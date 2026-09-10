# thinkschool

Training repository for the thinkbridge .NET programme. One folder per day.
Each day starts from the previous day's code and adds one layer, so the same
application — a small quotes API — is carried forward rather than rewritten,
and each day's folder is a working snapshot of what it looked like at the end
of that day.

The current, most complete version of the application is **`Day7/piece2`**.
It has been since Day 13: Day 6 was skipped, `Day7/piece2` started as a verified
byte-identical copy of `Day5/piece2`, and every day from 13 onward has added to
it in place rather than copying it forward. `Day5/piece2` is still what CI
builds (see "Working in this repo"), which is a gap rather than a statement
about which folder is current.

## Deployed environments

Two environments on one Azure subscription, deployed as separate Azure
Deployment Stacks (`quotes-dev`, `quotes-prod`) from the same template with
different parameter files.

| | API | Web |
|---|---|---|
| **dev** | [quotes-api-dev](https://quotes-api-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io/health) | [quotes-web-dev](https://quotes-web-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io) |
| **prod** | [quotes-api-prod](https://quotes-api-prod.greenhill-88fb93d9.uaenorth.azurecontainerapps.io/health) | [quotes-web-prod](https://quotes-web-prod.greenhill-88fb93d9.uaenorth.azurecontainerapps.io/quotes) |

The API links point at `/health`, which is the one endpoint worth clicking: a
200 there means the app booted (so its Key Vault reference resolved — the JWT
signing key is bound with `ValidateOnStart()` and a minimum length, so a
missing key is a startup failure) and that EF Core authenticated to an
Entra-only SQL server as its managed identity, where no password path exists to
explain the result.

**What differs, and what does not.** Prod has its own resource group, SQL
server and database, Service Bus namespace, Key Vault, container registry,
container apps, managed identity, Entra app registration, Log Analytics
workspace and alert rule. It shares exactly one thing with dev — the Container
Apps environment — because this subscription permits one in total
(`MaxNumberOfGlobalEnvironmentsInSubExceeded`). That is a constraint the
subscription imposed, not a design choice, and it means prod's app traffic
traverses infrastructure dev also uses. On a subscription allowing two, they
would be fully separate.

Prod also does not scale to zero: two always-on API replicas, a serverless SQL
database with auto-pause disabled, and geo-redundant backups. It therefore
bills continuously whether or not anyone uses it, and is torn down between
exercises with `az stack sub delete --name quotes-prod --action-on-unmanage
deleteAll` — so a link above may answer nothing at any given moment. Standing
prod back up is `Day24/scripts/05-promote-prod.ps1`.

**Deployment paths are separate too.** A merge to `main` deploys dev; a merge
to `production` deploys prod, through `.github/workflows/prod-deploy.yml` under
a GitHub Environment with a required reviewer. Prod does not rebuild — it
promotes the image dev already built and tested, with `az acr import`, so the
bytes that passed the tests are the bytes that run.

## The application

`QuotesApi` is an ASP.NET Core minimal API on .NET 10 with EF Core over SQLite
(SQL Server via Testcontainers in the integration suite). It exposes quotes and
user-owned collections of quotes, behind two authentication schemes — a
first-party JWT and Microsoft Entra ID — selected per request.

| Area | Where |
|---|---|
| Endpoints | `QuotesApi/Extensions/*EndpointExtensions.cs` |
| Domain model | `QuotesApi/Models` |
| Data access | `QuotesApi/Data`, `QuotesApi/Repositories` |
| Typed configuration | `QuotesApi/Configuration` |
| Cross-cutting middleware | `QuotesApi/Middleware` |
| Tracing setup | `QuotesApi/Extensions/ObservabilityExtensions.cs` |
| Messaging (publisher, consumers, idempotency) | `QuotesApi/Messaging` |
| Transactional outbox (writer, relay, retention) | `QuotesApi/Messaging/Outbox` |
| The write transaction that owns both | `QuotesApi/Services/QuoteWriteService.cs` |

## Days

**Day 1 — modelling.** `Day1/refactor-orders` refactors an anaemic order model
into one that owns its invariants; `Day1/piece2` applies the same idea to
quotes and collections. `Day1/piece2/RICH_MODEL_WHY.md` is the write-up.

**Day 2 — persistence.** EF Core, migrations, a repository seam, and the first
integration tests against a real SQL Server in a container.

**Day 3 — security and testing.** Password login with refresh tokens,
authorization policies including resource-based ownership checks, Entra ID as a
second scheme, and the unit / integration / SQL Server test split that the
later days keep running.

**Day 4 — operability.** Structured logging with Serilog and correlation IDs,
OpenTelemetry tracing exported to Jaeger and Azure Application Insights, typed
configuration with `IOptions` and startup validation, and a CI pipeline.
`Day4/piece2/docs/observability.md` covers the tracing setup.

**Day 5 — performance and packaging.** Diagnosing a slow endpoint from its
trace rather than by guessing: `Day5/piece2/docs/slow-endpoint-diagnosis.md`
walks an N+1 in `GET /api/collections` from the Jaeger trace that exposed it,
through the fix, to the test that stops it coming back. Then packaging the app
as a container image built from the project itself, with no Dockerfile —
`Day5/piece2/docs/containerising.md`, including the health-probe split and the
four things about it that were not obvious. Deployed to Azure Container Apps
two ways: by hand with `az cli` (`Day5/piece2/docs/azure-container-apps.md`),
and automated end-to-end with the Azure Developer CLI —
`Day5/piece2/docs/azd-deployment.md` walks the real bugs `azd up` surfaced (a
Container Apps Environment quota, an image-path mismatch, and an Alpine/RID
mismatch) and how each was actually fixed and verified against the live
endpoint; the verified results are in
`Day5/piece2/docs/day5-azd-submission.md`.

**Day 7 — joins and CTEs at depth.** Day 6 was skipped, so `Day7/piece2` is
`Day5/piece2` carried forward unchanged (verified byte-identical) with one
addition: `Day7/piece2/docs/sql/`, a set of T-SQL scripts written and run
against this app's own schema (the "Week-1 Quotes DB") rather than a
throwaway example table. `01-author-quote-summary.sql` is the required
exercise — each author with their quote count and most-recent quote, in one
statement, via a non-recursive CTE rather than a correlated subquery.
`02-join-practice.sql` and `03-recursive-cte-practice.sql` round out inner /
left / cross join and recursive-CTE fluency. `Quotes` has no timestamp
column to order "most recent" by (Day 6 would plausibly have added one) —
`Day7/piece2/docs/day7-joins-and-ctes-submission.md` explains the `Id`-as-
recency-proxy stand-in this uses instead, states it as an explicit
assumption rather than a silent one, and captures real output the queries
were verified against.

A second Day 7 exercise, `04-window-functions.sql`, covers `ROW_NUMBER`,
`RANK`/`DENSE_RANK`, `LAG`/`LEAD`, and a running total with `SUM() OVER
(ORDER BY ...)` against the same schema and seed data — including a direct
rewrite of `01-author-quote-summary.sql` with `ROW_NUMBER`, verified to
return identical output, to make the "aggregate collapses rows, a window
function decorates them" difference concrete rather than asserted. Details
in `Day7/piece2/docs/day7-window-functions-submission.md`.

**Day 13 — the front end.** `Day13/quotes-web` is an Angular 21 client for this
same API: standalone components throughout, no NgModules, no zone.js, and signals
as the only state mechanism. Every screen reads and writes through the real
endpoints — `/api/auth`, `/api/quotes`, `/api/collections` — and there is no mock
data in it.

Two things were added to the API for it, both in `Day7/piece2` in place rather
than as a copied snapshot, because a browser is the first client that needs
either: a CORS policy (`QuotesApi/Extensions/CorsExtensions.cs` — named origins,
no credentials, fails at startup on a malformed entry) and
`POST /api/auth/register`, since the API could verify a password but had no way to
set one. `Day13/docs/day13-angular-signals-zoneless-submission.md` is the write-up
and the verification report — including what could not be verified, namely that
the C# changes have not been compiled, because no .NET SDK was available where the
front end was built.

**Day 20 — the transactional outbox.** Day 19 published to Service Bus from
the request handler, after the write had already committed, with the publisher
swallowing every exception so the caller still got a 201 — and said out loud in
`ServiceBusQuoteEventPublisher` that an event lost that way was "lost unless
replayed from an outbox". Day 20 builds that outbox. `QuoteWriteService` commits
the domain change and an `OutboxMessages` row in one EF transaction;
`OutboxRelayService` claims rows with a provider-neutral conditional UPDATE,
publishes, then marks them Sent. No endpoint holds an `IQuoteEventPublisher`
any more, which is the observable part: nothing on the request path can reach
the broker.

What it does and does not guarantee is the interesting half.
`Day20/docs/day20-transactional-outbox-exercise.md` states it as at-least-once
with atomic intent, not exactly-once: publishing and marking are two systems
with no transaction between them, so a crash in that gap republishes — and
Day 19's `(MessageId, SubscriptionName)` primary key, over a deterministic
`EventId`, is what makes that duplicate a non-event rather than a second side
effect. At-least-once delivery, exactly-once effect. The crash tests in
`Quotes.Tests.Integration/OutboxCrashRecoveryTests.cs` assert each crash point
in turn, and `Day20/scripts/verify-crash-recovery.ps1` runs the manual proof —
a real `Stop-Process -Force` between commit and publish, with the pending row
asserted *before* the kill so that what follows is recovery and not a race that
happened to resolve.

## Running it

Prerequisites: .NET 10 SDK. Docker is needed only for the SQL Server
integration tests and for running Jaeger locally.

```bash
cd Day7/piece2
dotnet run --project QuotesApi
```

The API needs a JWT signing key, which is deliberately not in
`appsettings.json`. Supply it as a user secret:

```bash
dotnet user-secrets --project QuotesApi set "Jwt:Secret" "<at least 32 characters>"
```

Startup validation will fail fast with a readable message if it is missing or
too short, rather than failing later at token-signing time.

Optional, both off unless configured:

```bash
# Traces to a local Jaeger
dotnet user-secrets --project QuotesApi set "OpenTelemetry:OtlpEndpoint" "http://localhost:4317"

# Traces and logs to Azure Application Insights
dotnet user-secrets --project QuotesApi set "ApplicationInsights:ConnectionString" "<connection string>"
```

## Tests

```bash
cd Day7/piece2
dotnet test QuotesApi.slnx
```

Five test projects: `Quotes.Tests.Unit` (domain, services and the outbox relay;
no host), `QuotesApi.Tests` and `Quotes.Tests.Integration` (in-process host via
`WebApplicationFactory`), `Quotes.Tests.Integration.SqlServer` (Testcontainers)
and `Quotes.Tests.Integration.ServiceBus` (the Service Bus emulator plus a SQL
Server container). The last two **require Docker running** and are the tests
that fail first if it is not up; everything else, including all of the Day 20
outbox tests, runs without it.

`Outbox__RelayEnabled` and `ServiceBus__Enabled` must not be set in the shell
that runs the tests. All four test projects that boot the app force the relay
off in a `[ModuleInitializer]` for that reason — a test process inherits its
parent's environment, and a relay running inside the test hosts drains the rows
the outbox assertions read.

As a container (no Dockerfile — the image is built from the project):

```bash
cd Day7/piece2
dotnet publish QuotesApi --os linux-musl --arch x64 /t:PublishContainer
docker run --rm -p 8080:8080 -e Jwt__Secret="<at least 32 characters>" quotes-api:0.1.0
curl http://localhost:8080/health
```

The `Jwt__Secret` variable is required — user secrets do not exist inside a
container, and startup validation fails fast without it. The write-up is
`Day5/piece2/docs/containerising.md`, where it was written; the image now built
by the command above is `Day7/piece2`'s.

Coverage:

```bash
dotnet test QuotesApi.slnx --collect:"XPlat Code Coverage" \
  --settings coverlet.runsettings --results-directory:TestResults
reportgenerator -reports:"TestResults/**/coverage.cobertura.xml" \
  -targetdir:CoverageReport -reporttypes:Html
```

`--results-directory` matters. Without it each project writes into its own
`TestResults` folder and ReportGenerator will happily merge stale runs from
previous days, producing a report that never changes no matter what you edit.

## Working in this repo

- `main` is protected. Every task gets its own branch off an up-to-date `main`,
  and lands through a pull request that CI has passed.
- CI (`.github/workflows/ci.yml`) restores, builds and tests
  `Day5/piece2/QuotesApi.slnx` on every push and on every PR into `main`.
  **That is no longer the current solution.** All work from Day 13 onward lands
  in `Day7/piece2`, so CI has not built or run any of it — which is how the
  Day 7 SQL Server suite stayed red for weeks without anyone noticing (see the
  note in `Program.cs` about `EnsureCreated`). Pointing CI at
  `Day7/piece2/QuotesApi.slnx` is its own small change and is worth doing before
  the next day's work.
- Line endings: this repo stores LF and is worked on from Windows. Set
  `git config core.autocrlf true` once per clone. Without it every file shows
  as fully modified and real changes disappear into thousands of lines of
  line-ending noise.
- Build output (`bin/`, `obj/`), coverage output and local SQLite files are
  ignored and should never be committed.
