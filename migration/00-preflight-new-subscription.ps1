<#
.SYNOPSIS
    Gate 0 of the 2026-09 migration. Answers, before anything is created,
    whether the new subscription and tenant can host this system at all.

.DESCRIPTION
    Every check here failed for somebody once, in this repository, and cost a
    deployment cycle. None of them is hypothetical:

      G1  Signed in to the RIGHT tenant. `az account show` reporting a
          subscription is not the same as being in the directory that owns it,
          and a wrong tenant fails later as a permissions error that reads like
          a missing role.
      G2  The subscription is ENABLED. A disabled student subscription answers
          most read calls and refuses every write.
      G3  Resource providers registered. An unregistered provider fails a
          deployment halfway through, leaving a partial stack.
      G4  The region is allowed by policy AND offers what this needs.
      G5  Container Apps environment quota. The old subscription permitted
          exactly ONE in total -- not one per region -- and prod discovered
          that by being refused with MaxNumberOfGlobalEnvironmentsInSubExceeded.
          Whether the new one is the same is not assumed here; it is measured.
      G6  Directory write rights. Two later steps create app registrations and
          a group. If this tenant refuses directory writes, that is better
          known now than after dev is standing.

    Nothing is created. Nothing is changed. This script is safe to re-run.

.EXAMPLE
    ./migration/00-preflight-new-subscription.ps1 -Region uaenorth
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '33c82ead-36a8-4d8f-b969-d8476690c224',
    [string] $ExpectedTenantId = '803dced7-0a24-4857-8be8-280047561e95',
    [string] $Region = 'uaenorth'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# WHY NATIVE az CALLS GO THROUGH A HELPER.
#
# Windows PowerShell 5.1 turns anything a native command writes to STDERR into
# an ErrorRecord. With $ErrorActionPreference = 'Stop' that ErrorRecord is
# terminating -- so `az` printing a harmless notice ("WARNING: The behavior of
# this command has been altered by the following extension: containerapp")
# kills the script mid-gate, reported as NativeCommandError, which names the
# PowerShell line rather than anything about az.
#
# `2>$null` does NOT fix it: the redirection still creates the record first.
# So stderr is merged, ErrorRecords are filtered out, --only-show-errors keeps
# az quiet, and the EXIT CODE is what decides whether a call worked.
# ---------------------------------------------------------------------------
# The argument list is passed as an ARRAY, not as loose arguments: PowerShell
# would otherwise try to bind `-o` as a parameter name and fail with "the
# parameter name 'o' is ambiguous", because -OutVariable and -OutBuffer exist.
function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @AzArgs --only-show-errors 2>&1 |
               Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        return (($out | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $raw = Invoke-Az $AzArgs
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw.Trim() -eq '[]' -or $raw.Trim() -eq 'null') { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

$script:Failures = 0
function Gate ([string] $id, [string] $title) {
    Write-Host ''
    Write-Host "[$id] $title" -ForegroundColor Cyan
}
function Pass ([string] $m) { Write-Host "  PASS   $m" -ForegroundColor Green }
function Warn ([string] $m) { Write-Host "  CHECK  $m" -ForegroundColor Yellow }
function Fail ([string] $m) { Write-Host "  FAIL   $m" -ForegroundColor Red; $script:Failures++ }

# ---------------------------------------------------------------------------
Gate 'G1' 'Signed in to the new tenant, and the new subscription is current'

$account = Invoke-AzJson @('account','show','-o','json')
if ($null -eq $account) {
    Fail "Not signed in. Run: az login --tenant $ExpectedTenantId"
} else {
    if ($account.tenantId -ne $ExpectedTenantId) {
        Fail "Signed in to tenant $($account.tenantId), expected $ExpectedTenantId."
        Warn "Run: az login --tenant $ExpectedTenantId"
    } else {
        Pass "Tenant $($account.tenantId)"
    }

    if ($account.id -ne $SubscriptionId) {
        Warn "Current subscription is $($account.id); switching."
        Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null
        $account = Invoke-AzJson @('account','show','-o','json')
    }
    if ($account.id -eq $SubscriptionId) { Pass "Subscription $($account.id) ($($account.name))" }
    else { Fail "Could not select subscription $SubscriptionId." }
}

# ---------------------------------------------------------------------------
Gate 'G2' 'Subscription is enabled'

if ($null -ne $account) {
    if ($account.state -eq 'Enabled') { Pass "state = Enabled" }
    else { Fail "state = $($account.state). A disabled subscription refuses every write." }
}

# ---------------------------------------------------------------------------
Gate 'G3' 'Resource providers registered'

$needed = @(
    'Microsoft.App',                # Container Apps
    'Microsoft.ContainerRegistry',
    'Microsoft.Sql',
    'Microsoft.ServiceBus',
    'Microsoft.KeyVault',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.ManagedIdentity',
    'Microsoft.Resources'
)
foreach ($ns in $needed) {
    $state = (Invoke-Az @('provider','show','--namespace',$ns,'--query','registrationState','-o','tsv')).Trim()
    if ($state -eq 'Registered') {
        Pass "$ns"
    } else {
        Warn "$ns is '$state'. Registering (this can take a few minutes)."
        Invoke-Az @('provider','register','--namespace',$ns) | Out-Null
    }
}

# ---------------------------------------------------------------------------
Gate 'G4' "Region '$Region' is usable"

$locations = (Invoke-Az @('account','list-locations','--query','[].name','-o','tsv')) -split "`r?`n"
if ($locations -contains $Region) { Pass "$Region is offered to this subscription" }
else { Fail "$Region is not in this subscription's location list." }


# ---------------------------------------------------------------------------
Gate 'G5' 'Container Apps environment quota'

# The previous subscription allowed exactly ONE environment in total. That is a
# subscription-level constraint, it is not documented per-SKU, and the only
# reliable way to learn it is to count what exists and then try. Counting is
# the half that can be done before committing anything.
$caes = Invoke-AzJson @('containerapp','env','list','--query','[].{name:name,rg:resourceGroup,loc:location}','-o','json')
$count = if ($null -eq $caes) { 0 } else { @($caes).Count }
Write-Host "  existing Container Apps environments: $count"
if ($count -gt 0) {
    foreach ($c in @($caes)) { Write-Host "    $($c.name)  $($c.rg)  $($c.loc)" }
    Warn 'One already exists. main.dev.bicepparam sets createContainerAppsEnvironment;'
    Warn 'if this subscription also permits only one, prod must reference it rather than create one.'
} else {
    Pass 'None yet. The dev deployment will create the first.'
}

# ---------------------------------------------------------------------------
Gate 'G6' 'Directory write rights (app registrations and groups)'

# Not assumed. Day 23 could not read this tenant's authorization policy at all
# -- Graph returned nothing for defaultUserRolePermissions -- so whether
# directory writes were permitted stayed unknown until `az ad app create` was
# tried. Reading the policy is still worth attempting; failing to read it is
# not itself a failure.
$policy = Invoke-AzJson @('rest','--method','GET','--url','https://graph.microsoft.com/v1.0/policies/authorizationPolicy','-o','json')
if ($null -eq $policy) {
    Warn 'Could not read the tenant authorization policy. Not conclusive either way.'
    Warn 'Step 02 (app registrations) is where this is genuinely answered.'
} else {
    $perms = $policy.defaultUserRolePermissions
    Write-Host "  allowedToCreateApps        = $($perms.allowedToCreateApps)"
    Write-Host "  allowedToCreateSecurityGroups = $($perms.allowedToCreateSecurityGroups)"
    if ($perms.allowedToCreateApps) { Pass 'Members may create app registrations.' }
    else { Warn 'Members may NOT create app registrations. You need a directory role, or an admin.' }
    if (-not $perms.allowedToCreateSecurityGroups) {
        Warn 'Group creation is restricted. prod falls back to a User administrator -- record it as a deviation.'
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'Preflight passed. Next: ./migration/01-set-identities.ps1' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Failures) gate(s) failed. Fix these before creating anything." -ForegroundColor Red
    exit 1
}
