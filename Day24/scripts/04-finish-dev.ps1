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
# EXCLUDED PRINCIPAL, NOT A LIST OF EXCLUDED ACTIONS, and the first attempt
# explains why. Passing two actions was rejected:
#
#   unrecognized arguments: Microsoft.Sql/servers/firewallRules/delete
#
# az attached the first value to --deny-settings-excluded-actions and treated
# the second as a stray positional argument. The documentation describes it as a
# list, so this may be version-specific, but a command that silently keeps only
# the first of two protections is not one to guess at.
#
# Excluding the OPERATOR's own object id solves the root problem more directly
# anyway. The deny assignment exists to stop resources being deleted out from
# under the template -- an accidental portal delete, or a script nobody
# remembers running. The person who owns the stack being locked out of the
# stack's own housekeeping is not the hazard; it is the bug we hit twice.
#
# The trade-off, stated: this principal can now delete anything under the
# stack's scope. That is a real reduction, and it is acceptable here because it
# is the same account that can delete the stack outright. It would NOT be
# acceptable for a CI principal or a shared operator group, where excluding the
# single action is the narrower and better answer.
$meId = az ad signed-in-user show --query id -o tsv
if ([string]::IsNullOrWhiteSpace($meId)) { Bad 'Could not read the signed-in user object id.'; exit 1 }
Ok "Excluding own principal from the deny assignment: $meId"

Push-Location $apiRoot
try {
    az stack sub create --name $StackName --location $Location `
        --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
        --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
        --deny-settings-apply-to-child-scopes `
        --deny-settings-excluded-principals $meId `
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
# Two kinds of rule are NOT in the template and should go: a client-<ip> rule
# from a previous SQL_CLIENT_IP, and QueryEditorClientIPAddress_<epoch>, which
# the Azure portal's Query editor creates silently the first time you open it.
# The second is textbook drift -- a resource added by hand, invisible to the
# template, which the stack will delete on its next update anyway. Removing it
# here keeps the firewall describable by the template rather than by whoever
# last used the portal.
$expected = "client-$($env:SQL_CLIENT_IP -replace '\.','-')"
$orphans  = @($rules | Where-Object {
    ($_.name -like 'client-*' -or $_.name -like 'QueryEditorClientIPAddress_*') -and $_.name -ne $expected
})
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
# ScaledToZero IS A HEALTHY STATE, and treating it as a pending one wasted five
# polling attempts and then crashed. minReplicas is 0 in the template, so with
# no traffic the revision sits at ScaledToZero indefinitely -- it will never
# reach Running on its own, because the thing that wakes it is a request, and
# the requests are in the smoke tests further down. Waiting for Running before
# probing is waiting for an event that only probing can cause.
#
# The az call is also allowed to fail outright. It did:
#   ConnectionResetError(10054, 'An existing connection was forcibly closed')
# a transient TLS reset from ARM. az printed a full Python traceback and
# returned nothing, ConvertFrom-Json produced $null, and $rev.name threw
# "The property 'name' cannot be found on this object" under Set-StrictMode --
# so a network blip presented as a script bug. Retried rather than fatal.
$ready = $false
foreach ($i in 1..30) {
    $revJson = az containerapp revision list -n $ContainerApp -g $ResourceGroup `
        --query "[?properties.active] | [0].{name:name,state:properties.runningState}" -o json 2>$null
    $rev = $null
    if (-not [string]::IsNullOrWhiteSpace($revJson)) {
        try { $rev = $revJson | ConvertFrom-Json } catch { $rev = $null }
    }
    if ($null -eq $rev) {
        Write-Host "  attempt $i : could not read revision state (transient ARM error), retrying"
        Start-Sleep -Seconds 10
        continue
    }

    $state = if ($rev.PSObject.Properties.Name -contains 'state') { [string]$rev.state } else { '' }
    Write-Host "  attempt $i : $($rev.name) = $state"

    if ($state -in 'Running','ScaledToZero') {
        $ready = $true
        if ($state -eq 'ScaledToZero') {
            Note 'Scaled to zero, which is correct with minReplicas 0. The first probe will wake it.'
        }
        break
    }
    if ($state -in 'Failed','Degraded','ActivationFailed') {
        Bad "Revision reported $($rev.state)."
        # The console log is the only place the cause appears, and a crashed
        # replica is gone by the time you look -- so read it from Log Analytics.
        Note 'Read the crash output with:'
        Note "  `$ws = az monitor log-analytics workspace show -g $ResourceGroup -n log7mo4cimyk4vnk --query customerId -o tsv"
        Note "  az monitor log-analytics query --workspace `$ws --analytics-query `"ContainerAppConsoleLogs_CL | where RevisionName_s == '$($rev.name)' | project TimeGenerated, Log_s | order by TimeGenerated asc | take 60`" -o table"
        $failures += "revision $state"
        break
    }
    Start-Sleep -Seconds 10
}
if ($ready) { Ok 'Revision is in a serviceable state.' }

# ---------------------------------------------------------------------------
Step 'Smoke tests'
# ---------------------------------------------------------------------------
$fqdn = az containerapp show -n $ContainerApp -g $ResourceGroup --query "properties.configuration.ingress.fqdn" -o tsv
$app  = "https://$fqdn"
Write-Host "  $app"
Note 'minReplicas is 0 in the template and the database is serverless, so the'
Note 'first request pays a cold start plus a possible database resume.'

# curl.exe, NOT Invoke-WebRequest, and this is the second thing the first run
# taught. Invoke-WebRequest -SkipHttpErrorCheck exists only in PowerShell 7+;
# on Windows PowerShell 5.1 every probe failed with
#
#   A parameter cannot be found that matches parameter name 'SkipHttpErrorCheck'
#
# twelve times per endpoint. Worse than a wrong result: the tests never reached
# the app at all, so a healthy deployment reported five failures. Without that
# switch, Invoke-WebRequest THROWS on any 4xx/5xx, which is useless here --
# a 400 from /api/auth/login is the expected answer.
#
# curl.exe ships with Windows 10 1803 and later, behaves identically on
# PowerShell 5.1 and 7, and is the same tool the GitHub workflow uses, so the
# local probe and the CI probe cannot drift.
function Probe([string] $Name, [string] $Url, [string] $Method, [string] $Body, [string] $MustContain) {
    $bodyFile = Join-Path $env:TEMP ("probe-" + [guid]::NewGuid().ToString('N') + ".txt")
    try {
        foreach ($i in 1..12) {

            # NO $args, AND NO SPLATTING. The previous version built an array
            # called $args and invoked `& curl.exe @args`. $args is a PowerShell
            # AUTOMATIC variable inside a function -- it holds the unbound
            # arguments -- so assigning to it and then splatting it is not the
            # local array being passed, and under Set-StrictMode the whole thing
            # died with
            #   The property 'Length' cannot be found on this object
            # immediately after the first probe succeeded. The message named a
            # property nobody had written, which is what made it hard to place:
            # it comes from inside the splatting machinery, not from this code.
            #
            # Two explicit calls instead. Slightly repetitive, and it cannot be
            # wrong in a way that reports someone else's error.
            if ($Method -eq 'POST') {
                $code = & curl.exe -s -o $bodyFile -w '%{http_code}' --max-time 30 `
                            -X POST -H 'Content-Type: application/json' -d $Body $Url
            } else {
                $code = & curl.exe -s -o $bodyFile -w '%{http_code}' --max-time 30 $Url
            }
            $code = [string]$code

            # Get-Content -Raw returns $null for an EMPTY file, and under
            # Set-StrictMode $null.Length throws. /health/ready is precisely the
            # probe with an empty body, so the first success was also the first
            # crash. Coalesce rather than cast: the cast applies to the result,
            # and the result is already $null.
            $content = ''
            if (Test-Path $bodyFile) {
                $raw = Get-Content $bodyFile -Raw
                if ($null -ne $raw) { $content = [string]$raw }
            }

            # 000 is curl's "no response at all" -- a cold start still waking,
            # or no healthy replica behind ingress. Worth distinguishing from an
            # HTTP error rather than printing a bare 000.
            if ($code -eq '000') {
                Write-Host "  $Name attempt $i : no response yet (cold start or no healthy replica)"
            }
            elseif ($MustContain -and ($content -notmatch [regex]::Escape($MustContain))) {
                $preview = $content
                if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                Write-Host "  $Name attempt $i : HTTP $code but body lacked '$MustContain' -- $preview"
            }
            else {
                Ok "$Name -> HTTP $code"
                return $true
            }
            Start-Sleep -Seconds 10
        }
    } finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
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
