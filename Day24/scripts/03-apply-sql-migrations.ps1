<#
.SYNOPSIS
    Day 24. Applies the SQL Server migrations to a target database, from the
    provider's own migrations project, as a deployment step rather than at app
    startup.

.DESCRIPTION
    WHY THIS EXISTS AT ALL.

    QuotesApi cannot apply its own SQL Server migrations, and the reason is
    structural rather than an oversight:

      * QuotesApi.Migrations.SqlServer references QuotesApi, because it needs
        QuotesDbContext. QuotesApi references nothing, so that assembly is not
        deployed with the app and cannot be.
      * InfrastructureExtensions calls UseSqlServer(connection) without a
        MigrationsAssembly, so EF falls back to the assembly containing the
        DbContext -- QuotesApi -- whose Migrations/ folder holds the SQLITE
        migration set and the SQLite model snapshot.
      * MigrateAsync therefore diffed the SQL Server model against a SQLite
        snapshot, found differences, and threw PendingModelChangesWarning. In
        EF Core 10 that is an error, so the container exited before Kestrel
        bound a port: revision ActivationFailed, ingress with no healthy
        backend, and connection refusals rather than HTTP errors.

    Adding the reference the other way is circular. The structural fix is to
    extract QuotesDbContext into its own assembly; until then, the deployment
    applies migrations and Program.cs refuses to start if none are applied.

    This is also the ordinary practice for anything running more than one
    replica: two instances starting at once both call MigrateAsync, and EF's
    migration lock is all that stands between that and a race.

    WHAT IT DOES
      1. Generates an IDEMPOTENT script from QuotesApi.Migrations.SqlServer.
         Idempotent matters: every statement is wrapped in a check against
         __EFMigrationsHistory, so running this twice is a no-op rather than a
         pile of "object already exists" errors. That is what makes it safe to
         run on every deploy instead of only the first.
      2. Applies it with an Entra access token. No SQL password exists anywhere
         -- the server is Entra-only by design (see modules/sql.bicep).
      3. Prints the applied migrations back, read from the database rather than
         from the script, so the output is evidence and not an assumption.

.PARAMETER SqlServerFqdn
    e.g. sql-quotes-7mo4cimyk4vnk.database.windows.net

.PARAMETER DatabaseName
    Defaults to 'quotes'.

.PARAMETER ScriptOnly
    Generate the script and print where it is, then stop. Nothing touches the
    database. Use this first, and read the SQL.

.EXAMPLE
    ./Day24/scripts/03-apply-sql-migrations.ps1 `
        -SqlServerFqdn sql-quotes-7mo4cimyk4vnk.database.windows.net -ScriptOnly

    ./Day24/scripts/03-apply-sql-migrations.ps1 `
        -SqlServerFqdn sql-quotes-7mo4cimyk4vnk.database.windows.net
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SqlServerFqdn,
    [string] $DatabaseName = 'quotes',
    [switch] $ScriptOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$apiRoot  = Join-Path $repoRoot 'Day7\piece2'
$outDir   = Join-Path $repoRoot 'Day24\verification'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$scriptPath = Join-Path $outDir 'migrate-sqlserver.sql'

function Ok  ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host "Server:   $SqlServerFqdn"
Write-Host "Database: $DatabaseName"
Write-Host "Script:   $scriptPath"
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Generate the idempotent script
# ---------------------------------------------------------------------------
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { Die 'dotnet is not on PATH.' }

# --startup-project is the MIGRATIONS project, not QuotesApi. That is what
# SqlServerDesignTimeDbContextFactory is for: `dotnet ef` needs to construct a
# QuotesDbContext at design time and there is no Program.cs/DI container in a
# standalone class library to ask. The connection string in that factory is
# never opened -- generating a script only diffs the model against the
# migrations -- so this step needs no database and no network.
Push-Location $apiRoot
try {
    dotnet ef migrations script `
        --idempotent `
        --project QuotesApi.Migrations.SqlServer `
        --startup-project QuotesApi.Migrations.SqlServer `
        --context QuotesApi.Data.QuotesDbContext `
        --output $scriptPath
    if ($LASTEXITCODE -ne 0) { Die "dotnet ef migrations script failed (exit $LASTEXITCODE)." }
} finally { Pop-Location }

if (-not (Test-Path $scriptPath)) { Die "No script was written to $scriptPath." }
$lines = (Get-Content $scriptPath).Count
Ok "Generated $lines lines of SQL."

if ($ScriptOnly) {
    Note 'ScriptOnly: nothing was applied. Read the file before running without this switch.'
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Apply it, authenticating as a person via Entra
# ---------------------------------------------------------------------------
# Same transport choice as scripts/create-sql-user.ps1: prefer Invoke-Sqlcmd
# with an explicit access token, because it reports T-SQL errors as terminating
# PowerShell errors that a caller can actually act on.
$invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
if (-not $invokeSqlcmd) {
    Note 'Invoke-Sqlcmd not found. Installing the SqlServer module for the current user.'
    Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber
    Import-Module SqlServer
    $invokeSqlcmd = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
}
if (-not $invokeSqlcmd) { Die 'Could not obtain Invoke-Sqlcmd.' }

# The resource is the SQL audience, not ARM. A token for the wrong audience
# fails as "Login failed", which reads like a permissions problem.
$token = az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv
if ([string]::IsNullOrWhiteSpace($token)) { Die 'Could not get a SQL access token. Run az login.' }

# The firewall admits Azure services and whatever sqlAllowedClientIpAddresses
# named at deploy time. This connects as a PERSON from this machine, so if it
# fails on the firewall the fix is a redeploy with SQL_CLIENT_IP set -- not a
# hand-added rule, which would be invisible to the template and reported as
# drift by the idempotency check.
try {
    Invoke-Sqlcmd -ServerInstance $SqlServerFqdn `
                  -Database $DatabaseName `
                  -AccessToken $token `
                  -InputFile $scriptPath `
                  -QueryTimeout 300 `
                  -ErrorAction Stop | Out-Null
} catch {
    if ($_.Exception.Message -match 'not allowed to access the server') {
        Die "The SQL firewall refused this machine. Re-run the deployment with `$env:SQL_CLIENT_IP set: `$env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)"
    }
    Die "Applying the script failed: $($_.Exception.Message)"
}
Ok 'Script applied.'

# ---------------------------------------------------------------------------
# 3. Read the result back out of the database
# ---------------------------------------------------------------------------
# Deliberately queried rather than inferred from the script that just ran. The
# app makes the same check at startup and refuses to boot on an empty result,
# so this is the evidence that it will not.
$rows = Invoke-Sqlcmd -ServerInstance $SqlServerFqdn `
                      -Database $DatabaseName `
                      -AccessToken $token `
                      -Query 'SELECT MigrationId FROM __EFMigrationsHistory ORDER BY MigrationId' `
                      -ErrorAction Stop

if (-not $rows) { Die '__EFMigrationsHistory is empty after applying the script.' }

Write-Host ''
Write-Host 'Applied migrations:' -ForegroundColor Cyan
$rows | ForEach-Object { Write-Host "  $($_.MigrationId)" }
Write-Host ''
Ok "$($rows.Count) migration(s) applied. The app will start."

"Applied $($rows.Count) migrations to $SqlServerFqdn/$DatabaseName at $(Get-Date -Format o):" +
    "`n" + (($rows | ForEach-Object { "  " + $_.MigrationId }) -join "`n") |
    Out-File (Join-Path $outDir 'sqlserver-migrations-applied.txt') -Encoding utf8
Ok "Recorded in Day24/verification/sqlserver-migrations-applied.txt"
