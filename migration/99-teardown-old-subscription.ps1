<#
.SYNOPSIS
    Removes everything this project owns in the OLD subscription, once the new
    one is verified. Destructive, deliberate, and it refuses to be casual.

.DESCRIPTION
    RUN THIS LAST, AND ONLY AFTER 90-verify-no-old-ids.ps1 IS CLEAN AND THE NEW
    ENVIRONMENTS ANSWER. Until then the old subscription is the only place the
    system exists, and deleting it removes the thing you would otherwise roll
    back to.

    WHY DEPLOYMENT STACKS MAKE THIS SHORT. Both environments were deployed as
    stacks with --action-on-unmanage deleteAll, so the stack OWNS its resources
    and deleting it takes them with it. A plain deployment would have left every
    resource behind with nothing recording which deployment created it, and the
    cleanup would be a hunt through a resource group.

    WHAT IT DOES NOT DELETE, ON PURPOSE:

      * The old DIRECTORIES. A tenant is free, it does not expire with a
        subscription's credit, and other things may still reference it. Deleting
        a directory is irreversible in a way deleting a resource group is not.
      * App registrations in those directories. They authenticate nothing here
        any more, but they are also costing nothing, and removing them is a
        separate decision with a separate blast radius.
      * Anything outside the two stacks. If something was created by hand in
        that subscription, this script will not find it -- which is why it
        finishes by LISTING what survives rather than claiming the subscription
        is empty.

.PARAMETER Force
    Skip the typed confirmation. Intended for a re-run after a partial failure,
    not for the first run.

.EXAMPLE
    ./migration/99-teardown-old-subscription.ps1 -WhatIf
    ./migration/99-teardown-old-subscription.ps1
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]   $OldSubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string[]] $StackNames        = @('quotes-prod', 'quotes-dev'),
    [string[]] $ResourceGroups    = @('thinkschool-prod-rg', 'thinkschool-dev-rg', 'thinkschool-rg'),
    [switch]   $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# WHY NATIVE az CALLS GO THROUGH A HELPER.
#
# Windows PowerShell 5.1 turns anything a native command writes to STDERR into
# an ErrorRecord. With $ErrorActionPreference = 'Stop' that record is
# TERMINATING -- so `az` printing a harmless notice ("WARNING: The behavior of
# this command has been altered by the following extension: containerapp")
# kills the script, reported as NativeCommandError against the PowerShell line
# rather than as anything about az. `2>$null` does not help: the redirection
# still creates the record first.
#
# So: stderr is merged, ErrorRecords are filtered out, --only-show-errors keeps
# az quiet, and $LASTEXITCODE is what decides whether a call worked.
#
# The argument list is passed as an ARRAY, not as loose arguments: otherwise
# PowerShell tries to bind `-o` as a parameter name and fails with "the
# parameter name 'o' is ambiguous", because -OutVariable and -OutBuffer exist.
# ---------------------------------------------------------------------------
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

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Refuse to run while the new environment is unproven.
# ---------------------------------------------------------------------------
$verify = Join-Path $PSScriptRoot '90-verify-no-old-ids.ps1'
if (Test-Path $verify) {
    Note 'Checking that the repository no longer points at this subscription.'
    & pwsh -NoProfile -File $verify | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Die 'migration/90-verify-no-old-ids.ps1 is not clean. Finish the move before tearing down what you would roll back to.'
    }
    Ok 'repository is clean'
}

Invoke-Az @('account','set','--subscription',$OldSubscriptionId) | Out-Null
$account = Invoke-AzJson @('account','show','-o','json')
if ($null -eq $account -or $account.id -ne $OldSubscriptionId) {
    Die "Could not select the old subscription $OldSubscriptionId. Sign in to the tenant that owns it first."
}
Write-Host ''
Write-Host "About to delete, in subscription $($account.id) ($($account.name)):" -ForegroundColor Red
foreach ($s in $StackNames)     { Write-Host "  stack           $s" }
foreach ($g in $ResourceGroups) { Write-Host "  resource group  $g  (if the stack leaves it behind)" }
Write-Host ''

if (-not $Force -and -not $WhatIfPreference) {
    $answer = Read-Host "Type the subscription id to confirm"
    if ($answer -ne $OldSubscriptionId) { Die 'Confirmation did not match. Nothing was deleted.' }
}

# ---------------------------------------------------------------------------
# Stacks first. Prod before dev: prod references the SHARED Container Apps
# environment that lives in dev's resource group, and deleting the owner of a
# referenced resource first is how a teardown gets stuck half done.
# ---------------------------------------------------------------------------
foreach ($stack in $StackNames) {
    Invoke-Az @('stack','sub','show','--name',$stack,'-o','none') | Out-Null
    $found = ($LASTEXITCODE -eq 0)
    if (-not $found) { Note "stack $stack does not exist -- nothing to delete"; continue }

    if ($PSCmdlet.ShouldProcess($stack, 'az stack sub delete --action-on-unmanage deleteAll')) {
        Write-Host "  deleting stack $stack ..." -ForegroundColor Yellow
        Invoke-Az @('stack','sub','delete','--name',$stack,'--action-on-unmanage','deleteAll','--yes') | Write-Host
        if ($LASTEXITCODE -ne 0) { Die "Deleting stack $stack failed. Nothing further attempted." }
        Ok "stack $stack deleted"
    }
}

# ---------------------------------------------------------------------------
# Then anything the stacks did not own. thinkschool-rg is from the very first
# manual az-cli exercise and was never managed by a stack, so it survives a
# stack delete and would keep billing quietly.
# ---------------------------------------------------------------------------
foreach ($rg in $ResourceGroups) {
    if ((Invoke-Az @('group','exists','--name',$rg)).Trim() -ne 'true') { Note "resource group $rg already gone"; continue }
    if ($PSCmdlet.ShouldProcess($rg, 'az group delete')) {
        Write-Host "  deleting resource group $rg ..." -ForegroundColor Yellow
        Invoke-Az @('group','delete','--name',$rg,'--yes','--no-wait') | Out-Null
        Ok "resource group $rg deletion started"
    }
}

# ---------------------------------------------------------------------------
# Finish by listing what SURVIVES. Not by claiming the subscription is empty --
# anything created by hand is invisible to a stack delete, and the only honest
# report is the one Azure gives.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'What remains in the old subscription:' -ForegroundColor Cyan
Invoke-Az @('group','list','--query','[].{name:name,location:location,state:properties.provisioningState}','-o','table') | Write-Host
Write-Host ''
Note 'Deletions with --no-wait finish in the background. Re-run this listing in a'
Note 'few minutes; anything still present was not owned by a stack and is yours to judge.'
Write-Host ''
Note 'The old DIRECTORIES and their app registrations are deliberately untouched.'
Note 'A tenant is free and deleting one is irreversible. That is a separate decision.'
Write-Host ''
