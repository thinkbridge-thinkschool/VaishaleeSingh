<#
.SYNOPSIS
    Provisions the infrastructure the capstone needs to run in Azure: SQL,
    a container registry, and a Container Apps environment.

.DESCRIPTION
    SAME IDIOM AS Day29/scripts/00-provision-servicebus-topology.ps1 -- az CLI,
    idempotent, -DryRun first. That script's Invoke-Az wrapper exists because az
    writes to stderr on success as well as failure, and PowerShell turns any
    stderr output into a terminating NativeCommandError unless it is handled.
    The same wrapper is here for the same reason; exit code is the only signal
    that distinguishes "absent" from "broken".

    IDENTITY IS NOT HERE, AND NEITHER IS THE APP ITSELF. This script creates
    only what takes minutes to provision and never needs to change again.
    Entra app registrations are 01-provision-identity.ps1 and the Container App
    is 02-deploy.ps1, because those two have to happen after an image exists and
    are the ones that will be re-run.

    NOTHING HERE PRINTS A SECRET. The SQL admin password is read from the
    environment and never echoed, not even in -DryRun, where the argument list
    is printed -- see Invoke-Az.

.PARAMETER DryRun
    Print what would run and change nothing. Run this first, every time.

.EXAMPLE
    $env:CAPSTONE_SQL_ADMIN_PASSWORD = '<a new strong password>'
    ./Day32/scripts/00-provision-azure.ps1 -DryRun
    ./Day32/scripts/00-provision-azure.ps1
#>
[CmdletBinding()]
param(
    # Same subscription and resource group as Day 29's Service Bus namespace.
    # The Container App authenticates to that namespace with a managed identity
    # and disableLocalAuth = true, so they must be in the same tenant -- putting
    # them in the same resource group keeps the role assignment simple too.
    [string] $SubscriptionId = '33c82ead-36a8-4d8f-b969-d8476690c224',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',

    [string] $SqlServerName   = 'sql-quotes-capstone-v2',
    [string] $SqlDatabaseName = 'QuotesPlatform',
    [string] $SqlAdminUser    = 'capstoneadmin',
    [string] $SqlAdminPassword = $env:CAPSTONE_SQL_ADMIN_PASSWORD,

    [string] $RegistryName    = 'acrquotescapstonev2',
    [string] $EnvironmentName = 'cae-quotes-capstone',

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Guards. Each one turns a failure that would otherwise appear five minutes
# later, in a different tool, into a sentence.
# ---------------------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az CLI is not on PATH. Day 29 used it for the Service Bus topology; install it and sign in with `az login`.'
}

if ([string]::IsNullOrWhiteSpace($SqlAdminPassword)) {
    throw @'
No SQL admin password. Generate a NEW one and supply it via the environment:

  $env:CAPSTONE_SQL_ADMIN_PASSWORD = '<a new strong password>'

Do not reuse the local container password, do not commit it, and do not paste
it into a chat. It is the administrator of a database reachable from the
internet, which the local one never was.
'@
}

# Azure SQL rejects weak passwords with a generic error at the END of a slow
# create. Checking here costs nothing and names the actual rule.
if ($SqlAdminPassword.Length -lt 12) {
    throw 'The SQL admin password must be at least 12 characters (Azure SQL requires 8; 12 is this project''s floor).'
}

function Invoke-Az {
    param([string[]] $Arguments, [switch] $AllowFailure)

    # The password never reaches this line's output: any argument following
    # one that looks like a password flag is masked before printing.
    $printable = @()
    $maskNext = $false
    foreach ($argument in $Arguments) {
        if ($maskNext) { $printable += '***'; $maskNext = $false; continue }
        $printable += $argument
        if ($argument -in @('--admin-password', '-p', '--password')) { $maskNext = $true }
    }

    if ($DryRun) {
        Write-Host "  DRYRUN az $($printable -join ' ')"
        return $null
    }

    # az writes to stderr on SUCCESS as well as failure -- preview-feature
    # warnings, deprecation notices. Merging stderr into the output stream while
    # $ErrorActionPreference is 'Stop' makes PowerShell raise a terminating
    # NativeCommandError the moment az says anything there, BEFORE $LASTEXITCODE
    # is read. The first run of this script died on a preview-flag warning while
    # the underlying command had succeeded.
    #
    # Day29/scripts/00-provision-servicebus-topology.ps1 already solved this and
    # its comment explaining the fix was copied here without the fix itself.
    # Drop to 'Continue' for the duration of the call and decide on the exit
    # code, which is the only signal that distinguishes absent from broken.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($printable -join ' ') failed:`n$output"
    }

    return $output
}

Write-Host "Subscription : $SubscriptionId"
Write-Host "Resource grp : $ResourceGroup"
Write-Host ''

Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

# The resource group already exists (Day 29 put the Service Bus namespace in
# it). Read its location rather than hardcoding one: an Azure for Students
# subscription restricts regions, and the region that already worked is the
# region most likely to work again.
$location = if ($DryRun) { '<existing-rg-location>' } else {
    (Invoke-Az @('group', 'show', '--name', $ResourceGroup, '--query', 'location', '-o', 'tsv')).Trim()
}
Write-Host "Location     : $location  (taken from the existing resource group, not guessed)"
Write-Host ''

# ---------------------------------------------------------------------------
# Resource providers. An unregistered provider fails the FIRST create with a
# message about the provider rather than the resource, which reads like a
# permissions problem and is not.
# ---------------------------------------------------------------------------
Write-Host 'Registering resource providers (no-op if already registered)...'
foreach ($provider in @('Microsoft.Sql', 'Microsoft.ContainerRegistry', 'Microsoft.App', 'Microsoft.OperationalInsights')) {
    Invoke-Az @('provider', 'register', '--namespace', $provider) | Out-Null
    Write-Host "  $provider"
}

# The containerapp commands live in an extension. Adding it when it is already
# present is a no-op; omitting it makes 02-deploy.ps1 fail with "not a valid
# command", which looks like a typo.
Invoke-Az @('extension', 'add', '--name', 'containerapp', '--upgrade', '--only-show-errors') -AllowFailure | Out-Null

# ---------------------------------------------------------------------------
# Azure SQL. Serverless with auto-pause, because this is a demo that will sit
# idle for days at a time on a student credit.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Azure SQL server '$SqlServerName'..."
Invoke-Az @(
    'sql', 'server', 'create',
    '--name', $SqlServerName,
    '--resource-group', $ResourceGroup,
    '--location', $location,
    '--admin-user', $SqlAdminUser,
    '--admin-password', $SqlAdminPassword
    # --enable-public-network is REMOVED: it is a preview flag, public network
    # access is already the default for a new server, and its preview warning
    # was what tripped the stderr handling above. A flag that only restates a
    # default is not worth a warning on every run.
) | Out-Null

# Two firewall rules and no more:
#  - Azure services, so the Container App can connect at all.
#  - This machine, so migrations can be applied from here.
# 0.0.0.0 is Azure's special "allow Azure services" marker, NOT "allow the
# internet" -- worth the comment, because it reads exactly like the latter.
Write-Host '  firewall: allow Azure services'
Invoke-Az @(
    'sql', 'server', 'firewall-rule', 'create',
    '--resource-group', $ResourceGroup, '--server', $SqlServerName,
    '--name', 'AllowAzureServices',
    '--start-ip-address', '0.0.0.0', '--end-ip-address', '0.0.0.0'
) | Out-Null

if (-not $DryRun) {
    $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
    Write-Host "  firewall: allow this machine ($myIp) so migrations can run from here"
    Invoke-Az @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $ResourceGroup, '--server', $SqlServerName,
        '--name', 'AllowDevMachine',
        '--start-ip-address', $myIp, '--end-ip-address', $myIp
    ) -AllowFailure | Out-Null
}

Write-Host "  database '$SqlDatabaseName' (serverless, auto-pause after 60 min)"
Invoke-Az @(
    'sql', 'db', 'create',
    '--resource-group', $ResourceGroup, '--server', $SqlServerName,
    '--name', $SqlDatabaseName,
    '--edition', 'GeneralPurpose', '--family', 'Gen5', '--capacity', '1',
    '--compute-model', 'Serverless',
    '--auto-pause-delay', '60',
    '--backup-storage-redundancy', 'Local'
) | Out-Null

# ---------------------------------------------------------------------------
# Container registry. Admin user stays DISABLED: the Container App pulls with
# its managed identity, so there is no registry password to leak or rotate.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Container registry '$RegistryName'..."
Invoke-Az @(
    'acr', 'create',
    '--resource-group', $ResourceGroup, '--name', $RegistryName,
    '--sku', 'Basic', '--location', $location,
    '--admin-enabled', 'false'
) | Out-Null

# ---------------------------------------------------------------------------
# Container Apps environment.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "Container Apps environment '$EnvironmentName' (workload profiles)..."

# --enable-workload-profiles IS NOT OPTIONAL HERE, and the reason is not
# performance.
#
# Without it Azure creates an "EXPRESS" environment, which does not support
# system-assigned managed identity for container registry authentication. The
# first deploy failed with ExpressEnvironmentFeatureNotSupported, and the only
# way to pull an image on an express environment is a registry username and
# password -- reintroducing exactly the static credential that disabling the
# ACR admin user above was meant to avoid, and that Day 29 refused for Service
# Bus with disableLocalAuth.
#
# An express environment cannot be converted. If one already exists it has to
# be deleted and recreated, which also deletes every app inside it.
Invoke-Az @(
    'containerapp', 'env', 'create',
    '--resource-group', $ResourceGroup, '--name', $EnvironmentName,
    '--location', $location,
    '--enable-workload-profiles'
) | Out-Null

Write-Host ''
if ($DryRun) {
    Write-Host 'DRY RUN -- nothing was created. Re-run without -DryRun.'
}
else {
    Write-Host 'Provisioned. Next:'
    Write-Host '  ./Day32/scripts/01-provision-identity.ps1   (Entra app registrations)'
    Write-Host '  then build and push the image, then 02-deploy.ps1'
}
