# Day 29 — Build day 1: foundation + happy path

**Branch:** `day29-foundation-happy-path` off `dev`, PR into `dev`. Code changes
land in `Day22/Capstone` (the capstone lives where it was scaffolded, the same
way `Day7/piece2` keeps carrying the API forward rather than being copied per
day). This folder holds today's docs only: the prompt, this plan, and the
submission.

## What "foundation" and "happy path" mean today, precisely

Day 22 built the shape (projects, dependency rules, a rich `Collection`
aggregate, architecture tests) and deliberately built nothing that runs. Today
closes that gap for **one path only**:

```
Catalog: submit a quote, mark it publishable
  → Curation: create a collection, add the quote, submit for publication
    → Moderation: review opens, reviewer approves
      → Curation: applies the approval, publishes edition 1
        → Publishing: builds the immutable edition from the event snapshot
```

Every arrow above must cross a **real** boundary today: a real SQL Server
(schemas, migrations, actual transactions — not SQLite, not InMemory) and a
real Azure Service Bus namespace (actual publish/receive — not an in-process
fake). "Works against real infra by EOD" is the exit criterion for the whole
day, and it is checked by running the flow, not by reading the code.

**Explicitly not today** (recorded so it isn't silently dropped, not because
it's unimportant): `Reject`/`Revising`, `BeginRevision`, quote-correction
propagation (`QuoteRevised`), poison-message handling beyond what the Day 20
pattern already gives for free, retention/cleanup jobs, auth (endpoints take a
plain `actorId`/`ownerId` string for now, the same way Day 2–3 of the original
API built persistence before adding real auth), and any UI. Each is a
one-line addition to the Day 28-style build-plan-of-plans once this lands, not
a today problem.

## Ground rules

1. **Foundation only as deep as the happy path needs.** No speculative
   generality — e.g. no generic outbox abstraction beyond what Curation,
   Moderation and Publishing each concretely need to publish and consume today.
2. **Small, reviewable commits, each one buildable.** The sequence in Step 2 is
   also the intended commit sequence; nothing in the list depends on something
   later in it.
3. **Real infra, chosen deliberately (see Step 0), not assumed.**
4. **The architecture tests from Day 22 stay green throughout.** They are the
   thing stopping "foundation work" from becoming "quietly reach across a
   module boundary because it's Tuesday."
5. **Every cross-module fact travels as an integration event through the
   outbox — never a direct call, never a shared transaction.** This is the one
   rule the whole design (and ADR-0001) rests on; today is where it either
   holds or the plan was wrong.

## Step 0 — Decide the real infra, and say so (15 min)

Two things need a real backend today. Both already have working patterns in
this repo — today reuses them rather than inventing new ones.

**Database.** A real SQL Server, not SQLite. Simplest path: the same
`sqlserver:2022-latest` container image the integration tests already use
(`Day7/piece2` Testcontainers setup), run as a **standing** container for the
day rather than spun up per test run:

```powershell
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=<local-dev-only>" `
  -p 1433:1433 --name quotesplatform-sql -d mcr.microsoft.com/mssql/server:2022-latest
```

One database, `QuotesPlatform`, four schemas (`catalog`, `curation`,
`publishing`, `moderation`) — exactly as designed. Local SQL auth is fine here;
it is a throwaway local container, not the Entra-only Azure SQL that
`quotes-api` depends on.

**Messaging.** The existing Azure Service Bus **dev** namespace already
provisioned for `quotes-api` (`README.md` → `sb-quotes-<suffix>`,
`disableLocalAuth: true`). Reused rather than standing up a second namespace:
one topic, `capstone.collection-events`, with one subscription per consuming
module (`moderation-review-requests`, `curation-review-decisions`,
`publishing-editions`). Authentication is `DefaultAzureCredential` — the
same managed-identity-shaped pattern `quotes-api` uses, backed locally by
`az login` — so no connection string with a key ever exists.

**If Service Bus access isn't available today**, the fallback — recorded here
rather than discovered mid-afternoon — is Azure Service Bus's local emulator
container. The publisher/consumer code is identical either way; only the
connection config changes. This is a call to make once, at the start, not
something to redecide per module.

**Deliverable:** both reachable, proven with one throwaway `sqlcmd` /
`az servicebus` round trip before any module code changes.

## Step 1 — Foundation, module by module (commits 1–7)

Same shape repeated four times, then the messaging seam once. Each module's
commit is independently buildable and independently reviewable.

**Commit 1 — Curation persistence.**
`CollectionConfiguration`, `CollectionItemConfiguration`,
`CollectionMemberConfiguration` (owned types for items/members — they have no
identity of their own outside the aggregate), first EF migration
(`InitialCreate`) against the `curation` schema, `EfCollectionRepository`
implementing `ICollectionRepository`. `CurationModuleRegistration` switches
`UseSqlite` → `UseSqlServer` and registers the repository.

**Commit 2 — Catalog persistence.** `QuoteConfiguration`, migration,
`EfQuoteRepository`. Mirrors commit 1's shape exactly — Catalog's `Quote` is
the simpler aggregate.

**Commit 3 — Moderation persistence.** `ReviewConfiguration`, migration,
`EfReviewRepository`.

**Commit 4 — Publishing persistence.** `EditionConfiguration` +
`EditionItemConfiguration` (owned, ordered by `Position`), migration,
`EfEditionRepository`.

**Commit 5 — The outbox, shared shape, per-schema table.** Following Day 20's
`QuotesApi` pattern exactly (same commit-in-one-transaction contract): an
`OutboxMessage` row type and `IOutboxWriter` in `SharedKernel`, an
`OutboxMessages` table added to **each** module's own schema via that module's
own migration (no cross-schema table — the outbox is per-module, same as
everything else). Each module's `SaveChangesAsync` writes domain-event-derived
outbox rows in the same transaction as the aggregate — this is the line ADR-0001
is actually about, and today is where it gets built rather than argued for.

**Commit 6 — The relay and the publisher.** One `OutboxRelayService` (hosted
service, registered per module that has an outbox) claiming unsent rows and
publishing to the Service Bus topic via a small `IIntegrationEventPublisher`
implementation in `SharedKernel`/`Contracts`-adjacent infra. Mirrors
`OutboxRelayService` from `Day7/piece2/QuotesApi/Messaging/Outbox` closely
enough that a diff between the two is instructive, not coincidental.

**Commit 7 — The consumer side.** A small `ServiceBusConsumerHost` per
subscribing module, a `ProcessedMessages` table (per module, keyed on
`MessageId`) for idempotency — same at-least-once-delivery-exactly-once-effect
shape as Day 19/20. No business logic yet; each consumer at this point just
deserializes and logs, so commit 8 onward is pure application logic wired onto
an already-proven pipe.

**Verification gate for Step 1:** a message published by hand to the topic is
received, deduplicated on a repeat send, and logged by each subscription — with
the SQL Server container and Service Bus namespace both real, before any
endpoint exists.

## Step 2 — The happy path, one hop at a time (commits 8–12)

Each commit adds exactly one hop of the flow in Step "What foundation and
happy path mean today" and is independently demoable with `curl` /
`.http` requests against the running `Host`.

**Commit 8 — Catalog: submit + approve a quote.**
`POST /api/quotes` (creates via `Quote.Submit`), and — standing in for the full
Moderation-of-quotes flow, deferred per the "explicitly not today" list —
a direct `POST /api/quotes/{id}/mark-publishable` that calls `MarkPublishable()`
so the happy path has a publishable quote to work with today without building
quote review a day early.

**Commit 9 — Curation: create, add item, submit.**
`POST /api/collections`, `POST /api/collections/{id}/items`,
`POST /api/collections/{id}/submit`. The last one is where
`CollectionSubmittedForReview` (domain) becomes
`CollectionSubmittedForPublication` (integration, already defined in
`Contracts`) and goes out through the outbox built in commit 5.

**Commit 10 — Moderation: consume the request, expose the decision.**
The `moderation-review-requests` consumer (commit 7) now actually does
something: `Review.Open(Collection, collectionId)`. `POST
/api/reviews/{id}/approve` calls `Review.Approve`, then publishes
`CollectionApproved` (already defined in `Contracts`) through Moderation's own
outbox.

**Commit 11 — Curation: consume the approval, publish the edition.**
The `curation-review-decisions` consumer loads the aggregate, calls
`collection.Approve(...)`, which raises `CollectionEditionPublished`
(domain). The application layer translates that into `CollectionPublished`
(integration) **carrying the full item snapshot**, per the ADR — this is the
fat-payload rule from the design brief, built for real rather than described.

**Commit 12 — Publishing: consume, build, expose.**
The `publishing-editions` consumer calls `Edition.FromSnapshot(...)` entirely
from the event payload — no call back into Curation, which is the thing the
design brief says would be wrong, not just slower. `GET
/api/editions/{slug}` returns the read model.

**Verification gate for Step 2 (the actual EOD proof):** one script,
`Day29/verification/happy-path.ps1` (or `.http` file), that runs the six calls
above in order against the real SQL Server + real Service Bus and ends with a
`200` from `GET /api/editions/{slug}` showing the published items — with no
manual step in between except the waits for async delivery. This is the
artifact that proves "works against real infra by EOD," not a description of
it.

## Step 3 — Close the loop (commit 13)

- `Day29/docs/day29-submission.md`: what was built, the commit list, the
  verification script's output, and — same discipline as every prior day's
  submission — what was deliberately deferred and why, so nobody downstream
  mistakes "not built yet" for "forgotten."
- Confirm `dotnet build` and `dotnet test`
  `Day22/Capstone/QuotesPlatform.slnx` are both green, including the
  architecture tests unmodified from Day 22.

## Verification gates, summarized

| After | Gate |
|---|---|
| Step 0 | SQL Server and Service Bus both reachable from a throwaway script |
| Step 1 (commits 1–4) | Each module's migration applies cleanly to a fresh `QuotesPlatform` database; architecture tests still green |
| Step 1 (commits 5–7) | A hand-published message is received once per subscription and deduped on replay |
| Step 2 (commits 8–12) | Each hop demoable independently via `curl`/`.http` |
| Step 3 | `happy-path.ps1` runs unattended end to end and the final `GET` shows the published edition |
| Before merge | `git status` clean; no `quotesplatform.db` (SQLite artifact) committed; connection strings/secrets are in user-secrets or environment, not `appsettings.json` |

## What this day produces

- `Day29/docs/day29-prompt.md`, `day29-plan.md` (this file), `day29-submission.md`
- `Day29/verification/happy-path.ps1` (or equivalent `.http` file) and its captured output
- In `Day22/Capstone/src`: EF configurations, migrations and repository
  implementations for all four modules; the shared outbox + Service Bus
  publisher/consumer plumbing; the endpoints for the one flow above
- `Day22/Capstone/src/QuotesPlatform.Host/appsettings.json` pointed at real
  connection strings (via user-secrets locally), not SQLite

## The one thing to keep in view

The design review said the outbox was the decision worth defending. Today is
where that stops being a paragraph in an ADR and becomes a table that either
does or doesn't survive a real publish, a real network hiccup, and a real
re-delivery. If the happy path only works because a consumer got lucky on
ordering, or because the outbox row and the aggregate secretly aren't in the
same transaction, that's a foundation problem to fix today — not a footnote for
Day 30.
