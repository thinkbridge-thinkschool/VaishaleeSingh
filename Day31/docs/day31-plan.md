# Day 31 — Polish: tests, perf, security

**Branch:** `day31-polish-tests-perf-security` off `dev`, **after PR #92 merges.**
Code changes in `Day22/Capstone` and `.github/workflows/ci.yml`; docs, scripts
and evidence in `Day31/`.

## Read the brief precisely

> Tests at every layer (unit, integration via WebApplicationFactory, one E2E),
> a perf pass (the p99 of your hottest path), and a security re-check. Green CI
> gate.

Four deliverables, and **three of the four do not exist today.** This is not a
tidy-up day; it is a day of first-time work wearing the word "polish".

| Brief asks for | Capstone has today |
|---|---|
| Unit tests | **Yes** — 31 domain + translator tests |
| Integration **via WebApplicationFactory** | **No.** 10 integration tests exist and deliberately bypass HTTP entirely |
| One E2E | Partly — `happy-path.ps1` against live infra, not automated |
| p99 of the hottest path | **Never measured.** No number exists |
| Green CI gate | Builds and tests; **no coverage gate on the capstone** |

## Gap analysis

### 1. There is no HTTP test in this solution at all

`QuotesPlatform.IntegrationTests` resolves handlers from the container and
calls them directly. That was the right call on Day 30 — it proved the handlers
work — but it means **no test has ever sent a request through the Host.**
Nothing covers routing, model binding, status codes, or the `DomainException →
400` mapping that every endpoint relies on.

Concretely untested: that `POST /api/collections` returns **201 with a Location
header**, that a domain failure returns **400 and not 500**, that
`?subject=Quote` binds at all, and that a malformed body is rejected before it
reaches an aggregate.

**The obstacle, and it is the day's main technical decision.** `Program.cs`
throws unless both a connection string and a Service Bus namespace are present,
and each module registers **two hosted services** — an outbox relay and (for
three modules) a consumer host. Under `WebApplicationFactory` those start for
real: eight background services, each constructing a `ServiceBusClient` with
`DefaultAzureCredential`, against a namespace that is not reachable from CI.

Three ways out, and the choice matters:

- **Remove `IHostedService` registrations in the test factory.** No production
  change at all; the factory says "I am testing the HTTP surface, not the
  workers". **Preferred.**
- A configuration flag on the Host (`Workers:Enabled=false`). Production code
  grows a branch that exists only for tests, and a flag that disables the
  outbox in production by misconfiguration is a very bad failure mode.
- A fake `ServiceBusClient`. Most work, least value — the workers are not what
  these tests are for.

Recording the rejected options because "why didn't you just add a flag" is the
first question a reviewer will ask.

### 2. The hottest path is `GET /api/editions/{slug}`, and it has two concrete defects

Every other endpoint is a curator or reviewer action — low volume by nature.
The edition read is the only **reader-facing** endpoint: one write, unbounded
reads. If anything in this system is hot, it is that.

Two findings, both visible by reading and both measurable:

**No `AsNoTracking()`.** `EfEditionRepository.GetLatestBySlugAsync` does
`.Include(e => e.Items)` on a tracked query for data that is **immutable by
design** — `Edition` has no setters and no mutating methods. Every read pays
change-tracker setup and identity-map cost for an entity that can never change.
Day 10 of this course covered exactly this; the capstone never applied it.

**The index supports the filter but not the sort.**
`EditionConfiguration` has `HasIndex(e => e.Slug)` (non-unique, correct — the
slug is stable across editions). The query filters on `Slug` then orders by
`EditionNumber` descending and takes the first. SQL Server can seek the slug but
must then sort the matches. A composite `(Slug, EditionNumber DESC)` turns it
into a seek plus a top-1 scan backwards.

**Exit criterion is a number, not an adjective.** A p99 before, a p99 after, and
the query plan for both — otherwise this is a code change with a story attached.

### 3. Security: the finding is the absence of auth, and it is being recorded rather than fixed

**Every endpoint in the capstone trusts an `actorId` supplied in the request
body.** `Collection.RequireOwner` compares that string to `OwnerId`, so any
caller who knows a collection id and its owner's id can rename it, add members,
submit it, or begin a revision. There is no authentication anywhere in
`Program.cs` — no `AddAuthentication`, no `RequireAuthorization`, nothing.

That is not a bug. It is Day 29's recorded decision — *"endpoints take a plain
`actorId` for now, the same way Day 2–3 built persistence before adding real
auth"* — carried forward unexamined for three days.

**Decision: record it, do not fix it today.** Real authentication is a full day,
and half-finished auth is worse than none because it looks handled. This follows
`day28-build-plan.md`'s own treatment of the two-scheme debt: an accepted risk
gets an ADR **with an expiry date**, because an accepted risk with no expiry is
a forgotten risk.

The re-check therefore produces a threat model for the capstone modelled on
`Day27/docs/day27-threat-model.md`, plus **ADR-0003** accepting the auth gap with
a date. Secondary findings to check while there: no rate limiting, no request
size limit, whether `DomainException` messages leak anything beyond what a user
should see (they are written as user-facing, so probably fine — but say so
deliberately), and whether the Host should set security headers the way
`Day27`'s nginx config does for the SPA.

### 4. The CI gate is weaker than it looks

The `capstone` job restores, builds and tests. It does **not** collect coverage
and has **no threshold** — the `Enforce coverage threshold` step exists only for
`Day5/piece2`. So "green CI gate" today means adding one.

**Two hazards, both already visible:**

The existing coverage job is **currently failing** at
`Upload merged coverage report` with a 403 from an intermediary on
`FinalizeArtifact`. Copying that job's shape for the capstone copies its
problem. Diagnose before reusing — it may be org artifact storage rather than
the workflow.

And the capstone test suite now **starts a Docker container** (Testcontainers).
It worked locally; it has never run in CI. That is a new way for the job to be
slow or flaky, and it should be proven before a coverage gate is stacked on top.

## Order, and the cut line

**Track A — WebApplicationFactory tests (half day).** The biggest hole and the
only one the brief names by technology. Everything else is easier once the Host
can be started in a test.

**Track B — perf pass (quarter day).** Measure, change, measure. Needs Track A's
factory for a repeatable harness, which is why it is second.

**Track C — CI gate (quarter day).** Coverage collection and a threshold on the
capstone job, plus proving Testcontainers runs on a GitHub runner.

**Track D — security re-check (quarter day).** Threat model plus ADR-0003. No
code.

**Cut line: A and C, or the day did not happen.** They are the two the brief
grades directly ("integration via WebApplicationFactory", "green CI gate"). B
without a before-and-after number is worth nothing and should be dropped whole
rather than half-measured. D is documentation and can be finished in the
evening if the code runs long.

## Exit criteria

Observable or they are not criteria.

1. A `QuotesPlatform.ApiTests` project using `WebApplicationFactory<Program>`,
   with hosted services removed, sharing the Testcontainers SQL fixture.
   Covers: 201 + Location on create, 400 not 500 on a domain failure,
   404 on a missing id, `?subject=Quote` binding, and one full
   submit → reject → resubmit → approve sequence through HTTP.
2. `Program` reachable from the test project — it is top-level statements, so
   this needs `InternalsVisibleTo` or a `public partial class Program {}`.
   Name it as a required step rather than discovering it.
3. A recorded p99 for `GET /api/editions/{slug}` before and after, at a stated
   concurrency and iteration count, with both query plans saved.
4. `.github/workflows/ci.yml`'s capstone job collects coverage and fails below a
   stated threshold, and that threshold is **chosen from the measured number**
   rather than picked from the air.
5. `Day31/docs/day31-threat-model.md` and `Day28/docs/adr/0003-*.md` recording
   the auth gap with an expiry date.

## What would break this

The Day 30 PR not merging. This branch assumes `dev` contains flow 3, the
integration tests and the per-test database fixture. Branching before that lands
means rebuilding the fixture twice.
