<#
.SYNOPSIS
    Day 26. Generates real traffic, then runs the committed KQL against the
    workspace and saves the output as evidence — including whether a single
    operation stitches API, Service Bus worker and database.

.DESCRIPTION
    THE QUERIES ARE READ FROM Day26/kql RATHER THAN WRITTEN HERE. The same
    files are deployed as workspace saved searches and, for the error rate,
    embedded in the alert rule. One source of truth means the evidence this
    produces is evidence about the queries that actually ship, not about a
    convenient variant of them.

    IT CHECKS THE QUOTA FIRST, AND THAT IS NOT A FORMALITY. Day 25 lost an
    afternoon to queries that returned zero rows and looked exactly like a
    broken exporter. The workspace was OverQuota and silently dropping
    everything. A capped workspace makes every other result in this script
    meaningless, so it is the first thing established and a hard stop.

    WHY IT WRITES DATA. Proving the distributed trace requires crossing the
    asynchronous boundary, and only a WRITE does that: a GET never leaves the
    API. So the script registers a probe account and creates a quote, which
    exercises HTTP -> SQL -> outbox -> Service Bus -> consumer -> SQL. Reads
    alone would produce a confident-looking report that proves nothing about
    the half of the system this day exists to make legible.

    The probe account is named so it is obviously synthetic, and this is a dev
    environment. Do not point it at production without deciding that you want
    a real row in a real table.

.PARAMETER SkipTraffic
    Query only. Use when traffic already exists and you just want the report.

.PARAMETER WaitSeconds
    How long to wait for ingestion before querying. App Insights typically
    lands data in 2-5 minutes; the default errs long because an early query
    returning nothing is indistinguishable from a broken pipeline.

.EXAMPLE
    ./Day26/scripts/02-verify-telemetry.ps1
    ./Day26/scripts/02-verify-telemetry.ps1 -SkipTraffic
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',
    [string] $WorkspaceName  = 'log7mo4cimyk4vnk',
    [string] $ApiBaseUrl     = 'https://quotes-api-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io',
    [int]    $WaitSeconds    = 300,
    [switch] $SkipTraffic
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$kqlDir   = Join-Path $repoRoot 'Day26\kql'
$outDir   = Join-Path $repoRoot 'Day26\verification'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

# Native stderr under ErrorActionPreference Stop is a terminating error even
# when the command succeeded -- see the note in 01-github-oidc.ps1.
function Invoke-AzText {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $raw = & az @AzArgs 2>$null } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($raw -join "`n")
}
function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $text = Invoke-AzText $AzArgs
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Trim() -eq '[]') { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}


# THE COMMENTS THAT MAKE THESE QUERIES TRUSTWORTHY ARE WHAT STOPPED THEM RUNNING.
#
# Each .kql file opens with dozens of // lines explaining why it excludes health
# probes, why it sums ItemCount, why the error-rate floor exists. Passed to
# az.exe as one argument, the newlines do not reliably survive -- and a KQL
# query collapsed onto a single line is entirely commented out from its first
# // onwards. The result is ZERO ROWS AND NO ERROR, which is indistinguishable
# from "the pipeline is broken" and is what sent me looking at instrumentation,
# quotas and sampling while 592 AppRequests sat in the workspace.
#
# The comments stay in the files and in the deployed saved searches, where the
# portal renders multi-line KQL properly and where a human actually reads them.
# They are stripped only for command-line execution.
#
# The (?<!:) guard keeps the // in https:// intact -- several comments cite
# documentation URLs, and eating half a URL would corrupt the very lines this
# is trying to preserve.
#
# AND THE RESULT IS JOINED WITH SPACES, NOT NEWLINES, WHICH IS THE OTHER HALF
# OF THE BUG AND THE HALF THAT WAS ACTUALLY FATAL.
#
# Stripping the comments alone was not enough. The saved evidence from that
# attempt contained RAW, UNAGGREGATED AppRequests rows -- every column of
# every record -- which means the query az executed was the single word
# `AppRequests`. Only the FIRST LINE survived: the newlines do not make it
# through to az.exe as part of one argument, so every stage after the table
# name was silently discarded.
#
# That is why this failure was so persuasive. A truncated query is still
# VALID, so there is no error; it just answers a different and much broader
# question than the one asked. Combined with the comments, the same mechanism
# produced two different wrong answers -- "no rows" when the comment swallowed
# everything, and "all rows" when it did not -- and neither looked like a
# transport problem.
#
# KQL is whitespace-insensitive between operators, so a single line built with
# spaces is exactly equivalent to the multi-line original, and it cannot be
# truncated by a newline that never survives.
function Get-KqlQuery {
    param([Parameter(Mandatory)] [string] $Path)

    $clean = foreach ($line in (Get-Content $Path)) {
        $stripped = [regex]::Replace($line, '(?<!:)//.*$', '')
        if ($stripped.Trim() -ne '') { $stripped.Trim() }
    }
    return ($clean -join ' ')
}

Write-Host ''
Write-Host 'Day 26 -- telemetry verification' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die 'az is not on PATH.' }
az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Could not select the subscription. Run az login.' }

# ---------------------------------------------------------------------------
# 1. Is the workspace even accepting data?
# ---------------------------------------------------------------------------
Write-Host 'Workspace' -ForegroundColor Cyan
$ws = Invoke-AzJson @('monitor', 'log-analytics', 'workspace', 'show',
                      '-g', $ResourceGroup, '-n', $WorkspaceName, '-o', 'json')
if ($null -eq $ws) { Die "Could not read workspace $WorkspaceName." }

$wsid = $ws.customerId
$cap    = 'unset'
$status = 'unknown'
if ($ws.PSObject.Properties.Name -contains 'workspaceCapping' -and $null -ne $ws.workspaceCapping) {
    if ($ws.workspaceCapping.PSObject.Properties.Name -contains 'dailyQuotaGb')       { $cap    = $ws.workspaceCapping.dailyQuotaGb }
    if ($ws.workspaceCapping.PSObject.Properties.Name -contains 'dataIngestionStatus'){ $status = $ws.workspaceCapping.dataIngestionStatus }
}
Write-Host "  cap $cap GB/day, ingestion status: $status"

if ($status -eq 'OverQuota') {
    Note 'The workspace is OVER QUOTA and is dropping everything sent to it.'
    Note 'Every query below would return zero rows, and that would say nothing'
    Note 'about the pipeline. Stopping rather than producing a misleading report.'
    Note ''
    Note 'Check what is consuming it:'
    Note "  az monitor log-analytics query -w $wsid --analytics-query ""Usage | where TimeGenerated > ago(24h) | summarize GB=sum(Quantity)/1024 by DataType | order by GB desc"" -o table"
    exit 1
}
Ok 'Ingesting.'

# ---------------------------------------------------------------------------
# 2. Traffic, including one write that crosses the async boundary
# ---------------------------------------------------------------------------
if (-not $SkipTraffic) {
    Write-Host ''
    Write-Host 'Generating traffic' -ForegroundColor Cyan

    # WARM-UP FIRST, AND ITS STATUS IS REPORTED. minReplicas is 0, so the
    # first request after an idle period cold-starts the container and can
    # take half a minute. Firing ten requests at a scaled-to-zero app and
    # discarding the output produces "reads sent" whether or not any of them
    # arrived -- which is how the last run reported success and then found no
    # telemetry at all.
    $warm = curl.exe -s -o NUL -w '%{http_code}' --max-time 120 "$ApiBaseUrl/health/ready" 2>$null
    if ($warm -ne '200') {
        Note "Warm-up returned HTTP $warm. The app may be cold or unhealthy;"
        Note 'everything below will be thin or empty if it never served a request.'
    } else {
        Ok 'App is warm (health/ready 200).'
    }

    # READS COME AFTER AUTHENTICATION, because /api/quotes requires it. The
    # previous run reported "Reads sent: 0 of 10 returned 200 (codes: 401)" --
    # ten rejected requests. They are still recorded as requests, so they were
    # not useless, but a latency table built entirely from 401s describes the
    # authentication middleware rather than the endpoint. The reads are moved
    # below the login for that reason.


    # A deliberately synthetic identity. Deterministic per day so repeated runs
    # reuse one account rather than accumulating a new row every time.
    $probeEmail = "day26-probe-$(Get-Date -Format yyyyMMdd)@example.invalid"
    $probePass  = 'Day26-Probe-' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Date -Format yyyyMMdd))) + '!aA1'

    # BOTH CALLS REPORT THEIR STATUS AND BODY. The previous version discarded
    # them and said only "could not obtain a token", which is a symptom and
    # not a cause: a 400 from validation, a 409 from an existing account, a
    # 502 from a cold container and a timeout are four different problems with
    # four different fixes, and they were indistinguishable.
    # THE JSON GOES THROUGH A FILE, AND THAT IS WHY register RETURNED 400.
    #
    # `curl.exe -d '{"email":"..."}'` from PowerShell does not send that JSON.
    # PowerShell strips the double quotes on the way to a native command, so
    # curl receives {email:...,password:...}, the API cannot parse it, and the
    # answer is a 400 with an empty body -- which reads like a validation
    # failure on values that are in fact fine.
    #
    # 01-github-oidc.ps1 already passes Graph bodies through a file for exactly
    # this reason. I knew the hazard and still wrote it inline here.
    $regFile = Join-Path $env:TEMP 'day26-register-body.json'
    (@{ email = $probeEmail; password = $probePass } | ConvertTo-Json -Compress) |
        Out-File $regFile -Encoding ascii -NoNewline

    $regCode = curl.exe -s -o "$env:TEMP\day26-register.json" -w '%{http_code}' --max-time 60 `
                  -X POST "$ApiBaseUrl/api/auth/register" `
                  -H "Content-Type: application/json" --data-binary "@$regFile" 2>$null
    $regBodyText = ''
    if (Test-Path "$env:TEMP\day26-register.json") { $regBodyText = (Get-Content "$env:TEMP\day26-register.json" -Raw) }

    # 409 is success for this purpose: the account already exists from an
    # earlier run today, which is exactly what the deterministic name is for.
    if ($regCode -eq '200' -or $regCode -eq '201') { Ok "register -> HTTP $regCode" }
    elseif ($regCode -eq '409')                    { Ok  "register -> HTTP 409 (account already exists today, fine)" }
    else {
        Note "register -> HTTP $regCode"
        if (-not [string]::IsNullOrWhiteSpace($regBodyText)) { Note "  body: $($regBodyText.Trim())" }
    }

    $loginFile = Join-Path $env:TEMP 'day26-login-body.json'
    (@{ email = $probeEmail; password = $probePass } | ConvertTo-Json -Compress) |
        Out-File $loginFile -Encoding ascii -NoNewline

    $loginRaw = curl.exe -s -w "`nHTTP:%{http_code}" --max-time 60 `
                   -X POST "$ApiBaseUrl/api/auth/login" `
                   -H "Content-Type: application/json" --data-binary "@$loginFile" 2>$null

    # JOINED TO ONE STRING BEFORE -match, and this crashed the last run:
    #
    #   The variable '$Matches' cannot be retrieved because it has not been set.
    #
    # curl's multi-line output arrives as a string ARRAY, and -match against an
    # array behaves as a FILTER -- it returns the matching elements and never
    # populates $Matches. The if() was therefore truthy (a non-empty array)
    # while $Matches stayed unset, and Set-StrictMode turned reading it into a
    # terminating error. Against a single string, -match is a boolean and does
    # populate $Matches.
    $loginRaw = ($loginRaw -join "`n")

    $loginCode = 'unknown'
    if ($loginRaw -match 'HTTP:(\d+)\s*$') {
        $loginCode = $Matches[1]
        $loginRaw = $loginRaw -replace 'HTTP:\d+\s*$', ''
    }
    if ($loginCode -eq '200') { Ok "login -> HTTP 200" }
    else {
        Note "login -> HTTP $loginCode"
        if (-not [string]::IsNullOrWhiteSpace($loginRaw)) { Note "  body: $($loginRaw.Trim())" }
    }

    $token = $null
    if (-not [string]::IsNullOrWhiteSpace($loginRaw)) {
        try {
            $login = $loginRaw | ConvertFrom-Json
            foreach ($name in @('accessToken', 'token', 'access_token')) {
                if ($login.PSObject.Properties.Name -contains $name) { $token = $login.$name; break }
            }
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        Note 'Could not obtain a token, so no write was made.'
        Note 'The latency and dependency reports below are still valid; the'
        Note 'TRACE STITCH is not, because only a write crosses into the worker.'
        Note 'Re-run with credentials that work, or create a quote by hand first.'
    } else {
        Ok 'Authenticated as the probe account.'
        # Through a file, like the other two. This is THE request the whole
        # trace-stitch verdict depends on, so a silently mangled body here
        # would produce a NOT CONFIRMED that blamed traceparent for a
        # PowerShell quoting problem.
        $quoteFile = Join-Path $env:TEMP 'day26-quote-body.json'
        (@{ text = "Day 26 telemetry probe $(Get-Date -Format o)"; author = 'day26-probe' } |
            ConvertTo-Json -Compress) | Out-File $quoteFile -Encoding ascii -NoNewline

        $quoteCode = curl.exe -s -o "$env:TEMP\day26-quote.json" -w '%{http_code}' --max-time 60 `
                        -X POST "$ApiBaseUrl/api/quotes" `
                        -H "Content-Type: application/json" `
                        -H "Authorization: Bearer $token" --data-binary "@$quoteFile" 2>$null

        if ($quoteCode -eq '200' -or $quoteCode -eq '201') {
            Ok "Quote created (HTTP $quoteCode) -- the request that should span API, Service Bus and worker."
        } else {
            Note "Quote creation returned HTTP $quoteCode -- the write did NOT happen."
            $qBody = ''
            if (Test-Path "$env:TEMP\day26-quote.json") { $qBody = (Get-Content "$env:TEMP\day26-quote.json" -Raw) }
            if (-not [string]::IsNullOrWhiteSpace($qBody)) { Note "  body: $($qBody.Trim())" }
            Note 'The trace stitch verdict below cannot be trusted without it.'
        }

        # NOW the reads, with the token, so the latency table describes the
        # endpoint rather than the 401 path.
        $readCodes = @()
        1..10 | ForEach-Object {
            $readCodes += (curl.exe -s -o NUL -w '%{http_code}' --max-time 60 `
                              -H "Authorization: Bearer $token" "$ApiBaseUrl/api/quotes" 2>$null)
        }
        $ok = @($readCodes | Where-Object { $_ -eq '200' }).Count
        Ok "Authenticated reads: $ok of 10 returned 200 (codes: $((($readCodes | Sort-Object -Unique) -join ', ')))"
    }

    Write-Host ''
    Note "Waiting $WaitSeconds seconds for ingestion. An early query returning"
    Note 'nothing looks exactly like a broken pipeline, which is the confusion'
    Note 'this wait exists to avoid.'
    Start-Sleep -Seconds $WaitSeconds
}

# ---------------------------------------------------------------------------
# 3. Run the committed queries and save what they say
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Running the query pack' -ForegroundColor Cyan

$queries = @(
    @{ file = '01-latency-by-endpoint.kql';  out = 'latency-by-endpoint.txt';  title = 'p50/p95/p99 by endpoint' }
    @{ file = '02-dependency-breakdown.kql'; out = 'dependency-breakdown.txt'; title = 'Dependency breakdown by total time' }
    @{ file = '03-error-rate.kql';           out = 'error-rate.txt';           title = 'Error rate (the alert query)' }
    @{ file = '04-trace-stitch.kql';         out = 'trace-stitch.txt';         title = 'Distributed trace: API to worker to DB' }
)

foreach ($q in $queries) {
    $path = Join-Path $kqlDir $q.file
    if (-not (Test-Path $path)) { Note "Missing $($q.file)"; continue }

    $text = Get-KqlQuery -Path $path
    if ([string]::IsNullOrWhiteSpace($text)) { Note "$($q.file) is empty after stripping comments"; continue }

    $result = Invoke-AzText @('monitor', 'log-analytics', 'query', '-w', $wsid,
                              '--analytics-query', $text, '-o', 'table')

    $outPath = Join-Path $outDir $q.out
    $header = @(
        "Day 26 -- $($q.title)"
        "Query:  Day26/kql/$($q.file)   (verbatim; also deployed as a workspace saved search)"
        "Run at: $(Get-Date -Format o)"
        ''
    ) -join "`n"

    if ([string]::IsNullOrWhiteSpace($result)) {
        # An empty table is a RESULT, not an error, and the difference matters:
        # 03 returning nothing means the error rate is below the minimum-volume
        # floor, which is the query working correctly.
        $body = '(no rows)'
        Note "$($q.title): no rows"
    } else {
        $body = $result
        Ok $q.title
    }
    ($header + $body + "`n") | Out-File $outPath -Encoding utf8
}

# ---------------------------------------------------------------------------
# 4. Did the trace actually stitch?
# ---------------------------------------------------------------------------
# Asked as its own question rather than left to a human reading the table,
# because the answer is a specific shape: ONE OperationId carrying more than
# one AppRequest -- the HTTP call and the Service Bus consumer, which Azure
# Monitor records as a request because receiving a message is the worker's
# incoming operation.
Write-Host ''
Write-Host 'Trace stitch' -ForegroundColor Cyan

$stitchQuery = @'
let ops =
    AppDependencies
    | where TimeGenerated > ago(1h)
    | where DependencyType has "Service Bus" or Target has "servicebus.windows.net"
    | distinct OperationId;
union
    (AppRequests     | where TimeGenerated > ago(1h) and OperationId in (ops) | extend Kind = "request"),
    (AppDependencies | where TimeGenerated > ago(1h) and OperationId in (ops) | extend Kind = "dependency")
| summarize
    requests     = countif(Kind == "request"),
    dependencies = countif(Kind == "dependency"),
    kinds        = make_set(DependencyType)
  by OperationId
| where requests >= 2
| order by dependencies desc
'@

# Flattened for the same reason as the file-based queries above: a here-string
# is multi-line, and multi-line does not survive the trip.
$stitchOneLine = (($stitchQuery -split "`r?`n" | ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -ne '' }) -join ' ')

$stitch = Invoke-AzText @('monitor', 'log-analytics', 'query', '-w', $wsid,
                          '--analytics-query', $stitchOneLine, '-o', 'table')

$verdictPath = Join-Path $outDir 'trace-stitch-verdict.txt'
if ([string]::IsNullOrWhiteSpace($stitch)) {
    Note 'NOT CONFIRMED: no operation carries two requests.'
    Note 'That means either no write reached Service Bus in the last hour, or'
    Note 'traceparent is not surviving the hop -- in which case the API and the'
    Note 'worker produce two separate traces that each look perfectly healthy.'
    $verdict = @"
Day 26 -- distributed trace verdict: NOT CONFIRMED
Run at: $(Get-Date -Format o)

No OperationId in the last hour carries two or more AppRequests.

A correctly stitched write produces TWO requests under one OperationId: the
HTTP call, and the Service Bus consumer (Azure Monitor records a Consumer span
as a request, because receiving the message is the worker's own incoming
operation). Seeing one request and no second means one of:

  * no write crossed the boundary in the window -- a GET never leaves the API;
  * the outbox relay did not publish;
  * traceparent is not travelling, so the consumer started a NEW trace. This
    is the dangerous one: both halves look healthy in isolation and nothing
    reports an error. See ServiceBusQuoteEventPublisher (writes
    ApplicationProperties["traceparent"]) and QuoteEventProcessorService
    (reads it and calls SetParentId).
"@
} else {
    Ok 'CONFIRMED: at least one operation spans more than one request.'
    Write-Host ''
    Write-Host $stitch
    $verdict = @"
Day 26 -- distributed trace verdict: CONFIRMED
Run at: $(Get-Date -Format o)

At least one OperationId carries two or more AppRequests together with its
dependencies, which is the signature of a trace that survived the asynchronous
hop: the HTTP request and the Service Bus consumer share one operation, so the
worker's work is attributed to the request that caused it.

$stitch

The consumer appearing as a REQUEST rather than a dependency is correct and is
the part that looks wrong at first glance: Azure Monitor maps a Consumer span
to a request, because from the worker's point of view receiving the message is
the incoming operation.
"@
}
$verdict | Out-File $verdictPath -Encoding utf8

Write-Host ''
Ok "Evidence written to Day26/verification/"
Write-Host ''
