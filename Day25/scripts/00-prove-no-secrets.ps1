<#
.SYNOPSIS
    Day 25. Proves there are zero secrets in the deployed app settings -- or
    reports exactly which ones are still there. Exit code is the proof.

.DESCRIPTION
    WHY THIS RUNS BEFORE ANY OF THE DAY 25 CHANGES.

    A check that has only ever passed proves nothing. Run this first, with
    -Baseline, against the environment as Day 24 left it: it should FAIL, and
    the recorded failures are what the rest of Day 25 is answering. Run it
    again at the end without -Baseline and the two files together are the
    evidence. One passing screenshot is not evidence; a check that went from
    red to green on named findings is.

    WHAT "ZERO SECRETS" IS TAKEN TO MEAN HERE, because the loose reading is
    not worth much. It is not "I looked at the app settings and did not see a
    password". It is three separate claims, and this script tests all three:

      1. NOTHING SECRET IS IN THE APP'S CONFIGURATION. No inline Container
         Apps secret (a secret with a literal `value` rather than a
         `keyVaultUrl`), and no environment variable whose value is shaped
         like a credential.

      2. THE RESOURCES DO NOT ACCEPT SECRETS AT ALL. This is the half that
         actually matters and the half that is usually skipped. An app
         setting is a convention; `disableLocalAuth` is a control. If the SQL
         server is Entra-only, the Service Bus namespace has local auth off,
         the registry has no admin user and App Insights refuses ingestion
         keys, then a credential pasted into configuration would not work
         even if someone added one tomorrow. Absence of a secret is a fact
         about today. Refusal of secrets is a fact about the deployment.

      3. THE IDENTITY DOING THE WORK IS NOT OVER-PRIVILEGED. Replacing a
         connection string with a managed identity that holds Contributor on
         the subscription is not a security improvement, it is the same
         authority behind a nicer door. Broad roles are reported as failures.

    WHAT IT DELIBERATELY DOES NOT DO. It does not read secret VALUES back and
    print them. `az containerapp secret list --show-values` would resolve and
    display them, which is the one thing a script whose output gets committed
    must not do. It distinguishes vault-backed from inline by the presence of
    `keyVaultUrl`, which needs no value at all.

.PARAMETER Baseline
    Write the report to Day25/verification/no-secrets-BEFORE.txt instead of
    no-secrets-AFTER.txt, and do not treat failures as an error worth a
    non-zero exit -- a baseline run is EXPECTED to fail, and a red baseline
    should not stop a script that is only recording it.

.PARAMETER KeyVaultName
    Empty until Phase 2 creates the vault. When empty, the Key Vault checks
    report as "not yet provisioned" rather than failing, so this script is
    runnable from the first day of Day 25 rather than only the last.

.EXAMPLE
    ./Day25/scripts/00-prove-no-secrets.ps1 -Baseline
    ./Day25/scripts/00-prove-no-secrets.ps1
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId  = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup   = 'thinkschool-dev-rg',
    [string] $ApiContainerApp = 'quotes-api-dev',
    [string] $WebContainerApp = 'quotes-web-dev',
    [string] $KeyVaultName    = '',
    [switch] $Baseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir   = Join-Path $repoRoot 'Day25\verification'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$reportPath = Join-Path $outDir $(if ($Baseline) { 'no-secrets-BEFORE.txt' } else { 'no-secrets-AFTER.txt' })

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [Parameter(Mandatory)] [string] $Area,
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'SKIP', 'INFO')] [string] $Status,
        [string] $Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Area   = $Area
        Check  = $Check
        Status = $Status
        Detail = $Detail
    })

    $colour = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'DarkGray' }
        default { 'Yellow' }
    }
    Write-Host ('  {0,-4}  {1,-22} {2}' -f $Status, $Area, $Check) -ForegroundColor $colour
    if ($Detail) { Write-Host ('        {0}' -f $Detail) -ForegroundColor DarkGray }
}

# Named $AzArgs, NOT $args. Day 24 lost an afternoon to exactly this: $args is
# an automatic variable inside a PowerShell function, so a local assignment to
# it is silently ignored and the splat passes the function's own arguments
# instead of the ones just built. See Day24/scripts/04-finish-dev.ps1.
function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)

    $raw = & az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }

    $joined = ($raw -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined)) { return $null }

    try { return $joined | ConvertFrom-Json } catch { return $null }
}

function Test-HasProperty {
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $false }
    return ($InputObject.PSObject.Properties.Name -contains $Name)
}

# ---------------------------------------------------------------------------
# What a credential looks like when it is hiding in a configuration value
# ---------------------------------------------------------------------------
# Deliberately pattern-based rather than name-based. A value called
# ConnectionStrings__DefaultConnection is not automatically a secret -- this
# project's is `Authentication=Active Directory Default`, which contains no
# credential at all -- and a value called Foo__Bar might be one. What makes a
# string a secret is its CONTENT.
$CredentialPatterns = @(
    @{ Name = 'SQL password';                  Pattern = '(?i)(^|;)\s*(password|pwd)\s*=\s*[^;\s]' }
    @{ Name = 'Service Bus / Event Hub SAS';   Pattern = '(?i)SharedAccessKey\s*=' }
    @{ Name = 'Storage account key';           Pattern = '(?i)AccountKey\s*=' }
    @{ Name = 'SAS token signature';           Pattern = '(?i)(^|[?&])sig=' }
    @{ Name = 'PEM private key';               Pattern = '-----BEGIN' }
    @{ Name = 'Bare high-entropy literal';     Pattern = '^[A-Za-z0-9+/]{32,}={0,2}$' }
)

# Checked separately from the list above, because whether it is a credential
# depends on a property of another resource: with App Insights local auth
# DISABLED an instrumentation key is an identifier, and with it ENABLED the
# same string is a working ingestion credential. Same value, two meanings.
$InstrumentationKeyPattern = '(?i)InstrumentationKey\s*='

Write-Host ''
Write-Host 'Day 25 -- zero-secrets proof' -ForegroundColor Cyan
Write-Host ('Subscription:   {0}' -f $SubscriptionId)
Write-Host ('Resource group: {0}' -f $ResourceGroup)
Write-Host ('Mode:           {0}' -f $(if ($Baseline) { 'BASELINE (failures expected)' } else { 'VERIFY' }))
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host '  FAIL  az is not on PATH.' -ForegroundColor Red
    exit 1
}
az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAIL  Could not select the subscription. Run az login.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Container app secrets: inline value, or Key Vault reference?
# ---------------------------------------------------------------------------
Write-Host 'Container app secrets' -ForegroundColor Cyan

foreach ($app in @($ApiContainerApp, $WebContainerApp)) {
    # Called directly rather than through Invoke-AzJson, because the two
    # outcomes that matter here are indistinguishable after ConvertFrom-Json on
    # Windows PowerShell 5.1: it turns the JSON literal `[]` into NOTHING, not
    # into an empty array, so "this app has no secrets" and "this command
    # failed" both arrive as $null.
    #
    # The baseline run reported quotes-web-dev as "app not found" for exactly
    # that reason. It exists, and it holds no secrets -- which is the best
    # possible result and was being printed as an inconclusive skip. A proof
    # that cannot tell a pass from a missing resource is not a proof.
    $rawSecrets = (& az containerapp secret list -n $app -g $ResourceGroup -o json 2>$null) -join "`n"
    $azFailed = ($LASTEXITCODE -ne 0)

    if ($azFailed) {
        Add-Result -Area $app -Check 'secret list' -Status 'SKIP' -Detail 'App not found, or no permission to read it.'
        continue
    }

    if ([string]::IsNullOrWhiteSpace($rawSecrets) -or $rawSecrets.Trim() -eq '[]') {
        Add-Result -Area $app -Check 'holds no secrets at all' -Status 'PASS' -Detail 'Nothing to vault; nothing to leak.'
        continue
    }

    $secrets = $null
    try { $secrets = $rawSecrets | ConvertFrom-Json } catch { $secrets = $null }
    if ($null -eq $secrets) {
        Add-Result -Area $app -Check 'secret list' -Status 'SKIP' -Detail 'Could not parse the secret list.'
        continue
    }

    foreach ($secret in @($secrets)) {
        $kvUrl = if (Test-HasProperty $secret 'keyVaultUrl') { $secret.keyVaultUrl } else { $null }

        if (-not [string]::IsNullOrWhiteSpace($kvUrl)) {
            $identity = if (Test-HasProperty $secret 'identity') { $secret.identity } else { '' }
            if ([string]::IsNullOrWhiteSpace($identity)) {
                # A Key Vault reference with no identity cannot resolve, and the
                # revision fails to provision rather than falling back -- worth
                # its own failure so it is not mistaken for a passing vault ref.
                Add-Result -Area $app -Check ("secret '{0}' is vault-backed but has no identity" -f $secret.name) `
                           -Status 'FAIL' -Detail $kvUrl
            } else {
                Add-Result -Area $app -Check ("secret '{0}' is a Key Vault reference" -f $secret.name) `
                           -Status 'PASS' -Detail $kvUrl
            }
        } else {
            Add-Result -Area $app -Check ("secret '{0}' holds an INLINE value" -f $secret.name) `
                       -Status 'FAIL' `
                       -Detail 'Stored in the container app itself, so it travelled through the template, the deployment history and whoever ran the deploy. Needs a keyVaultUrl.'
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Environment variables: is anything credential-shaped sitting in the clear?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Environment variables' -ForegroundColor Cyan

# Resolved once, because it decides how an instrumentation key is judged below.
$aiComponents = Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Insights/components', '-o', 'json')
$aiLocalAuthDisabled = $false
$aiComponent = $null
if ($null -ne $aiComponents -and @($aiComponents).Count -gt 0) {
    $aiComponent = Invoke-AzJson @('resource', 'show', '--ids', @($aiComponents)[0].id, '-o', 'json')
    if ($null -ne $aiComponent -and (Test-HasProperty $aiComponent.properties 'DisableLocalAuth')) {
        $aiLocalAuthDisabled = [bool] $aiComponent.properties.DisableLocalAuth
    }
}

foreach ($app in @($ApiContainerApp, $WebContainerApp)) {
    $app_ = Invoke-AzJson @('containerapp', 'show', '-n', $app, '-g', $ResourceGroup, '-o', 'json')
    if ($null -eq $app_) {
        Add-Result -Area $app -Check 'read container app' -Status 'SKIP' -Detail 'Not found.'
        continue
    }

    $containers = $app_.properties.template.containers
    $findings = 0

    foreach ($container in @($containers)) {
        if (-not (Test-HasProperty $container 'env')) { continue }
        foreach ($entry in @($container.env)) {
            if ($null -eq $entry) { continue }

            # A secretRef is not a value; whether it is safe was decided in
            # section 1 by whether that secret is vault-backed.
            $hasValue = (Test-HasProperty $entry 'value') -and -not [string]::IsNullOrWhiteSpace($entry.value)
            if (-not $hasValue) { continue }

            foreach ($pattern in $CredentialPatterns) {
                if ($entry.value -match $pattern.Pattern) {
                    $findings++
                    Add-Result -Area $app -Check ("env '{0}' looks like a credential" -f $entry.name) `
                               -Status 'FAIL' -Detail ('Matched: {0}' -f $pattern.Name)
                }
            }

            if ($entry.value -match $InstrumentationKeyPattern) {
                if ($aiLocalAuthDisabled) {
                    Add-Result -Area $app -Check ("env '{0}' carries an instrumentation key" -f $entry.name) `
                               -Status 'PASS' `
                               -Detail 'App Insights local auth is disabled, so this is an identifier and not a credential.'
                } else {
                    $findings++
                    Add-Result -Area $app -Check ("env '{0}' carries a WORKING ingestion key" -f $entry.name) `
                               -Status 'FAIL' `
                               -Detail 'App Insights still accepts local auth, so this string authenticates telemetry ingestion on its own.'
                }
            }
        }
    }

    if ($findings -eq 0) {
        Add-Result -Area $app -Check 'no credential-shaped env values' -Status 'PASS'
    }
}

# ---------------------------------------------------------------------------
# 3. Do the resources still ACCEPT a secret? This is the half that matters.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Resources refuse secret-based auth' -ForegroundColor Cyan

# --- Azure SQL: Entra-only ---
$sqlServers = Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Sql/servers', '-o', 'json')
if ($null -eq $sqlServers -or @($sqlServers).Count -eq 0) {
    Add-Result -Area 'Azure SQL' -Check 'server present' -Status 'SKIP' -Detail 'No SQL server in this resource group.'
} else {
    foreach ($server in @($sqlServers)) {
        $adOnly = Invoke-AzJson @('sql', 'server', 'ad-only-auth', 'get', '-n', $server.name, '-g', $ResourceGroup, '-o', 'json')
        $isEntraOnly = ($null -ne $adOnly) -and (Test-HasProperty $adOnly 'azureAdOnlyAuthentication') -and $adOnly.azureAdOnlyAuthentication
        Add-Result -Area 'Azure SQL' -Check ("{0}: Entra-only authentication" -f $server.name) `
                   -Status $(if ($isEntraOnly) { 'PASS' } else { 'FAIL' }) `
                   -Detail $(if ($isEntraOnly) { 'No SQL login exists to hold a password.' } else { 'SQL authentication is still enabled: a password could be used.' })
    }
}

# --- Service Bus: local (SAS) auth off ---
$sbNamespaces = Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.ServiceBus/namespaces', '-o', 'json')
if ($null -eq $sbNamespaces -or @($sbNamespaces).Count -eq 0) {
    Add-Result -Area 'Service Bus' -Check 'namespace present' -Status 'SKIP'
} else {
    foreach ($ns in @($sbNamespaces)) {
        $nsFull = Invoke-AzJson @('resource', 'show', '--ids', $ns.id, '-o', 'json')
        $disabled = ($null -ne $nsFull) -and (Test-HasProperty $nsFull.properties 'disableLocalAuth') -and $nsFull.properties.disableLocalAuth
        Add-Result -Area 'Service Bus' -Check ("{0}: local (SAS) auth disabled" -f $ns.name) `
                   -Status $(if ($disabled) { 'PASS' } else { 'FAIL' }) `
                   -Detail $(if ($disabled) { 'Connection strings with SharedAccessKey are rejected.' } else { 'SAS connection strings still work against this namespace.' })
    }
}

# --- Container Registry: no admin user ---
$registries = Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.ContainerRegistry/registries', '-o', 'json')
if ($null -eq $registries -or @($registries).Count -eq 0) {
    Add-Result -Area 'Container Registry' -Check 'registry present' -Status 'SKIP'
} else {
    foreach ($registry in @($registries)) {
        $acr = Invoke-AzJson @('acr', 'show', '-n', $registry.name, '-o', 'json')
        $adminOn = ($null -ne $acr) -and (Test-HasProperty $acr 'adminUserEnabled') -and $acr.adminUserEnabled
        Add-Result -Area 'Container Registry' -Check ("{0}: admin user disabled" -f $registry.name) `
                   -Status $(if ($adminOn) { 'FAIL' } else { 'PASS' }) `
                   -Detail $(if ($adminOn) { 'A username and password pair exists on this registry. Nothing uses it -- both container apps pull with a managed identity -- which makes it a credential with no owner.' } else { 'Pull is identity-only.' })
    }
}

# --- Application Insights: ingestion keys refused ---
if ($null -eq $aiComponent) {
    Add-Result -Area 'App Insights' -Check 'component present' -Status 'SKIP'
} else {
    Add-Result -Area 'App Insights' -Check ("{0}: local auth disabled" -f $aiComponent.name) `
               -Status $(if ($aiLocalAuthDisabled) { 'PASS' } else { 'FAIL' }) `
               -Detail $(if ($aiLocalAuthDisabled) { 'Ingestion requires an Entra token; the instrumentation key is only an address.' } else { 'The instrumentation key in app settings is a working ingestion credential.' })
}

# --- Key Vault: RBAC, not access policies ---
Write-Host ''
Write-Host 'Key Vault' -ForegroundColor Cyan
$vaults = Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.KeyVault/vaults', '-o', 'json')
if ($null -eq $vaults -or @($vaults).Count -eq 0) {
    Add-Result -Area 'Key Vault' -Check 'vault provisioned' -Status $(if ($Baseline) { 'INFO' } else { 'FAIL' }) `
               -Detail 'No vault in this resource group. Expected before Phase 2; a failure after it.'
} else {
    foreach ($v in @($vaults)) {
        $vault = Invoke-AzJson @('keyvault', 'show', '-n', $v.name, '-o', 'json')
        if ($null -eq $vault) { continue }

        $rbac = (Test-HasProperty $vault.properties 'enableRbacAuthorization') -and $vault.properties.enableRbacAuthorization
        Add-Result -Area 'Key Vault' -Check ("{0}: RBAC authorization" -f $v.name) `
                   -Status $(if ($rbac) { 'PASS' } else { 'FAIL' }) `
                   -Detail $(if ($rbac) { 'Access is role assignments, auditable in the same place as everything else.' } else { 'Still on access policies: a second, parallel permission model that no RBAC review will show you.' })

        # Purge protection is reported, never failed. It is correct in prod and
        # actively harmful in this dev environment: Day 24 tears the stack down
        # with actionOnUnmanage deleteAll, and a purge-protected vault reserves
        # its name for up to 90 days, so the next stack create fails on a name
        # it cannot reuse.
        $purge = (Test-HasProperty $vault.properties 'enablePurgeProtection') -and $vault.properties.enablePurgeProtection
        Add-Result -Area 'Key Vault' -Check ("{0}: purge protection = {1}" -f $v.name, $purge) -Status 'INFO' `
                   -Detail 'Wanted in prod. In dev it collides with the stack teardown -- see Day25/docs/day25-submission.md.'
    }
}

# ---------------------------------------------------------------------------
# 4. Is the identity that replaced the secrets over-privileged?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Managed identity privilege' -ForegroundColor Cyan

$identities = Invoke-AzJson @('identity', 'list', '-g', $ResourceGroup, '-o', 'json')
if ($null -eq $identities -or @($identities).Count -eq 0) {
    Add-Result -Area 'Managed identity' -Check 'identity present' -Status 'SKIP'
} else {
    # Roles broad enough that holding one makes the narrower grants decorative.
    $broadRoles = @('Owner', 'Contributor', 'User Access Administrator')

    foreach ($mi in @($identities)) {
        $assignments = Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $mi.principalId, '--all', '-o', 'json')
        if ($null -eq $assignments) {
            Add-Result -Area $mi.name -Check 'role assignments readable' -Status 'SKIP' -Detail 'Needs directory read permission.'
            continue
        }

        $broad = @($assignments | Where-Object { $broadRoles -contains $_.roleDefinitionName })
        if ($broad.Count -gt 0) {
            foreach ($b in $broad) {
                Add-Result -Area $mi.name -Check ("holds '{0}'" -f $b.roleDefinitionName) -Status 'FAIL' `
                           -Detail ('Scope: {0}. Swapping a connection string for an identity this broad moves the credential, it does not reduce it.' -f $b.scope)
            }
        } else {
            $names = (@($assignments | ForEach-Object { $_.roleDefinitionName }) | Sort-Object -Unique) -join ', '
            Add-Result -Area $mi.name -Check 'least-privilege roles only' -Status 'PASS' -Detail $names
        }
    }
}

# ---------------------------------------------------------------------------
# 5. The static half: does the repository itself carry a literal?
# ---------------------------------------------------------------------------
# The checks above describe one deployed environment at one moment. This one
# describes what the next deployment WOULD carry, which is the part a reviewer
# can act on -- and it catches the case where someone fixes Azure by hand and
# leaves the template as it was.
Write-Host ''
Write-Host 'Repository' -ForegroundColor Cyan

$scanTargets = @(
    'Day7\piece2\infra\main.bicep'
    'Day7\piece2\infra\main.dev.bicepparam'
    'Day7\piece2\infra\main.prod.bicepparam'
    'Day7\piece2\infra\main.parameters.json'
    'Day7\piece2\QuotesApi\appsettings.json'
    'Day7\piece2\QuotesApi\appsettings.Production.json'
)

$repoFindings = 0
foreach ($relative in $scanTargets) {
    $full = Join-Path $repoRoot $relative
    if (-not (Test-Path $full)) { continue }

    # -Raw returns $null for an empty file, and touching .Length on $null throws
    # under Set-StrictMode. Day 24 hit this; check before use.
    $content = Get-Content $full -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { continue }

    foreach ($pattern in $CredentialPatterns) {
        # The bare-high-entropy pattern is anchored to a whole line and would
        # match half the base64 in a lock file; it is meant for a single config
        # VALUE, not a document, so it is skipped in the file scan.
        if ($pattern.Name -eq 'Bare high-entropy literal') { continue }

        if ($content -match $pattern.Pattern) {
            $repoFindings++
            Add-Result -Area 'Repository' -Check ("{0} contains a literal" -f $relative) -Status 'FAIL' `
                       -Detail ('Matched: {0}' -f $pattern.Name)
        }
    }
}
if ($repoFindings -eq 0) {
    Add-Result -Area 'Repository' -Check 'no credential literals in infra or appsettings' -Status 'PASS'
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$pass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$skip = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count

Write-Host ''
Write-Host ('{0} passed, {1} failed, {2} skipped.' -f $pass, $fail, $skip) -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })

$header = @(
    ('Day 25 zero-secrets proof -- {0}' -f $(if ($Baseline) { 'BASELINE, before any Day 25 change' } else { 'VERIFICATION' }))
    ('Run at:         {0}' -f (Get-Date -Format o))
    ('Subscription:   {0}' -f $SubscriptionId)
    ('Resource group: {0}' -f $ResourceGroup)
    ('Result:         {0} passed, {1} failed, {2} skipped' -f $pass, $fail, $skip)
    ''
)

$body = $script:Results | ForEach-Object {
    $line = ('{0,-4}  {1,-22}  {2}' -f $_.Status, $_.Area, $_.Check)
    if ($_.Detail) { $line += ("`n" + (' ' * 30) + $_.Detail) }
    $line
}

($header + $body) -join "`n" | Out-File $reportPath -Encoding utf8
Write-Host ('Written to {0}' -f $reportPath) -ForegroundColor Cyan
Write-Host ''

# A baseline is SUPPOSED to be red. Failing the script on it would mean the one
# run whose failures are the point is also the run that stops the pipeline.
if ($Baseline) { exit 0 }
if ($fail -gt 0) { exit 1 }
exit 0
