<#
.SYNOPSIS
    Fills every SETME01 sentinel: who administers SQL, and who may seed the
    Key Vault. These are directory object ids, and a tenant move invalidates
    all of them.

.DESCRIPTION
    WHY THIS IS A SCRIPT AND NOT A NOTE SAYING "PASTE YOUR OBJECT ID".

    With azureADOnlyAuthentication there is no SQL login to fall back on. A
    wrong-but-well-formed object id therefore does not fail the deployment --
    it succeeds and leaves a server NOBODY CAN ADMINISTER, and the only repair
    is to redeploy the server. The failure mode of transcribing a GUID by hand
    is exactly the failure mode that is most expensive here, so nobody
    transcribes one.

    WHAT IT WRITES

      main.dev.bicepparam    sqlEntraAdminObjectId, sqlEntraAdminLogin
      main.prod.bicepparam   sqlEntraAdminObjectId, sqlEntraAdminLogin,
                             sqlEntraAdminPrincipalType, keyVaultWriterPrincipalId
      Day24/scripts/02-deploy-dev.ps1   its two matching defaults
      azd environment        SQL_ENTRA_ADMIN_LOGIN

    PROD PREFERS A GROUP, AND SAYS SO WHEN IT CANNOT HAVE ONE.
    A production database whose only administrator is one named individual
    loses its administrator when that person changes role. This creates
    quotes-sql-admins and adds the caller. If the tenant refuses group
    creation -- many do -- it falls back to the caller as a User and prints
    that as a stated deviation rather than adopting it quietly.

.PARAMETER WhatIf
    Report what would be written, and write nothing.

.EXAMPLE
    ./migration/01-set-identities.ps1 -WhatIf
    ./migration/01-set-identities.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId   = '33c82ead-36a8-4d8f-b969-d8476690c224',
    [string] $ExpectedTenantId = '803dced7-0a24-4857-8be8-280047561e95',
    [string] $AdminGroupName   = 'quotes-sql-admins',
    [switch] $SkipGroup
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$infra    = Join-Path $repoRoot 'Day7/piece2/infra'
$devParam = Join-Path $infra 'main.dev.bicepparam'
$prodParam= Join-Path $infra 'main.prod.bicepparam'
$deployDev= Join-Path $repoRoot 'Day24/scripts/02-deploy-dev.ps1'

foreach ($f in @($devParam, $prodParam, $deployDev)) {
    if (-not (Test-Path $f)) { Die "Not found: $f" }
}

# ---------------------------------------------------------------------------
# The tenant is checked before anything is read, because reading the WRONG
# directory succeeds and returns a plausible object id.
# ---------------------------------------------------------------------------
$account = Invoke-AzJson @('account','show','-o','json')
if ($null -eq $account) { Die "Not signed in. Run: az login --tenant $ExpectedTenantId" }
if ($account.tenantId -ne $ExpectedTenantId) {
    Die "Signed in to tenant $($account.tenantId), expected $ExpectedTenantId. Run: az login --tenant $ExpectedTenantId"
}
if ($account.id -ne $SubscriptionId) { Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null }
Ok "tenant $ExpectedTenantId, subscription $SubscriptionId"

# ---------------------------------------------------------------------------
# The operator
# ---------------------------------------------------------------------------
$me = Invoke-AzJson @('ad','signed-in-user','show','--query','{id:id, upn:userPrincipalName, name:displayName}','-o','json')
if ($null -eq $me -or [string]::IsNullOrWhiteSpace($me.id)) {
    Die 'Could not read the signed-in user. A service principal cannot run this step; sign in as yourself.'
}
$operatorId  = $me.id
$operatorUpn = $me.upn
$operatorName = $me.name

# THE SQL ADMINISTRATOR LOGIN IS A DISPLAY NAME, NOT A UPN, AND THE DIFFERENCE
# IS NOT COSMETIC.
#
# `sid` identifies the principal; `login` is a label beside it. The CLI says so
# in its own parameter names: az sql server ad-admin create takes
# --display-name and --object-id. prod has always used a display name here
# ('quotes-sql-admins', the group's), and dev used a UPN only because the old
# tenant's UPN happened to be an ordinary address.
#
# It stopped being harmless the moment this account became a GUEST. A guest UPN
# is vaishalee_outlook.com#EXT#@tenant.onmicrosoft.com -- TWO '#' characters, and
# '#' begins the fragment in a URL. Deploying that as the login fails with
#
#   InvalidResourceIdSegment: The 'parameters.properties.administrators.sid'
#   segment in the url is invalid
#
# which names the WRONG property: sid is a perfectly good GUID, and the thing
# that broke the URL sits next to it. An error that points one field away is
# how an afternoon disappears.
if ([string]::IsNullOrWhiteSpace($operatorName)) {
    Note 'displayName is empty; falling back to the UPN for the SQL login.'
    $operatorName = $operatorUpn
} elseif ($operatorUpn -like '*#*') {
    Note "UPN contains '#' (a guest identity), so the SQL login uses the display name."
}

Ok "operator $operatorUpn"
Ok "object   $operatorId"
Ok "sql login $operatorName"

# ---------------------------------------------------------------------------
# The prod administrator: a group if the tenant allows it, else the operator
# ---------------------------------------------------------------------------
$prodAdminId    = $operatorId
$prodAdminLogin = $operatorName
$prodAdminType  = 'User'
$deviation      = $true

if (-not $SkipGroup) {
    $existing = (Invoke-Az @('ad','group','list','--display-name',$AdminGroupName,'--query','[0].id','-o','tsv')).Trim()
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        $prodAdminId = $existing; $prodAdminLogin = $AdminGroupName; $prodAdminType = 'Group'; $deviation = $false
        Ok "group $AdminGroupName already exists ($existing)"
    } elseif ($PSCmdlet.ShouldProcess($AdminGroupName, 'create Entra group')) {
        $created = (Invoke-Az @('ad','group','create','--display-name',$AdminGroupName,'--mail-nickname',$AdminGroupName,'--query','id','-o','tsv')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($created)) {
            Invoke-Az @('ad','group','member','add','--group',$AdminGroupName,'--member-id',$operatorId) | Out-Null
            $prodAdminId = $created; $prodAdminLogin = $AdminGroupName; $prodAdminType = 'Group'; $deviation = $false
            Ok "created group $AdminGroupName ($created), added $operatorUpn"
        } else {
            Note 'Group creation was refused by this tenant.'
        }
    }
}

if ($deviation -and $WhatIfPreference) {
    # -WhatIf makes ShouldProcess return false, so the group was not created and
    # $deviation is still true. Saying "prod will be administered by one user"
    # here would be reporting an artefact of the dry run as a finding, which is
    # exactly the kind of false alarm that teaches people to skim warnings.
    Note 'WhatIf: the group would be created on a real run. No deviation is implied.'
} elseif ($deviation) {
    Note 'STATED DEVIATION: prod will be administered by ONE NAMED USER, not a group.'
    Note 'A production database whose only administrator is one person loses its'
    Note 'administrator when that person changes role. Record this, do not forget it.'
}

# ---------------------------------------------------------------------------
# Writing. One helper, so every file is rewritten the same way and a re-run
# replaces rather than stacks.
# ---------------------------------------------------------------------------
function Set-Line {
    param(
        [Parameter(Mandatory)] [string] $File,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Replacement
    )
    $content = Get-Content -Path $File -Raw
    if ($content -notmatch $Pattern) {
        Note "no line matching /$Pattern/ in $(Split-Path -Leaf $File) -- left alone"
        return $false
    }
    # An INSTANCE regex, because the static Replace has no (input, evaluator,
    # count) overload -- passing 1 there silently binds to RegexOptions.IgnoreCase
    # and replaces every match instead of the first.
    $rx = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement }
    $updated = $rx.Replace($content, $evaluator, 1)
    if ($updated -eq $content) { return $false }
    if ($PSCmdlet.ShouldProcess($File, 'write')) {
        Set-Content -Path $File -Value $updated -NoNewline
    }
    return $true
}

Write-Host ''
Write-Host 'Writing:' -ForegroundColor Cyan

Set-Line -File $devParam -Pattern "(?m)^param sqlEntraAdminObjectId = '[^']*'" -Replacement "param sqlEntraAdminObjectId = '$operatorId'" | Out-Null
Set-Line -File $devParam -Pattern "(?m)^param sqlEntraAdminLogin = '[^']*'"    -Replacement "param sqlEntraAdminLogin = '$operatorName'" | Out-Null
Ok "$devParam"

Set-Line -File $prodParam -Pattern "(?m)^param keyVaultWriterPrincipalId = '[^']*'" -Replacement "param keyVaultWriterPrincipalId = '$operatorId'" | Out-Null
Set-Line -File $prodParam -Pattern "(?m)^param sqlEntraAdminObjectId = '[^']*'"     -Replacement "param sqlEntraAdminObjectId = '$prodAdminId'" | Out-Null
Set-Line -File $prodParam -Pattern "(?m)^param sqlEntraAdminLogin = '[^']*'"        -Replacement "param sqlEntraAdminLogin = '$prodAdminLogin'" | Out-Null
Set-Line -File $prodParam -Pattern "(?m)^param sqlEntraAdminPrincipalType = '[^']*'"-Replacement "param sqlEntraAdminPrincipalType = '$prodAdminType'" | Out-Null
Ok "$prodParam"

Set-Line -File $deployDev -Pattern "(?m)^\s*\[string\] \`$SqlAdminObjectId = '[^']*'" -Replacement "    [string] `$SqlAdminObjectId = '$operatorId'" | Out-Null
Set-Line -File $deployDev -Pattern "(?m)^\s*\[string\] \`$SqlAdminLogin\s*= '[^']*'"  -Replacement "    [string] `$SqlAdminLogin    = '$operatorName'" | Out-Null
Ok "$deployDev"

# azd reads main.parameters.json, which reads these two from the environment.
$azdDir = Join-Path $repoRoot 'Day7/piece2'
if ($PSCmdlet.ShouldProcess('azd environment', 'set SQL_ENTRA_ADMIN_LOGIN and AZURE_PRINCIPAL_ID')) {
    # azd goes through the same stderr guard as az, and for the same reason:
    # it prints an "Update available: x -> y" banner on STDERR, which under
    # $ErrorActionPreference = 'Stop' becomes a terminating ErrorRecord. The
    # first version of this script caught that and reported "azd not on PATH",
    # which was not true and sent the reader looking in the wrong place.
    Push-Location $azdDir
    try {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & azd env set SQL_ENTRA_ADMIN_LOGIN $operatorName 2>&1 | Out-Null
            $okLogin = ($LASTEXITCODE -eq 0)
            & azd env set AZURE_PRINCIPAL_ID $operatorId 2>&1 | Out-Null
            $okId = ($LASTEXITCODE -eq 0)
        } finally { $ErrorActionPreference = $previous }

        if ($okLogin -and $okId) {
            Ok 'azd environment updated (SQL_ENTRA_ADMIN_LOGIN, AZURE_PRINCIPAL_ID)'
        } else {
            Note 'azd refused one or both values. Set them by hand, from Day7/piece2:'
            Note "  azd env set SQL_ENTRA_ADMIN_LOGIN $operatorName"
            Note "  azd env set AZURE_PRINCIPAL_ID $operatorId"
        }
    } catch {
        Note 'azd is not on PATH. Set both by hand, from Day7/piece2:'
        Note "  azd env set SQL_ENTRA_ADMIN_LOGIN $operatorName"
        Note "  azd env set AZURE_PRINCIPAL_ID $operatorId"
    } finally { Pop-Location }
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  1. git diff Day7/piece2/infra Day24/scripts/02-deploy-dev.ps1'
Write-Host '  2. ./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev   (fills SETME02)'
Write-Host '  3. ./migration/README.md continues from there.'
Write-Host ''
