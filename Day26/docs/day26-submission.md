# Day 26 — App Insights + KQL

**Task.** Make production legible. Wire OpenTelemetry → App Insights, then
write KQL for p50/p99 by endpoint, the dependency call breakdown, and an alert
on error rate. Confirm distributed tracing stitches API → worker → DB.

**Exercise.** Paste the KQL + a screenshot of the alert. One line on what you'd
alert on and why.

Dev: subscription `85567e22-…`, resource group `thinkschool-dev-rg`, region
`uaenorth`. Workspace `log7mo4cimyk4vnk`, component
`appi-quotes-api-7mo4cimyk4vnk`.

## The precondition nobody asked for

Every query in this exercise returned nothing at first, and no alert could
have fired, because the workspace was `OverQuota` and silently dropping
ingestion — roughly 2.6 GB offered against a 1 GB/day cap.

The cause was one missing line. Serilog's `MinimumLevel.Override` covered
`Microsoft.AspNetCore`, EF Core commands and `OpenTelemetry`, but not `Azure` —
so `Azure.Identity` (MSAL writes a dozen INFO lines per token) and
`Azure.Messaging.ServiceBus` (both subscriptions polled every 60 s, forever)
logged at Information. That was ~1.8 of the 2.6 GB, **paid for twice**: once as
`ContainerAppConsoleLogs_CL`, again as `AppTraces` after Serilog re-exported
it. `"Azure": "Warning"` removes both and keeps every warning and error.

A capped workspace is worth understanding as a failure mode in its own right:
it does not reject writes loudly, it drops them, and every query then returns
an empty result that reads as "nothing is happening" rather than "you cannot
see".

## OpenTelemetry → App Insights

Already wired across Days 19–22 and authenticated on Day 25; this day
confirmed it end to end rather than rebuilding it. Live over six hours:

```
Type              Rows   Latest
AppRequests        592   2026-09-10T06:48:32Z
AppDependencies   2809   2026-09-10T06:48:33Z
AppTraces          779   2026-09-10T06:48:33Z
AppExceptions        0   —
```

Two things that matter came out of that table.

**Sampling is active at 12.5 %.** The dependency records carry
`microsoft.sample_rate: 12.5`, so one record in eight is stored with
`ItemCount: 8` as the multiplier. Every query in this pack uses
`sum(ItemCount)` rather than `count()`. I had written that guard on principle,
with a comment saying sampling was off "which is exactly why it is easy to
write count() and not notice for months" — I was wrong about the state, and
the guard turned out to be load-bearing. `count()` here under-reports by eight
times, silently.

**`AppExceptions` is empty.** Day 25 found 28,308 managed-identity failures in
a single hour and I explicitly declined to claim `AZURE_CLIENT_ID` had fixed
them, because ingestion had stopped and "no errors recorded" was not evidence.
Six hours of live ingestion with thousands of other rows arriving and zero
exceptions is the clean window that was missing. That closes it.

## KQL

Four queries under `Day26/kql/`, committed, deployed as workspace saved
searches from the same files via `loadTextContent`, and — for the error rate —
embedded in the alert rule from that same file. One source of truth: the alert
query and the query an operator runs while investigating cannot disagree.

### p50/p95/p99 by endpoint

```kql
AppRequests
| where TimeGenerated > ago(24h)
| where Name !startswith "GET /health"
| summarize
    requests = sum(ItemCount),
    p50      = round(percentile(DurationMs, 50), 1),
    p95      = round(percentile(DurationMs, 95), 1),
    p99      = round(percentile(DurationMs, 99), 1),
    failures = sumif(ItemCount, Success == false)
    by Endpoint = Name
| extend failureRatePct = round(100.0 * failures / requests, 2)
| where requests >= 5
| project Endpoint, requests, p50, p95, p99, failures, failureRatePct
| order by p99 desc
```

```
Endpoint              Requests  p50    p95    p99    Failures  FailureRatePct
POST /api/auth/login  12        12.0   607.3  607.3  10        83.33
GET /api/quotes/      31        0.7    54.6   71.4   29        93.55
```

Three deliberate choices. **Health probes are excluded** — Container Apps calls
`/health/live` and `/health/ready` every 10 s per replica, and they are the
fastest and most numerous requests, so including them drags every aggregate
toward "everything is fast". **The request count sits beside the percentile**,
because a p99 over four requests is just the slowest of four; `requests >= 5`
removes the worst of it and the column lets a reader judge the rest. **`Name`
is the route template**, not the URL, so `/api/quotes/1` and `/api/quotes/2`
aggregate instead of exploding into thousands of one-request groups.

The high failure rates are honest and are an artefact of the probe traffic:
the reads were rejected 400/401 before authentication was wired into the
script. Real numbers, unflattering, left as they are.

### Dependency call breakdown

```kql
AppDependencies
| where TimeGenerated > ago(24h)
| summarize
    calls    = sum(ItemCount),
    totalMs  = sum(DurationMs),
    p50      = round(percentile(DurationMs, 50), 1),
    p99      = round(percentile(DurationMs, 99), 1),
    failures = sumif(ItemCount, Success == false)
    by DependencyType, Target, Name
| extend
    totalSeconds   = round(totalMs / 1000.0, 2),
    msPerCall      = round(totalMs / calls, 1),
    failureRatePct = round(100.0 * failures / calls, 2)
| project DependencyType, Target, Name, calls, totalSeconds, msPerCall, p50, p99, failures, failureRatePct
| order by totalSeconds desc
```

```
DependencyType          Name                             Calls  TotalSec  ms/call  p50    p99
SQL                     SQL: quotes                      1612   5.05      3.1      1.1    35.2
SQL                     SQL: quotes  (tcp:…,1433)        1618   4.01      2.5      1.1    28.6
InProc | Microsoft.AAD  DefaultAzureCredential.GetToken     9   1.02    113.6     79.3   236.8
HTTP                    GET /msi/token                      9   0.92    101.9     76.9   191.2
Other                   Outbox publish                      1   0.46    461.2    461.2   461.2
InProc                  verify-password                     2   0.27    136.2     92.3   180.0
```

**Ordered by total time, not by p99, and the live data settles the argument.**
`SQL: quotes` runs at 3.1 ms per call — unremarkable — but 1612 calls, for
5.05 s. `Outbox publish` is the slowest single call in the system at 461 ms,
and costs 0.46 s in total. Sorted by p99 you would spend the afternoon on the
outbox; sorted by total time you correctly spend it on the query count. Total
time is the latency budget you are actually paying.

**And it surfaced a defect I was not looking for.** SQL appears twice, with
1612 and 1618 calls and two spellings of the same target
(`server | quotes` and `tcp:server,1433 | quotes`). Two near-identical counts
for the same work is double instrumentation: `AddEntityFrameworkCoreInstrumentation()`
and the Azure Monitor distro's own SqlClient instrumentation are both recording
every query. `ObservabilityExtensions` guards carefully against exactly this
for ASP.NET Core and HttpClient — its comment says double-registering "silently
corrupts every duration percentile and doubles the ingestion bill" — and the
same hazard was live for SQL the whole time. Every SQL total above is inflated
roughly twofold. Named here rather than fixed: it is a one-line change with a
real risk of removing SQL spans entirely, and it deserves its own verification
run.

### Error rate — the alert query

```kql
let MinRequests = 20;    // per five-minute bucket; below this the ratio is noise
AppRequests
| where TimeGenerated > ago(1h)
| where Name !startswith "GET /health"
| summarize
    total  = sum(ItemCount),
    failed = sumif(ItemCount, Success == false)
    by bin(TimeGenerated, 5m)
| where total >= MinRequests
| extend errorRatePct = round(100.0 * failed / total, 2)
| project TimeGenerated, errorRatePct, total, failed
| order by TimeGenerated desc
```

**Returns no rows against this environment, and that is the correct result.**
43 requests over 24 hours never reach 20 in any five-minute bucket, so the
floor suppresses the ratio entirely — which is the guard doing its job rather
than a query that failed.

## The alert

Deployed as infrastructure in `infra/modules/alerts.bicep`, not clicked in the
portal. Live in the stack:

```
Microsoft.Insights/actionGroups/quotes-oncall-dev
Microsoft.Insights/scheduledQueryRules/quotes-error-rate-dev
```

**What I'd alert on and why: the error-rate ratio, never the failure count.**
Twenty failures out of two hundred thousand requests is a healthy service;
two out of three is an outage. A metric alert on failed requests fires on the
first and misses the second, and only a query makes the denominator available.
That is worth the per-evaluation cost of a scheduled query rule.

**Three independent guards, because one is never enough on a service that
scales to zero.** The query returns nothing below 20 requests in a bucket; the
rule requires two consecutive failing periods, so a deployment's brief burst
cannot page anyone; and only then does the threshold apply — 5 % in dev, 2 %
in prod, because prod does not scale to zero and its windows carry real
traffic. At `minReplicas: 0`, one failure in a two-request window is 50 %, and
an alert that pages on that is muted within a week. A muted alert is worse
than no alert: it trains the recipient to ignore the one that matters.

`autoMitigate` is on, severity is 2 rather than 0, and the action group emails
a real address — an alert nobody receives is not an alert.

## Distributed tracing: API → worker → DB

**Partially confirmed, and the partial is the finding.**

One operation, `e08131d63e18b5798ae6ebee6039184c`, from a real `POST /api/quotes/`:

```
Detail                   Kind        DurationMs  SpanId            ParentSpanId
POST /api/quotes/        request       242.2      a592669f70d5be36  (root)
SQL :: SQL: quotes       dependency      1.5      3733c7562b7653fe  a592669f70d5be36
SQL :: SQL: quotes       dependency      3.1      1a7fabc8f0fa010f  a592669f70d5be36
SQL :: SQL: quotes       dependency      2.7      a9a7e42d2fe10c7e  1a7fabc8f0fa010f
Other :: Outbox publish  dependency    461.2      8c49c5f554b171da  a592669f70d5be36
SQL :: SQL: quotes       dependency      7.7      0c3e5e1c175dc4a6  8c49c5f554b171da
…
```

**API → DB stitches, and so does API → outbox → DB.** The SQL spans are
children of the request, the publish is a child of the request, and further SQL
is nested under the publish span — one operation id across all of it, with the
parent/child chain intact.

**API → worker does not stitch.** The whole trace contains exactly **one**
request span and three span kinds: the HTTP request, SQL, and `Outbox publish`.
A correctly stitched write would show a *second* `AppRequest` — Azure Monitor
maps a Consumer span to a request, because receiving a message is the worker's
own incoming operation. There is no such span.

Two concrete causes, both evidenced rather than guessed:

**The Azure SDK's Service Bus spans are never collected.**
`ObservabilityExtensions` calls `AddSource("Azure.Messaging.ServiceBus")` and
no such dependency exists in 24 hours of data — the publish is visible only
through the app's own `Outbox publish` span from `QuotesActivitySource`. The
SDK names its sources per client type (`Azure.Messaging.ServiceBus.ServiceBusSender`
and friends) and `AddSource` matches exactly rather than by prefix, so a
wildcard is required. The hop is traced by our span, not the SDK's, which is
thinner coverage than the code claims.

**And some spans are created but never exported.** Two `ParentSpanId` values in
this trace — `c49b8dec3736b542` and `5d50c538a10d4608` — **do not appear as any
`SpanId`**. Orphaned parents are proof that spans exist which are not reaching
App Insights: SQL calls whose parent activity was dropped. That is what an
unregistered `ActivitySource` looks like from the query side, and it is the
strongest single piece of evidence here.

So the mechanism the code implements is sound — `ServiceBusQuoteEventPublisher`
writes `traceparent` into `ApplicationProperties`, `QuoteEventProcessorService`
reads it and calls `SetParentId` — and the *collection* is incomplete. Claiming
the trace stitches API → worker → DB would be untrue, and claiming it is broken
would also be untrue. It is API → DB confirmed, worker unconfirmed, with the
next step identified.

## What cost the most time, and why it is worth recording

The four queries returned "no rows" through several rounds while 592 requests
sat in the workspace. Three separate transport bugs produced that same
sentence:

1. **Comments commented out the queries.** Each `.kql` file opens with dozens
   of `//` lines; passed as one argument the newlines did not survive, and a
   KQL query collapsed onto one line is commented out from its first `//`
   onwards. Valid, empty, no error.
2. **Only the first line arrived.** Once comments were stripped, the saved
   evidence contained raw unaggregated rows — because the query az executed was
   the single word `AppRequests`. A truncated KQL query is still valid; it just
   answers a broader question.
3. **My own helper hid the errors.** `Invoke-AzText` returned `$null` on any
   non-zero exit, so a genuine KQL failure arrived as "no rows" — a statement
   about the data when it was a statement about the query.

The fix for all three was to stop putting PowerShell between the query and the
service: az reads `@file` itself, so neither newlines nor the embedded double
quotes in `Name !startswith "GET /health"` are ever mangled, and the bytes
executed are the bytes committed and deployed.

The lesson is the one this whole day is about. **An empty result and a failed
query are different facts, and a tool that reports them identically will send
you looking in the wrong place every time.** I spent rounds on instrumentation,
sampling and quotas — and wrote a hypothesis that the app had been
half-instrumented since Day 19, which was wrong — because my own verification
tool was doing precisely the thing I had written a day's worth of commentary
about.
