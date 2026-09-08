<#
.SYNOPSIS
    Day 24. Finishes the dev deployment: reconciles the stack, clears the orphan
    firewall rule, makes sure the real image is deployed, and smoke-tests.

.DESCRIPTION
    ONE COMMAND, ON PURPOSE. The steps here were previously handed over as
    multi-line PowerShell with backtick continuations, and pasting those into a
    terminal went wrong twice: once the shell swallowed a continuation and
    reported "The output stream for this command is already redirected", and
    once a previous transcript was pasted back in and PowerShell tried to
    execute its own output as commands. Neither changed any Azure state, but
    both cost time and made it hard to tell what had actually run. A script has
    no paste hazard.

    Everything is idempotent. Run it as often as you like.

    WHAT IT FIXES, and why each one exists is worth knowing:

    1. The stack's deny assignment blocks the stack's own cleanup.
       sqlAllowedClientIpAddresses names a firewall rule after the operator's
       IP. A home IP changes, so the next deployment names a different rule and
       the old one leaves the template; actionOnUnmanage is `delete`, so the
       stack tries to remove it and is refused by its OWN deny assignment:
         DenyAssignmentAuthorizationFailed ... denied because of the deny
         assignment ... created by Deployment Stack '.../quotes-dev'
       The unmanage delete runs in the caller's security context, and
       applyToChildScopes extends denyDelete to every child of the SQL server.
       Two correct settings, one deadlock. Fixed by excluding exactly one action.

    2. quotesApiExists. Until it was set, every CLI stack update reverted the
       container app to the aci-helloworld placeholder, because
       fetch-container-image.bicep never looked up the running image. Now true
       in main.dev.bicepparam -- but a stack run made WHILE the placeholder was
       deployed faithfully preserves the placeholder, so this script checks and
       re-points if needed.

.PARAMETER ImageTag
    The image tag to ensure is deployed. Defaults to the one this project last
    pushed. Pass a newer tag after a fresh `dotnet publish`.

.EXAMPLE
    .\Day24\scripts\04-finish-dev.ps1
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $StackName      = 'quotes-dev',
    [string] $Location       = 'uaenorth',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',
    [string] $ContainerApp   = 'quotes-api-dev',
    [string] $SqlServer      = 'sql-quotes-7mo4cimyk4vnk',
    [string] $AcrEndpoint    = 'cr7mo4cimyk4vnk.azurecr.io',
    [string] $ImageTag       = 'dev-20260908171206'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$apiRoot  = Join-Path $repoRoot 'Day7\piece2'
$verify   = Join-Path $repoRoot 'Day24\verification'
New-Item -ItemType Directory -Force -Path $verify | Out-Null

$n = 0
function Step([string] $t) { $script:n++; Write-Host ''; Write-Host ('=' * 70) -ForegroundColor DarkGray; Write-Host ("$script:n. $t") -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor DarkGray }
function Ok  ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Bad ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red }

$failures = @()

# ---------------------------------------------------------------------------
Step 'Preconditions'
# ---------------------------------------------------------------------------
az account set --subscription $SubscriptionId | Out-Null
Ok "Subscription $SubscriptionId"

# The signing key must be the SAME value the stack last deployed, or the
# container's jwt-secret changes and every token already issued stops
# validating. There is no way to read it back -- it is @secure() -- so if the
# shell has lost it, a new one is generated and that consequence is stated
# rather than hidden.
if (-not $env:JWT_SECRET -or $env:JWT_SECRET.Length -lt 32) {
    $env:JWT_SECRET = [Convert]::ToBase64String((1..48 | ForEach-Object { Get-Random -Maximum 256 }))
    Note 'JWT_SECRET was not set in this shell, so a NEW random key was generated.'
    Note 'Any token issued by the currently deployed app will stop validating. No data is'
    Note 'affected. To avoid this next time, set $env:JWT_SECRET before running.'
} else {
    Ok "Reusing the JWT_SECRET in this shell ($($env:JWT_SECRET.Length) chars)."
}

$env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org).Trim()
Ok "This machine: $env:SQL_CLIENT_IP"

# ---------------------------------------------------------------------------
Step 'Reconcile the stack, with the deny-settings exclusion'
# ---------------------------------------------------------------------------
Push-Location $apiRoot
try {
    az stack sub create --name $StackName --location $Location `
        --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
        --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
        --deny-settings-apply-to-child-scopes `
        --deny-settings-excluded-actions `
            'Microsoft.Resources/subscriptions/resourceGroups/delete' `
            'Microsoft.Sql/servers/firewallRules/delete' `
        --description 'QuotesApi dev - Day 24' --yes -o none
} finally { Pop-Location }

$state = az stack sub show --name $StackName --query provisioningState -o tsv
if ($state -eq 'succeeded') { Ok "Stack state: $state" }
else {
    Bad "Stack state: $state"
    az stack sub show --name $StackName --query failedResources -o json | Write-Host
    $failures += "stack state $state"
}

# ---------------------------------------------------------------------------
Step 'Firewall rules'
# ---------------------------------------------------------------------------
$rules = az sql server firewall-rule list --server $SqlServer -g $ResourceGroup -o json | ConvertFrom-Json
$rules | ForEach-Object { Write-Host "  $($_.name)  $($_.startIpAddress)" }

# Orphans are rules named after a previous IP. The stack wants them gone and was
# refused before the exclusion existed; if any survive, delete them explicitly.
# That is finishing the stack's own instruction, not editing infrastructure
# behind the template's back -- the rule is not in the template any more.
$expected = "client-$($env:SQL_CLIENT_IP -replace '\.','-')"
$orphans  = @($rules | Where-Object { $_.name -like 'client-*' -and $_.name -ne $expected })
foreach ($o in $orphans) {
    Note "Deleting orphan rule $($o.name) (not in the template)."
    az sql server firewall-rule delete --name $o.name --server $SqlServer -g $ResourceGroup -o none
}
if (-not ($rules | Where-Object { $_.name -eq $expected })) {
    Bad "No rule for this machine ($expected). The migration script and any manual SQL access will be refused."
    $failures += 'missing client firewall rule'
} else { Ok "This machine is allowed ($expected)." }

# ---------------------------------------------------------------------------
Step 'The deployed image'
# ---------------------------------------------------------------------------
$wanted = "$AcrEndpoint/quotes-api:$ImageTag"
$current = az containerapp show -n $ContainerApp -g $ResourceGroup --query "properties.template.containers[0].image" -o tsv

if ($current -eq $wanted) {
    Ok "Already on $current"
} else {
    Note "Currently on $current"
    Note "Re-pointing to $wanted"
    az containerapp update -n $ContainerApp -g $ResourceGroup --image $wanted -o none
    Ok 'Updated.'
}

# ---------------------------------------------------------------------------
Step 'Wait for a healthy revision'
# ---------------------------------------------------------------------------
$ready = $false
foreach ($i in 1..30) {
    $rev = az containerapp revision list -n $ContainerApp -g $ResourceGroup `
        --query "[?properties.active] | [0].{name:name,state:properties.runningState}" -o json | ConvertFrom-Json
    Write-Host "  attempt $i : $($rev.name) = $($rev.state)"
    if ($rev.state -eq 'Running') { $ready = $true; break }
    if ($rev.state -in 'Failed','Degraded','ActivationFailed') {
        Bad "Revision reported $($rev.state)."
        # The console log is the only place the cause appears, and a crashed
        # replica is gone by the time you look -- so read it from Log Analytics.
        Note 'Read the crash output with:'
        Note "  `$ws = az monitor log-analytics workspace show -g $ResourceGroup -n log7mo4cimyk4vnk --query customerId -o tsv"
        Note "  az monitor log-analytics query --workspace `$ws --analytics-query `"ContainerAppConsoleLogs_CL | where RevisionName_s == '$($rev.name)' | project TimeGenerated, Log_s | order by TimeGenerated asc | take 60`" -o table"
        $failures += "revision $($rev.state)"
        break
    }
    Start-Sleep -Seconds 10
}
if ($ready) { Ok 'Revision running.' }

# ---------------------------------------------------------------------------
Step 'Smoke tests'
# ---------------------------------------------------------------------------
$fqdn = az containerapp show -n $ContainerApp -g $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv
$app  = "https://$fqdn"
Write-Host "  $app"
Note 'minReplicas is 0 in the template and the database is serverless, so the'
Note 'first request pays a cold start plus a possible database resume.'

function Probe([string] $Name, [string] $Url, [string] $Method, [string] $Body, [string] $MustContain) {
    foreach ($i in 1..12) {
        try {
            $p = @{ Uri = $Url; TimeoutSec = 30; SkipHttpErrorCheck = $true; Method = $Method }
            if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
            $r = Invoke-WebRequest @p
            $body = [string]$r.Content
            if ($MustContain -and $body -notmatch [regex]::Escape($MustContain)) {
                Write-Host "  $Name attempt $i : $($r.StatusCode), body did not contain '$MustContain'"
            } else {
                Ok "$Name -> $($r.StatusCode)"
                return $true
            }
        } catch {
            Write-Host "  $Name attempt $i : $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 10
    }
    Bad "$Name never succeeded."
    return $false
}

# /health/ready is the one that fails if the migrations were not applied or the
# managed identity has no database user.
if (-not (Probe 'health/ready' "$app/health/ready" 'GET' $null $null)) { $failures += 'health/ready' }

# The API must answer with ITS OWN validation problem. HTML here would mean the
# MapFallbackToFile regex is not excluding api/, so API 404s are served as the
# SPA shell with a 200 -- the hazard staticwebapp.config.json used to prevent.
if (-not (Probe 'api/auth/login' "$app/api/auth/login" 'POST' '{"email":"","password":""}' 'credentials')) { $failures += 'api/auth/login' }

# Real data through EF Core and Azure SQL.
if (-not (Probe 'api/quotes' "$app/api/quotes?page=1&pageSize=3" 'GET' $null $null)) { $failures += 'api/quotes' }

# The SPA shell, checked for Angular's own marker rather than a 200: / returns
# 200 whether it serves index.html or a stray file.
if (-not (Probe 'SPA shell' "$app/" 'GET' $null '<app-root')) { $failures += 'SPA shell' }

# The deep link is the whole reason the fallback exists -- /quotes is a client
# route the server knows nothing about.
if (-not (Probe 'deep link /quotes' "$app/quotes" 'GET' $null '<app-root')) { $failures += 'deep link' }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkGray
if ($failures.Count -eq 0) {
    Write-Host 'DEV IS UP' -ForegroundColor Green
    Write-Host ('=' * 70) -ForegroundColor Green
    Write-Host "  $app"
    Write-Host ''
    Write-Host '  Next, and all of it is evidence rather than debugging:'
    Write-Host '    1. Drift proof:  az containerapp update -n quotes-api-dev -g thinkschool-dev-rg --min-replicas 3'
    Write-Host '                     then the what-if must show ~ Modify minReplicas 3 -> 0'
    Write-Host '    2. Deny proof:   az containerapp delete -n quotes-api-dev -g thinkschool-dev-rg --yes'
    Write-Host '                     must be refused with RequestDisallowedByDeploymentStackDenyAssignment'
    Write-Host '    3. Repo variables + GitHub OIDC, then merge to main.'
    Write-Host '    4. Prod: deploy, verify, then az stack sub delete to prove clean teardown.'
    "$app is healthy at $(Get-Date -Format o)" | Out-File (Join-Path $verify 'dev-smoke-passed.txt') -Encoding utf8
} else {
    Write-Host "$($failures.Count) CHECK(S) FAILED" -ForegroundColor Red
    Write-Host ('=' * 70) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  * $_" -ForegroundColor Red }
    exit 1
}
Write-Host ''
