# Day 31 — Polish: tests, perf, security

**Branch:** `day31-polish-tests-perf-security`
**Target:** `Day22/Capstone` (the capstone), not `quotes-api`
**Date:** 2026-09-17

---

## What shipped

| Track | Deliverable | State |
|---|---|---|
| A | `QuotesPlatform.ApiTests` — 14 cases over the HTTP surface via `WebApplicationFactory` | Done, green |
| B | Perf pass on the hottest path: composite index + `AsNoTracking` | Change done; **timing inconclusive, see below** |
| C | Coverage-gated CI job for the capstone | **Written, not applied** — `ci.yml` is protected |
| D | Threat model + ADR-0003 on the missing authentication | Done |

**Tests: 58 → 72.** All green, build warning-free.

---

## The three artefacts the brief asks for

### 1. CI run (green)

**Run:** _to be filled from the first green run after the job is applied._

The capstone job has no coverage gate until the block in
`Day31/docs/ci-capstone-job.md` is pasted into `.github/workflows/ci.yml` by
hand — that file is protected against the tooling used here. Until then this
line is honestly blank rather than pointing at a run that proves something
weaker than it looks.

Expect the **first** run to fail: `THRESHOLD = 55.0` is a placeholder, to be
replaced by a number a few points below whatever that run measures. A threshold
chosen before the measurement tests nothing, so failing once is the design
working rather than a setback.

### 2. Test coverage at each layer

| Layer | Project | Tests | What it would catch that nothing else does |
|---|---|---|---|
| Unit — domain | `Modules.Curation.Domain.Tests` | 27 | Aggregate invariants: state guards, ownership, the item freeze after submission |
| Unit — application | `Modules.Moderation.Application.Tests` | 7 | The (subject, outcome) translation table, exhaustively — including the rejected quote that deliberately maps to nothing |
| Structural | `ArchitectureTests` | 8 | A module boundary violation, **the day the project reference is added** rather than the day someone writes code across it |
| Composition | `CompositionTests` | 6 | A DI registration that resolves at startup but not per-request — built from the same container the Host builds |
| Integration | `IntegrationTests` | 10 | Handler behaviour against real SQL Server 2022 via Testcontainers, one database per test |
| HTTP / E2E | `ApiTests` | 14 | Routing, model binding, status codes, and the `DomainException` → 400 mapping. **New today** |
| | **Total** | **72** | |

These are test counts, not line coverage. The percentage comes from the CI gate
in §1 and is not quoted here until that run exists — a coverage figure produced
by a different method than the one that will enforce it is a figure nobody can
check.

The two layers worth defending:

- **`ArchitectureTests` reads `.csproj` files rather than compiled assemblies.**
  A boundary is violated the moment the reference is added, not when code
  finally uses it, and that is the cheapest possible moment to catch it.
- **`ApiTests` uses local mirror records** for response shapes rather than the
  production types. A test that deserialises into the type the endpoint
  serialises from cannot notice a renamed field, because both sides move
  together.

### 3. Hot-path p99, before and after polish

`GET /api/editions/{slug}` — 5,002 editions × 20 items, probe slug carrying two
editions so the `ORDER BY` has a real choice. bombardier `-c 20 -d 30s`, Day 11's
load held fixed.

**Before** — standalone `IX_Editions_Slug`, tracking queries:

| p99 | req/s |
|---|---|
| 8.46ms | 5,122 |
| 47.34ms | 2,090 |
| 41.88ms | 2,144 |

**After** — composite `(Slug, EditionNumber DESC)` + `AsNoTracking`:

| p99 | req/s |
|---|---|
| 7.82ms | 6,004 |
| 14.21ms | 3,346 |
| 10.92 / 10.74 / 10.97ms | 3,658 / 3,717 / 3,741 |
| 59.93ms | 1,580 |
| 101.94ms | 1,698 |

**The ranges overlap, so no before/after figure is claimed.** Before spans
2,090–5,122 req/s; after spans 1,580–6,004. Picking one pair from each column
would let this section report an 8% improvement, a 4× improvement, or a
regression, all from the same ten runs. Which is the reason for reporting the
distributions instead of a pair.

What did change, and does not vary with machine load, is the execution plan:

```
before:  |--Sort(TOP 1, ORDER BY:([e].[EditionNumber] DESC))
              |--Index Seek(... [IX_Editions_Slug] ...)

after:   |--Top(TOP EXPRESSION:((1)))
              |--Index Seek(... [IX_Editions_Slug_EditionNumber] ... ORDERED FORWARD)
```

**A sort was removed from the hottest read.** That is the claim, it is proven
from the plan, and §Track B below covers how two earlier readings of these same
numbers were wrong.

---

## Track A — the first tests that send an HTTP request

The Day 30 integration tests resolve handlers from the container and invoke them
directly. That proves the handlers work and proves nothing about routing, model
binding, status codes, or the `DomainException` → 400 mapping every endpoint
depends on. **A handler that works behind an endpoint returning 500 is still a
broken feature**, and nothing in the suite would have said so.

14 cases now cover that gap. The two that earn their place most:

- `A_broken_domain_rule_is_a_400_with_a_reason` — every endpoint catches
  `DomainException` and maps it; nothing verified the mapping. An unmapped rule
  reaches a caller as a 500, which is an outage-shaped response to an ordinary
  validation failure.
- `The_review_lookup_binds_its_subject` — the `subject` query parameter was added
  on Day 30 because the lookup had hardcoded `ReviewSubject.Collection`. An
  optional parameter that silently fails to bind reproduces that bug exactly.

### The trap in the factory, recorded because it costs an afternoon

Each module registers hosted services — outbox relays and consumer hosts, eight
in total — which construct a `ServiceBusClient` with `DefaultAzureCredential`
against a namespace no test can reach. They have to go. The obvious way is
`services.RemoveAll<IHostedService>()`.

**That also removes ASP.NET Core's own `GenericWebHostService`, which is what
runs the request pipeline.** The result is a TestServer that starts cleanly and
answers nothing, which reads like a routing bug and is not one.

So the factory removes only descriptors whose implementation type sits under
`QuotesPlatform.*`, and `No_module_background_service_runs_under_the_test_host`
asserts they are gone — because a future namespace rename would silently
reinstate all eight, and the symptom would be a slow, intermittently failing
suite rather than an obvious error.

`Program.cs` gained `public partial class Program;`. Top-level statements
generate an *internal* `Program`, which `WebApplicationFactory<Program>` cannot
see. `InternalsVisibleTo` was the alternative and was rejected: it exposes every
internal in the Host to the test assembly to solve a problem with one type.

---

## Track B — the perf pass, and why it reports no number

### What was changed

1. `AsNoTracking()` on both `EfEditionRepository` reads. `GET /api/editions/{slug}`
   loads an edition and its ~20 items — 21 entities the change tracker snapshots
   and holds for the life of a request, for a response that is serialised and
   discarded.
2. `IX_Editions_Slug` (standalone) replaced by `(Slug ASC, EditionNumber DESC)`,
   migration `20260917043136_IndexEditionsBySlugAndNumber`.

### What is proven

The execution plans, which are structural and do not vary with machine load:

**Before** — a sort:
```
|--Sort(TOP 1, ORDER BY:([e].[EditionNumber] DESC))
     |--Nested Loops(Inner Join, ...)
          |--Index Seek(... [IX_Editions_Slug] ..., SEEK:([e].[Slug]=N'perf-probe-edition') ORDERED FORWARD)
          |--Clustered Index Seek(... [PK_Editions] ... LOOKUP ORDERED FORWARD)
```

**After** — no sort:
```
|--Top(TOP EXPRESSION:((1)))
     |--Nested Loops(Inner Join, ...)
          |--Index Seek(... [IX_Editions_Slug_EditionNumber] ..., SEEK:([e].[Slug]=N'perf-probe-edition') ORDERED FORWARD)
          |--Clustered Index Seek(... [PK_Editions] ... LOOKUP ORDERED FORWARD)
```

The `IsDescending(false, true)` is what makes this fall out for free: reading
*forward* through one slug's entries already yields editions newest-first, so
`ORDER BY EditionNumber DESC` costs nothing. A plain `(Slug, EditionNumber)`
index would have needed a backward scan or kept the sort.

**Eliminating a sort from the hottest read is a real improvement with a named
mechanism.** That is the claim this track makes.

### What is NOT proven: any latency number

Measured on the seeded database (5,002 editions × 20 items, probe slug carrying
two editions so the `ORDER BY` has a real choice), bombardier `-c 20 -d 30s`,
Day 11's load held fixed. Ten runs:

| run | config | p99 | req/s |
|---|---|---|---|
| after | composite idx | 8.56ms | 5,637 |
| before | standalone idx | 8.46ms | 5,122 |
| index-and-notracking | composite + no-track | 7.82ms | 6,004 |
| repeat | composite + no-track | 14.21ms | 3,346 |
| var-1 | composite + no-track | 10.92ms | 3,658 |
| var-2 | composite + no-track | 10.74ms | 3,717 |
| var-3 | composite + no-track | 10.97ms | 3,741 |
| baseline-controlled | standalone idx | 47.34ms | 2,090 |
| baseline-controlled-2 | standalone idx | 41.88ms | 2,144 |
| current-return | composite + no-track | 59.93ms | 1,580 |
| current-return-2 | composite + no-track | 101.94ms | 1,698 |

Ranges by configuration:

- standalone index: **2,090 – 5,122 req/s**
- composite + no-tracking: **1,580 – 6,004 req/s**

**They overlap almost entirely. This rig cannot distinguish the two
configurations.** The machine degraded monotonically across the session — the
same unchanged code measured 6,004, then ~3,700, then ~1,640 req/s over roughly
ninety minutes.

### How that was caught, which is the part worth keeping

Two intermediate conclusions were drawn and both were wrong:

1. From single runs per configuration: "p99 −7.6%, throughput +17%."
2. After a repeat exposed that as noise, from tight clusters either side:
   "p99 4× better, throughput 1.75× better." Two runs per side, each pair
   agreeing to within ~2%.

The second looked rigorous and was not. **Two runs agreeing with each other
prove the instrument is repeatable over thirty seconds. They say nothing about
whether the machine is the same machine it was ten minutes ago.**

What settled it was an A → B → A control: return to the first configuration and
re-measure. A did not come back. `current-return` was *worse than the baseline
it was supposed to beat*, in the configuration that had measured 3.5× better an
hour earlier.

Without that control, a 4× improvement would have gone into this document with
four supporting runs behind it.

### What this changes about method

- Interleave A/B/A/B. Sequential A-then-B against a drifting baseline measures
  the drift.
- Establish repeatability **before** interpreting a difference, not after a
  result looks good.
- A quiet, dedicated environment is a precondition for a latency claim. A
  developer laptop running Docker Desktop, a SQL container, a Host, an IDE and a
  browser is not one.

Day 11's lesson was "a p99 over twenty requests is not a percentile". Day 31's
is sharper: **a p99 over 170,000 requests is a fine percentile and still tells
you nothing if the baseline moved.**

### Not done

- A covering index. The plan still shows a key lookup, because the index carries
  only `Slug` and `EditionNumber` while the response needs seven more columns.
  At `TOP 1` that is one lookup and cheap — but `INCLUDE` would remove it, and it
  was not attempted.
- Any defensible latency figure. Deliberately absent rather than estimated.
- **`QuerySplittingBehavior` is unconfigured**, and EF says so on every API test
  run:

  > `Microsoft.EntityFrameworkCore.Query[20504]` — Compiling a query which loads
  > related collections for more than one collection navigation … no
  > `QuerySplittingBehavior` has been configured. By default … `SingleQuery`,
  > which can potentially result in slow query performance.

  A real perf characteristic of a query this codebase runs, flagged by the
  framework itself, printing in the build output the whole time and not noticed
  until the per-layer test counts were collected. It is a better-evidenced
  perf lead than the one this track spent the day measuring — `AsSplitQuery`
  versus the cartesian explosion of a single join is a decision with a known
  shape, unlike a p99 on a drifting laptop. Not attempted today; it belongs at
  the top of the next perf pass.

---

## Track C — CI gate (written, not applied)

`ci.yml` is protected and cannot be written by the tooling used here, so the job
lives in `Day31/docs/ci-capstone-job.md` to be pasted manually.

The gap it closes: coverage thresholds existed only for `Day5/piece2`, so the
newest code in the repository had the weakest check on it. The job runs the full
capstone suite with `--collect:"XPlat Code Coverage"` and fails below a
threshold.

Two decisions inside it:

- The threshold is computed **in-job** rather than reusing the other job's
  artifact upload, which is currently 403-ing on `FinalizeArtifact`. Copying its
  shape would copy its problem.
- `ubuntu-latest`, because `IntegrationTests` and `ApiTests` both start a real
  SQL Server via Testcontainers and those runners ship with Docker. On a Windows
  runner both projects fail — 24 failures, all Docker-unavailable.

**Open:** the `THRESHOLD` placeholder is 55 and must be set from the first green
run. A threshold chosen before the measurement tests nothing.

---

## Track D — security re-check

`Day31/docs/day31-threat-model.md`, the capstone's first. Day 27 covered
`quotes-api`; this Host had never been reviewed, and it is the newest code in
the repository.

**The headline: there is no authentication.** Every write endpoint takes
`actorId` / `ownerId` / `reviewerId` as a plain string in the request body, and
the aggregate compares that string against the one it stored.
`Collection.RequireOwner` is an ownership check, and the caller supplies both
sides of the comparison.

The sharpest consequence is not that anyone can act as anyone. It is that
`Review` exists specifically to answer "who decided this" — its own doc comment
says collapsing it into `Collection` would make "who rejected edition 3"
unanswerable — and **it records whatever the caller typed.** An audit trail that
can be written by the person it incriminates is worse than none, because it is
believed.

Recorded in **ADR-0003**, accepted until **2026-10-31 or first deployment,
whichever comes first**. The ADR rejects the cheap-guard option explicitly: a
header is exactly as forgeable as a body field, a shared API key authenticates
the deployment rather than the user, and the real cost is that it *looks*
handled — a reviewer who sees an API key stops asking about auth.

The threat model also records what was checked and found clean, because "not
mentioned" and "checked and fine" look identical in a document that only lists
faults: no raw SQL anywhere, no secrets in the repository, no cross-schema
foreign keys, idempotency on every consumer. And two things this codebase gets
right and should keep — the SQL password comes from the environment and is never
defaulted into a committed file, and the Service Bus namespace has
`disableLocalAuth = true` with `DefaultAzureCredential`, so there is no
connection string to leak.

**Not done:** no ZAP scan against the capstone Host. Day 27 ran one against
`quotes-api`. This document is a code and design review, not a test.

---

## What I got wrong today

- **Claimed a perf win twice on insufficient evidence.** Covered above. The
  control was run only after a repeat happened to contradict the first result —
  it should have been the first thing measured, not the last.
- **Sequenced the change before the baseline.** `AsNoTracking` and the index
  were already committed when the measurement started, so the baseline had to be
  reconstructed by reverting a migration and checking out one file. Measure
  first.
- **`AsNoTracking` never reached disk on the first attempt.** The write reported
  success and wrote nothing. It was caught only because `git checkout <parent> --
  EfEditionRepository.cs` produced no diff — a no-op checkout meant the two
  versions were identical, which meant the change had never been committed.
  Every file write since has been verified by byte count rather than by the
  tool's success message.
- **Wrote `-SkipHttpErrorCheck` into a script run on Windows PowerShell 5.1**,
  where the parameter does not exist. And `SET SHOWPLAN_TEXT` paired with
  `SET NOCOUNT ON` in one batch, which SQL Server rejects. Both were written
  without being run once.
- **Two scripts assumed `sqlcmd` on PATH.** It wasn't, and `winget` wasn't
  either. Fixed by using the `sqlcmd` already inside the SQL Server container —
  the client was on the machine all along, in the image running the database.
- **Ran a test suite against a locked build and read "58 passed" as a result.**
  The Host was still running and holding the Publishing DLL, so `ApiTests` never
  built. A passing count from a failed build is not a passing test run.

One thing that went right and is worth naming: the fixtures now turn "Docker is
not running" into one readable line instead of 24 forty-frame stack traces. The
first time that happened it cost real confusion — output that long reads like a
broken suite rather than a stopped daemon.

---

## Evidence

- `Day31/verification/` — ten bombardier transcripts and the captured plans
- `Day31/docs/day31-threat-model.md`
- `Day31/docs/ci-capstone-job.md`
- `Day28/docs/adr/0003-capstone-ships-without-authentication.md`
- `Day22/Capstone/tests/QuotesPlatform.ApiTests/`
