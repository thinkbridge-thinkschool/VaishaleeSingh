<#
.SYNOPSIS
    The gate. Fails while any identifier from the old subscription or the old
    tenants survives in live configuration, and while any SETME sentinel is
    still unfilled.

.DESCRIPTION
    "Nothing is on the old id" is a claim, and a claim about a repository is
    checkable. This is the check.

    IT LOOKS FOR TWO DIFFERENT KINDS OF PROBLEM.

      OLD IDENTIFIERS   a subscription id, a tenant id, an object id, an app
                        registration, or a resource name derived from the old
                        subscription's resourceToken. Any of these in live
                        configuration means something still points at
                        infrastructure that is going away.

      UNFILLED SENTINELS  SETME01 / SETME02 / SETME10. These are deliberate
                        placeholders, put there so that a stale value could not
                        silently survive the move. One left behind is a step
                        that was skipped, and it fails at deploy time instead
                        of here.

    WHAT IT DELIBERATELY DOES NOT SEARCH.

      docs/ and *submission*.md and *postmortem*.md are HISTORICAL RECORD. They
      describe work that really was done in the old subscription, against those
      exact ids. Rewriting them would make them lie. They are excluded by design
      rather than by oversight, and -IncludeDocs lists them if you want to see
      how many there are.

.EXAMPLE
    ./migration/90-verify-no-old-ids.ps1
    ./migration/90-verify-no-old-ids.ps1 -IncludeDocs
#>

[CmdletBinding()]
param(
    [switch] $IncludeDocs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot

$oldIdentifiers = [ordered]@{
    '85567e22-432e-4648-aa68-ba2714167694' = 'old subscription (Azure for Students)'
    '80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e' = 'older subscription'
    '8d46a076-d093-416d-a57b-8692cde13bf8' = 'old tenant'
    'f774bb68-0575-4cd2-9d4c-3b4e593d1110' = 'original tenant'
    'a59d00a8-a829-49b4-83d1-952727eea166' = 'old operator object id'
    'aad084c3-ebcf-495f-9c13-01415848fab4' = 'old SQL admin group object id'
    '18920fc7-79a5-42f0-bf65-c101749dd79b' = 'old dev API app registration'
    '5cb4e24e-86b4-4287-9f6d-4da55bcae1ac' = 'old prod API app registration'
    'e2255607-dc83-4747-9623-b73cc24ff62c' = 'old dev SPA app registration'
    '91566dbd-d857-488a-858d-475e60b309b7' = 'legacy API app registration'
    'e020d22f-8d9c-4e65-9240-9e3b0931270a' = 'old capstone API app registration'
    '7mo4cimyk4vnk'                        = 'old resourceToken (registry, SQL, Service Bus, workspace names)'
    'greenhill-88fb93d9'                   = 'old Container Apps default domain'
    'vaishalee.singh@s.amity.edu'          = 'old tenant UPN'
}

$sentinels = @('SETME01', 'SETME02', 'SETME10')

$skipDirs  = @('node_modules', 'bin', 'obj', '.git', '.angular', 'dist', '_staging', '_to_delete', 'TestResults', 'CoverageReport')
$textExt   = @('.ps1','.psm1','.bicep','.bicepparam','.json','.yml','.yaml','.md','.cs','.ts','.html','.sql','.env','.example','.config','.props','.targets','.slnx','.csproj')

function Test-IsHistory([string] $path) {
    $p = $path.Replace('\','/')
    return ($p -match '/docs/') -or ($p -match 'submission') -or ($p -match 'postmortem') -or ($p -match '/verification/')
}

$files = Get-ChildItem -Path $repoRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
    $parts = $_.FullName.Replace('\','/').Split('/')
    (-not ($parts | Where-Object { $skipDirs -contains $_ })) -and
    (($textExt -contains $_.Extension.ToLower()) -or ($_.Name -eq '.env'))
}

$liveHits    = New-Object System.Collections.Generic.List[string]
$historyHits = New-Object System.Collections.Generic.List[string]
$sentinelHits= New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
    $lines = Get-Content -Path $f.FullName -ErrorAction SilentlyContinue
    if ($null -eq $lines) { continue }
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\','/')
    $isHistory = Test-IsHistory $rel

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Two files necessarily CONTAIN old identifiers: this one, whose search
        # list they are, and the teardown script, which has to name the
        # subscription it deletes. Excluding exactly those two is not a
        # loophole -- excluding the whole migration folder would be, because a
        # stale id in 01-set-identities.ps1 is a real defect.
        $isSelf = ($rel -like '*90-verify-no-old-ids.ps1') -or
                  ($rel -like '*99-teardown-old-subscription.ps1')

        foreach ($needle in $oldIdentifiers.Keys) {
            if ((-not $isSelf) -and $line -like "*$needle*") {
                $entry = "{0}:{1}  [{2}]" -f $rel, ($i + 1), $oldIdentifiers[$needle]
                if ($isHistory) { $historyHits.Add($entry) } else { $liveHits.Add($entry) }
            }
        }
        # A sentinel only counts when it sits in a VALUE -- inside quotes, or
        # inside a URL. The parameter files and the READMEs also NAME the
        # sentinels in prose, explaining what fills them, and flagging those
        # would make this check cry wolf about its own documentation.
        if (-not $isHistory -and $rel -notlike 'migration*') {
            $sq = [char]39
            $dq = [char]34
            foreach ($s in $sentinels) {
                $inValue = ($line -match "$sq[^$sq]*$s") -or
                           ($line -match "$dq[^$dq]*$s") -or
                           ($line -match "https?://\S*$s")
                if ($inValue) {
                    $sentinelHits.Add(("{0}:{1}  [{2} not filled]" -f $rel, ($i + 1), $s))
                }
            }
        }
    }
}

Write-Host ''
Write-Host "Scanned $($files.Count) files under $repoRoot" -ForegroundColor Cyan
Write-Host ''

if ($liveHits.Count -gt 0) {
    Write-Host "OLD IDENTIFIERS IN LIVE CONFIGURATION ($($liveHits.Count)):" -ForegroundColor Red
    $liveHits | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ''
} else {
    Write-Host 'No old identifiers in live configuration.' -ForegroundColor Green
}

if ($sentinelHits.Count -gt 0) {
    Write-Host "UNFILLED SENTINELS ($($sentinelHits.Count)):" -ForegroundColor Yellow
    $sentinelHits | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  SETME01 -> ./migration/01-set-identities.ps1'
    Write-Host '  SETME02 -> ./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev|prod'
    Write-Host '  SETME10 -> ./migration/10-refresh-derived-names.ps1  (after dev deploys)'
    Write-Host ''
} else {
    Write-Host 'No unfilled sentinels.' -ForegroundColor Green
}

Write-Host "Historical references left in place on purpose: $($historyHits.Count)" -ForegroundColor DarkGray
if ($IncludeDocs -and $historyHits.Count -gt 0) {
    $historyHits | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
}
Write-Host '  (submissions and verification logs record what was done in the old' -ForegroundColor DarkGray
Write-Host '   subscription. Editing them would make them false.)' -ForegroundColor DarkGray
Write-Host ''

if ($liveHits.Count -gt 0 -or $sentinelHits.Count -gt 0) {
    Write-Host 'NOT CLEAN.' -ForegroundColor Red
    exit 1
}
Write-Host 'CLEAN. Nothing live points at the old subscription or the old tenants.' -ForegroundColor Green
exit 0
