<#
.SYNOPSIS
    Applies migrations to Azure SQL, then deploys (or updates) the Container
    App and grants its managed identity what it needs to reach the registry,
    the database and Service Bus.

.DESCRIPTION
    ORDER MATTERS AND IS THE POINT OF THIS SCRIPT.

    1. Migrations run FIRST, from this machine, before any new revision takes
       traffic. The Host deliberately does not migrate on startup: two replicas
       starting together would race the same schema change. That decision is
       recorded in the Dockerfile and it is why this step exists here.

    2. The Container App is created with a SYSTEM-ASSIGNED identity, then the
       role assignments follow. A revision that starts before its identity can
       pull from the registry or read from Service Bus fails in a way that
       looks like a code fault and is not.

    ROLE ASSIGNMENT PROPAGATION IS NOT INSTANT. Azure RBAC takes a minute or
    two to take effect. A consumer logging authentication failures immediately
    after the first deploy is almost always this -- wait before debugging.

    NO SECRET IS PRINTED. The SQL connection string is passed as a Container
    App secret and referenced by name; the password is read from the
    environment and never echoed.

.EXAMPLE
    $env:CAPSTONE_SQL_ADMIN_PASSWORD = '<the password used in 00-provision>'
    ./Day32/scripts/02-deploy.ps1 -DryRun
    ./Day32/scripts/02-deploy.ps1
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId  = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup   = 'thinkschool-dev-rg',

    [string] $AppName         = 'ca-quotes-capstone',
    [string] $EnvironmentName = 'cae-quotes-capstone',
    [string] $RegistryName    = 'acrquotescapstone',
    [string] $ImageTag        = 'v1',

    [string] $SqlServerName    = 'sql-quotes-capstone',
    [string] $SqlDatabaseName  = 'QuotesPlatform',
    [string] $SqlAdminUser     = 'capstoneadmin',
    [string] $SqlAdminPassword = $env:CAPSTONE_SQL_ADMIN_PASSWORD,

    [string] $ServiceBusNamespace = 'sb-quotes-7mo4cimyk4vnk',

    # From 01-provision-identity.ps1's output. Defaults are this tenant's.
    [string] $Authority = 'https://login.microsoftonline.com/8d46a076-d093-416d-a57b-8692cde13bf8/v2.0',
    [string] $Audience  = 'api://e020d22f-8d9c-4e65-9240-9e3b0931270a',

    [switch] $SkipMigrations,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if ([string]::IsNullOrWhiteSpace($SqlAdminPassword)) {
    throw 'CAPSTONE_SQL_ADMIN_PASSWORD is not set. Use the password given to 00-provision-azure.ps1.'
}

function Invoke-Az {
    param([string[]] $Arguments, [switch] $AllowFailure, [switch] $Quiet)

    $printable = @()
    $maskNext = $false
    foreach ($argument in $Arguments) {
        if ($maskNext) { $printable += '***'; $maskNext = $false; continue }
        # Anything that could carry the password or a connection string is
        # masked before it can reach a transcript.
        if ($argument -match 'Password=|secretref|sqlconn=') { $printable += '***'; continue }
        $printable += $argument
        if ($argument -in @('--admin-password', '-p', '--password', '--secrets')) { $maskNext = $true }
    }

    if ($DryRun -and -not $Quiet) {
        Write-Host "  DRYRUN az $($printable -join ' ')"
        return $null
    }

    # az writes warnings to stderr on success; with ErrorActionPreference Stop
    # that becomes a terminating error before the exit code is read.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & az @Arguments 2>&1 }
    finally { $ErrorActionPreference = $previous }

    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($printable -join ' ') failed:`n$output"
    }

    # Drop ErrorRecords that 2>&1 merged in on a successful call -- callers
    # here expect text, and .Trim() on a mixed array fails unhelpfully.
    $text = $output |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { "$_" }

    return ($text -join [Environment]::NewLine)
}

Invoke-Az -Quiet @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

# Connection Timeout is 60 on purpose: the database is SERVERLESS with
# auto-pause, so the first connection after an idle period has to wake it up.
# The default 15 seconds is not enough and the failure looks like the server
# does not exist.
$connectionString = "Server=tcp:$SqlServerName.database.windows.net,1433;Database=$SqlDatabaseName;User ID=$SqlAdminUser;Password=$SqlAdminPassword;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"

# ---------------------------------------------------------------------------
# 1. Migrations -- BEFORE the new revision exists.
# ---------------------------------------------------------------------------
if (-not $SkipMigrations) {
    Write-Host 'Applying migrations to Azure SQL...'
    Write-Host '  (the database is serverless; the first call may take ~60s to resume it)'

    foreach ($module in @('Catalog', 'Curation', 'Moderation', 'Publishing')) {
        $project = Join-Path $repoRoot "Day22/Capstone/src/Modules/$module/QuotesPlatform.Modules.$module.Infrastructure"
        Write-Host "  $module"

        if ($DryRun) {
            Write-Host "    DRYRUN dotnet ef database update --project $project --context $($module)DbContext --connection ***"
            continue
        }

        # --connection is REQUIRED: each module's design-time factory points at
        # a throwaway local database, so without it this would migrate the
        # wrong thing and report success.
        & dotnet ef database update `
            --project $project --startup-project $project `
            --context "$($module)DbContext" --connection $connectionString

        if ($LASTEXITCODE -ne 0) { throw "Migrations failed for $module." }
    }
}
else {
    Write-Host 'Skipping migrations (-SkipMigrations).'
}

# ---------------------------------------------------------------------------
# 2. The Container App.
# ---------------------------------------------------------------------------
$image = "$RegistryName.azurecr.io/quotes-capstone:$ImageTag"
$exists = Invoke-Az -Quiet -AllowFailure @(
    'containerapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'name', '-o', 'tsv')

Write-Host ''
if ([string]::IsNullOrWhiteSpace($exists)) {
    Write-Host "Creating Container App '$AppName'..."

    # --registry-identity system tells Azure to create the AcrPull role
    # assignment for the app's own identity, so no registry password exists
    # anywhere. --min-replicas 1 because scale-to-zero would also stop the
    # outbox relays, and an outbox that is only drained while someone is
    # watching is not an outbox.
    Invoke-Az @(
        'containerapp', 'create',
        '--name', $AppName, '--resource-group', $ResourceGroup,
        '--environment', $EnvironmentName,
        '--image', $image,
        '--target-port', '8080', '--ingress', 'external',
        '--system-assigned',
        '--registry-server', "$RegistryName.azurecr.io",
        '--registry-identity', 'system',
        '--min-replicas', '1', '--max-replicas', '1',
        '--secrets', "sqlconn=$connectionString",
        '--env-vars',
            'ConnectionStrings__Default=secretref:sqlconn',
            "ServiceBus__FullyQualifiedNamespace=$ServiceBusNamespace.servicebus.windows.net",
            "AzureAd__Authority=$Authority",
            "AzureAd__Audience=$Audience"
    ) | Out-Null
}
else {
    Write-Host "Updating Container App '$AppName'..."
    Invoke-Az @(
        'containerapp', 'secret', 'set',
        '--name', $AppName, '--resource-group', $ResourceGroup,
        '--secrets', "sqlconn=$connectionString") | Out-Null

    Invoke-Az @(
        'containerapp', 'update',
        '--name', $AppName, '--resource-group', $ResourceGroup,
        '--image', $image,
        '--set-env-vars',
            'ConnectionStrings__Default=secretref:sqlconn',
            "ServiceBus__FullyQualifiedNamespace=$ServiceBusNamespace.servicebus.windows.net",
            "AzureAd__Authority=$Authority",
            "AzureAd__Audience=$Audience"
    ) | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Service Bus RBAC for the app's identity.
# ---------------------------------------------------------------------------
$principalId = if ($DryRun) { '<system-identity-principal-id>' } else {
    (Invoke-Az -Quiet @(
        'containerapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup,
        '--query', 'identity.principalId', '-o', 'tsv')).Trim()
}

$namespaceScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ServiceBus/namespaces/$ServiceBusNamespace"

Write-Host ''
Write-Host 'Service Bus role assignments...'
foreach ($role in @('Azure Service Bus Data Sender', 'Azure Service Bus Data Receiver')) {
    Write-Host "  $role"
    # AllowFailure: re-running re-assigns an existing role, which az reports as
    # an error and which is not one.
    Invoke-Az -AllowFailure @(
        'role', 'assignment', 'create',
        '--assignee-object-id', $principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', $role,
        '--scope', $namespaceScope) | Out-Null
}

# ---------------------------------------------------------------------------
# 4. Where it lives, and whether it is actually up.
# ---------------------------------------------------------------------------
Write-Host ''
if ($DryRun) {
    Write-Host 'DRY RUN -- nothing was deployed.'
    return
}

$fqdn = (Invoke-Az -Quiet @(
    'containerapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup,
    '--query', 'properties.configuration.ingress.fqdn', '-o', 'tsv')).Trim()

$baseUrl = "https://$fqdn"
Write-Host "Deployed: $baseUrl"
Write-Host ''
Write-Host 'Verifying...'

# /health is the ONE anonymous endpoint, so this proves the process is up
# without needing a token.
$healthy = $false
for ($attempt = 1; $attempt -le 20; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 10
        if ($health.status -eq 'ok') { $healthy = $true; break }
    }
    catch { Start-Sleep -Seconds 10 }
}

if (-not $healthy) {
    throw @"
/health never answered. Check the revision's logs:
  az containerapp logs show --name $AppName --resource-group $ResourceGroup --tail 100

Most likely causes, in order:
  * a configuration value Program.cs fails fast on (it refuses to start
    without ConnectionStrings:Default, ServiceBus and both AzureAd settings)
  * the SQL firewall not allowing Azure services
  * --target-port not matching ASPNETCORE_HTTP_PORTS in the image
"@
}

Write-Host '  /health           : ok'

# AND THE POINT OF THE WHOLE DAY: an unauthenticated write must be refused.
# A deployment that answers /health proves the process started. This proves
# the thing ADR-0003 said had to be true before it was reachable.
$status = 0
try {
    $response = Invoke-WebRequest -Uri "$baseUrl/api/collections" -Method Post `
        -Body '{"name":"anonymous probe"}' -ContentType 'application/json' -UseBasicParsing
    $status = [int] $response.StatusCode
}
catch {
    $r = $_.Exception.Response
    if ($r -and $r.StatusCode) { $status = [int] $r.StatusCode }
}

if ($status -ne 401) {
    throw "An UNAUTHENTICATED POST /api/collections returned $status, expected 401. Do not leave this deployment running."
}

Write-Host '  anonymous write   : 401 (refused)'
Write-Host ''
Write-Host "Base URL: $baseUrl"
Write-Host 'Next: ./Day32/scripts/happy-path.ps1 -BaseUrl ' + $baseUrl
