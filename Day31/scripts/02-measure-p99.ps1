<#
.SYNOPSIS
    Measures the p99 of the hottest path with bombardier, and saves the
    transcript plus the query plan.

.DESCRIPTION
    SAME TOOL AS DAY 11, deliberately. bombardier -c 20 -d 30s is the load Day
    11 used for its p99 work, so the numbers here are shape-comparable with that
    submission rather than being a new instrument nobody can calibrate against.
    k6 would be the upgrade the day a perf THRESHOLD needs to fail CI, or the
    day the path being measured takes more than one request; neither is true
    today, and swapping tools to look thorough costs comparability.

    TWO THINGS DAY 11 LEARNED THE HARD WAY, BOTH ENCODED HERE.

    A p99 needs enough samples to be a percentile. Day 11's baseline p99 rested
    on twenty requests, where p99 and max were necessarily the same number, and
    its submission says so rather than quoting the figure straight. Thirty
    seconds at 20 connections against a fast endpoint gives tens of thousands of
    samples, so that is not a risk here -- but the run below PRINTS the request
    count, because a p99 whose sample size is not visible is a number you cannot
    weigh.

    And a censored distribution is worse than none. Day 11's first baseline
    reported p99 = 10.04s, which was bombardier's default request timeout rather
    than the system's behaviour. --timeout is raised below so slow requests
    finish and get counted.

.PARAMETER Label
    'before' or 'after'. Names the transcript so the two runs cannot be confused
    once they are files rather than terminal output.

.EXAMPLE
    # with the Host running and the database seeded
    ./Day31/scripts/02-measure-p99.ps1 -Label before
    # apply the AsNoTracking + index change, dotnet ef database update, restart
    ./Day31/scripts/02-measure-p99.ps1 -Label after
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('before', 'after')] [string] $Label,

    [string] $BaseUrl = 'http://localhost:5080',
    [string] $Slug    = 'perf-probe-edition',

    # Day 11's load, unchanged. Comparing two runs means holding this fixed --
    # the single easiest way to produce a meaningless improvement is to measure
    # the second run under lighter load than the first.
    [int] $Connections = 20,
    [string] $Duration = '30s',
    [string] $Timeout  = '120s',

    [string] $SqlServer = 'localhost,1433',
    [string] $Database  = 'QuotesPlatform',
    [string] $SqlUser   = 'sa',
    [string] $SqlPassword = $env:CAPSTONE_SQL_PASSWORD,

    [string] $OutputDirectory = 'Day31/verification'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command bombardier -ErrorAction SilentlyContinue)) {
    throw @'
bombardier is not on PATH. Day 11 used it for the same measurement:
  winget install codesenberg.bombardier
  # or: go install github.com/codesenberg/bombardier@latest
'@
}

$url = "$BaseUrl/api/editions/$Slug"

# Fail early and loudly if the probe row is missing. A 404 measured at 20
# connections for 30 seconds produces a beautiful p99 for an endpoint that did
# no work, and nothing in bombardier's output says so.
$probe = Invoke-WebRequest -Uri $url -Method Get -SkipHttpErrorCheck
if ($probe.StatusCode -ne 200) {
    throw "GET $url returned $($probe.StatusCode). Run 01-seed-editions.ps1 first -- measuring a 404 is measuring nothing."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$transcript = Join-Path $OutputDirectory "p99-$Label.txt"

Write-Host "Measuring $url"
Write-Host "Load: -c $Connections -d $Duration --timeout $Timeout  (Day 11's load, held fixed)"
Write-Host ''

# A warm-up that is not measured. The first requests pay JIT, connection pool
# fill and EF's model build -- all one-time costs that would land in the
# measured p99 and would land unevenly between the two runs.
& bombardier -c $Connections -d 5s --timeout $Timeout -l $url | Out-Null

$output = & bombardier -c $Connections -d $Duration --timeout $Timeout -l $url 2>&1
$output | Write-Host

$header = @"
Day 31 -- p99 of the hottest path ($Label)
$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Endpoint : GET /api/editions/$Slug
Load     : bombardier -c $Connections -d $Duration --timeout $Timeout -l
Warm-up  : 5s at the same concurrency, discarded

"@

$header + ($output -join [Environment]::NewLine) | Set-Content -Path $transcript -Encoding utf8
Write-Host ''
Write-Host "Saved $transcript"

# The query plan matters as much as the number. A p99 that improved without the
# plan changing is a p99 that improved for some other reason -- caching, warm
# buffers, a quieter machine -- and the plan is the only thing that says which.
if (-not [string]::IsNullOrWhiteSpace($SqlPassword)) {
    $planFile = Join-Path $OutputDirectory "plan-$Label.txt"

    $planQuery = @"
SET NOCOUNT ON;
SET SHOWPLAN_TEXT ON;
GO
SELECT TOP 1 e.Id, e.CollectionId, e.EditionNumber, e.Name, e.Slug, e.OwnerId, e.PublishedAt
FROM publishing.Editions e
WHERE e.Slug = '$Slug'
ORDER BY e.EditionNumber DESC;
GO
"@

    $plan = & sqlcmd -S $SqlServer -U $SqlUser -P $SqlPassword -d $Database -C -b -Q $planQuery 2>&1
    if ($LASTEXITCODE -eq 0) {
        $plan | Set-Content -Path $planFile -Encoding utf8
        Write-Host "Saved $planFile"
        Write-Host ''
        Write-Host 'Look for: "Index Seek" on the composite index and NO "Sort" operator.'
        Write-Host 'A Sort still in the plan after the change means the index is not being used.'
    }
    else {
        Write-Warning "Could not capture the query plan: $plan"
    }
}
else {
    Write-Warning 'No SQL password supplied, so no query plan was captured. The number alone does not say WHY it changed.'
}

Write-Host ''
Write-Host @'
Reading the result honestly:
  * Compare p99 AND the request count. A p99 that improved while throughput
    fell is not an improvement.
  * If before and after overlap, say so. "Correct on reasoning, effect within
    noise at this volume" is a real finding; an invented win is not.
'@
