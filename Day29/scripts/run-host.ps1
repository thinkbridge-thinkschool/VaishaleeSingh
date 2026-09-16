<#
.SYNOPSIS
    Starts QuotesPlatform.Host against local SQL and the dev Service Bus
    namespace, with every setting it needs supplied explicitly.

.DESCRIPTION
    WHY THIS EXISTS. The Host needs three settings and takes none of them
    from a committed file: the connection string and the Service Bus
    namespace are deliberately empty in appsettings.json, and the listen URL
    has to be pinned or Kestrel picks a random HTTPS port that
    Invoke-RestMethod then rejects over the dev certificate.

    Supplying those as $env: assignments works, but $env: is per-process:
    a new terminal window starts with none of them, and the failure is
    "ConnectionStrings:Default is not set" -- which reads like a
    configuration bug rather than "you are in a different window". That
    cost several restarts during the first real run of the happy path.

    HTTP, NOT HTTPS, ON PURPOSE. Windows PowerShell 5.1's
    Invoke-RestMethod has no -SkipCertificateCheck, so the ASP.NET dev
    certificate makes every call in happy-path.ps1 fail on trust. Local
    verification runs over http; nothing here is reachable off the machine.

.EXAMPLE
    ./Day29/scripts/run-host.ps1
    ./Day29/scripts/run-host.ps1 -Port 5090
#>
[CmdletBinding()]
param(
    [string] $SqlServer = 'localhost,1433',
    [string] $Database  = 'QuotesPlatform',
    [string] $SqlUser   = 'sa',

    # Local container credential, supplied at the command line or from the
    # environment. Never defaulted to a literal here: a password in a
    # committed file is a password in every clone of the repository.
    [string] $SqlPassword = $env:CAPSTONE_SQL_PASSWORD,

    [string] $ServiceBusNamespace = 'sb-quotes-7mo4cimyk4vnk.servicebus.windows.net',
    [int]    $Port = 5080,

    # Raise to Debug when you need EF Core's per-command output back.
    [string] $LogLevel = 'Information'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
    throw @'
No SQL password. Supply one of:
  $env:CAPSTONE_SQL_PASSWORD = '<the sa password of your local container>'
  ./Day29/scripts/run-host.ps1 -SqlPassword '<...>'
This is the password you passed as MSSQL_SA_PASSWORD to `docker run`.
'@
}

# A Host left running in another window holds the port, and Kestrel's answer
# to that is a bind failure followed by roughly two hundred lines of unrelated
# shutdown noise: four relays looping against a disposed IServiceProvider and
# the Windows EventLog logger throwing while trying to report it. The real
# cause -- "you already have one of these running" -- is the first line and is
# gone off the top of the scrollback by the time you look. Say it here instead,
# and name the process so it can be stopped without hunting through windows.
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $name  = if ($owner) { "$($owner.ProcessName) (PID $($owner.Id))" } else { "PID $($listener.OwningProcess)" }

    throw @"
Port $Port is already in use by $name.
That is almost certainly a Host still running in another window. Stop it with:
  Stop-Process -Id $($listener.OwningProcess) -Force
or run this script on a different port:
  ./Day29/scripts/run-host.ps1 -Port 5090
"@
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$project  = Join-Path $repoRoot 'Day22/Capstone/src/QuotesPlatform.Host'

$env:ConnectionStrings__Default = "Server=$SqlServer;Database=$Database;User Id=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True"
$env:ServiceBus__FullyQualifiedNamespace = $ServiceBusNamespace
$env:ASPNETCORE_URLS = "http://localhost:$Port"
$env:Logging__LogLevel__Default = $LogLevel

# Everything except the password, so the log can be pasted into a review.
Write-Host "SQL          : $SqlServer/$Database as $SqlUser"
Write-Host "Service Bus  : $ServiceBusNamespace"
Write-Host "Listening on : http://localhost:$Port"
Write-Host "Health check : Invoke-RestMethod http://localhost:$Port/health"
Write-Host ""

dotnet run --project $project
