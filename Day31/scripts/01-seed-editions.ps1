<#
.SYNOPSIS
    Seeds published editions so the p99 measurement has something to measure.

.DESCRIPTION
    WHY THIS EXISTS, AND WHY IT IS THE ACTUAL WORK OF THE PERF PASS.

    GET /api/editions/{slug} against a database holding one edition with three
    items cannot show the effect of either change being made today. Change
    tracking on four objects is microseconds. A sort over one row is free. Run
    bombardier against that and you get "p99 4.1ms -> 3.9ms", which is noise
    wearing the costume of a result.

    Day 11's own submission names this failure mode from the other direction:
    its baseline p50 and p99 were both just bombardier's timeout ceiling, and it
    says outright that the danger is "a number that looks like data because it
    looks like data". Measuring a real change on trivial data is the same
    mistake with the sign flipped -- and the temptation afterwards is to report
    the difference anyway.

    So: seed enough editions that the slug index has something to seek through,
    and enough items per edition that the change tracker has something to track.

    WRITTEN AS SQL, NOT AS API CALLS, on purpose. Going through the real flow
    would mean a submit and an approval per collection, three broker hops each,
    for rows whose only job is to be in the way. That is hours for data that is
    scenery. The INSERTs below mirror exactly what CollectionPublishedHandler
    produces -- if the schema changes under them, that is a signal worth having.

.PARAMETER Editions
    How many published editions to create. Default 5000.

.PARAMETER ItemsPerEdition
    Items in each. Default 20, comfortably under Collection.MaxItems (50).

.EXAMPLE
    $env:CAPSTONE_SQL_PASSWORD = '<local container password>'
    ./Day31/scripts/01-seed-editions.ps1
    ./Day31/scripts/01-seed-editions.ps1 -Editions 20000 -ItemsPerEdition 30
#>
[CmdletBinding()]
param(
    [string] $SqlServer = 'localhost,1433',
    [string] $Database  = 'QuotesPlatform',
    [string] $SqlUser   = 'sa',
    [string] $SqlPassword = $env:CAPSTONE_SQL_PASSWORD,

    [int] $Editions = 5000,
    [int] $ItemsPerEdition = 20,

    # The slug the measurement will hit. Seeded LAST and deliberately in the
    # middle of the range rather than at either end: a slug that happens to be
    # the first or last row can be served from a boundary of the index and
    # flatter than the typical case.
    [string] $ProbeSlug = 'perf-probe-edition'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
    throw @'
No SQL password. Supply one of:
  $env:CAPSTONE_SQL_PASSWORD = '<the sa password of your local container>'
  ./Day31/scripts/01-seed-editions.ps1 -SqlPassword '<...>'
'@
}

function Invoke-Sql {
    param([string] $Query, [int] $TimeoutSeconds = 600)

    $output = & sqlcmd -S $SqlServer -U $SqlUser -P $SqlPassword -d $Database `
        -C -b -t $TimeoutSeconds -Q $Query 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed:`n$output"
    }

    return $output
}

Write-Host "Seeding $Editions editions x $ItemsPerEdition items into $Database on $SqlServer"
Write-Host 'This is a set-based insert, not a loop -- expect seconds, not minutes.'
Write-Host ''

# A single set-based INSERT built from a numbers CTE. A row-by-row loop for
# 5,000 editions and 100,000 items would take minutes and teach nothing.
$seed = @"
SET NOCOUNT ON;

;WITH n AS (
    SELECT TOP ($Editions) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO publishing.Editions (Id, CollectionId, EditionNumber, Name, Slug, OwnerId, PublishedAt)
SELECT
    NEWID(),
    NEWID(),
    1,
    CONCAT('Seeded collection ', i),
    CONCAT('seeded-collection-', i),
    CONCAT('curator-', i % 50),
    DATEADD(minute, -i, SYSUTCDATETIME())
FROM n;

;WITH items AS (
    SELECT TOP ($ItemsPerEdition) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS position
    FROM sys.all_objects
)
INSERT INTO publishing.EditionItems (EditionId, Position, QuoteId, Author, Text)
SELECT
    e.Id,
    i.position,
    NEWID(),
    CONCAT('Author ', i.position),
    CONCAT('Seeded quote text number ', i.position, ' for edition ', e.Slug)
FROM publishing.Editions e
CROSS JOIN items i
WHERE NOT EXISTS (
    SELECT 1 FROM publishing.EditionItems x
    WHERE x.EditionId = e.Id AND x.Position = i.position
);
"@

Invoke-Sql -Query $seed | Out-Null

# The probe row. Two editions at the same slug, so the ORDER BY in
# GetLatestBySlugAsync has an actual choice to make -- with one row per slug the
# sort is free and the index change would measure as nothing whatever the volume.
$probe = @"
SET NOCOUNT ON;
DECLARE @collection uniqueidentifier = NEWID();

DELETE i FROM publishing.EditionItems i
  JOIN publishing.Editions e ON e.Id = i.EditionId WHERE e.Slug = '$ProbeSlug';
DELETE FROM publishing.Editions WHERE Slug = '$ProbeSlug';

;WITH editions AS (SELECT 1 AS n UNION ALL SELECT 2)
INSERT INTO publishing.Editions (Id, CollectionId, EditionNumber, Name, Slug, OwnerId, PublishedAt)
SELECT NEWID(), @collection, n, 'Perf probe edition', '$ProbeSlug', 'curator-probe',
       DATEADD(minute, -10 * n, SYSUTCDATETIME())
FROM editions;

;WITH items AS (
    SELECT TOP ($ItemsPerEdition) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS position
    FROM sys.all_objects
)
INSERT INTO publishing.EditionItems (EditionId, Position, QuoteId, Author, Text)
SELECT e.Id, i.position, NEWID(), CONCAT('Author ', i.position),
       CONCAT('Probe quote text number ', i.position)
FROM publishing.Editions e CROSS JOIN items i
WHERE e.Slug = '$ProbeSlug';
"@

Invoke-Sql -Query $probe | Out-Null

$counts = Invoke-Sql -Query @"
SET NOCOUNT ON;
SELECT CONCAT('editions=', (SELECT COUNT(*) FROM publishing.Editions),
              ' items=',    (SELECT COUNT(*) FROM publishing.EditionItems),
              ' probe=',    (SELECT COUNT(*) FROM publishing.Editions WHERE Slug = '$ProbeSlug'));
"@

Write-Host ($counts | Where-Object { $_ -match 'editions=' })
Write-Host ''
Write-Host "Measure against: GET /api/editions/$ProbeSlug"
Write-Host 'Next: ./Day31/scripts/02-measure-p99.ps1'
