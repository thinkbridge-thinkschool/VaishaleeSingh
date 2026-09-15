# Day 29 — Build day 1: foundation + happy path (submission)

**Branch:** `day29-foundation-happy-path`. Code changes in `Day22/Capstone`;
today's docs and verification artifact in `Day29/`.

| Deliverable | Where |
|---|---|
| Task prompt | `Day29/docs/day29-prompt.md` |
| Plan | `Day29/docs/day29-plan.md` |
| This submission | `Day29/docs/day29-submission.md` |
| Verification script | `Day29/verification/happy-path.ps1` |

## Repository, branch and commit log

| | |
|---|---|
| Repository | https://github.com/thinkbridge-thinkschool/VaishaleeSingh |
| Branch | `day29-foundation-happy-path` |
| Pull request | https://github.com/thinkbridge-thinkschool/VaishaleeSingh/pull/90 (into `dev`) |
| Code | `Day22/Capstone` |
| Docs, scripts, verification | `Day29/` |

Newest first. The first thirteen built the happy path; everything above them
is the review round (see "What the review changed"). The listing below is a
snapshot — the command underneath it is the source of truth, and it will
include this commit and anything after it:

```
1ebcb12 docs(day29): record what the review found, and correct what this claimed
e40fbb9 fix(day29): the happy-path script could not have passed
cb8dc9e feat(day29): provision the Service Bus topology the capstone needs
2a456aa ci: build and test the capstone solution
36dfa58 test(capstone): cover the container the Host actually builds
0c836f8 fix(composition): one Service Bus client, and a migrations history table per schema
9fbe1e3 fix(di): give each module its own outbox publisher port
11549ad fix(outbox): the relays could not start, and the retry budget was off by one
a1582e7 docs(day29): submission + happy-path verification script
9244020 feat(publishing): build the edition from the event, expose it (happy path hop 5)
5d06a5b feat(curation): apply Moderation's approval, publish the edition (happy path hop 4)
a54eb8d feat(moderation): open review on submission, approve endpoint (happy path hop 3)
c43c1e6 feat(curation): create, add item, submit endpoints (happy path hop 2)
2c52a7e feat(catalog): submit + mark-publishable endpoints (happy path hop 1)
36d6c00 feat(consumers): Service Bus consumer host + idempotency per subscribing module
2e94d86 feat(outbox): relay to Azure Service Bus per module
6948b7d feat(outbox): shared outbox shape, one table per module schema
6ccf835 feat(publishing): EF configuration, SQL Server migration and repository for Edition
2940868 feat(moderation): EF configuration, SQL Server migration and repository for Review
0b00b45 feat(catalog): EF configuration, SQL Server migration and repository for Quote
7966602 feat(curation): EF configurations, SQL Server migration and repository for Collection
```

Regenerate with:

```bash
git log --oneline origin/dev..day29-foundation-happy-path
```

## What today closed

Day 22 scaffolded the capstone and deliberately built nothing that runs. Today
made one path real, start to finish, against real SQL Server and a real Azure
Service Bus namespace: submit a quote, publish it, curate a collection from
three such quotes, submit it for review, have Moderation open and approve a
review, have Curation apply that approval and publish the next edition, and
have Publishing build and expose that edition.

**13 commits**, each independently buildable (verified: `dotnet build` and
`dotnet test` green after every one, architecture tests included):

| # | What it added |
|---|---|
| 1 | Curation: EF configuration, SQL Server migration, repository for `Collection` |
| 2 | Catalog: same shape for `Quote` |
| 3 | Moderation: same shape for `Review` |
| 4 | Publishing: same shape for `Edition` (caught EF defaulting `Position` to a SQL identity column inside a composite key — fixed with `ValueGeneratedNever()`) |
| 5 | Shared outbox shape: `OutboxMessage`, one table per module schema, `EfOutboxIntegrationEventPublisher` per module |
| 6 | `*OutboxRelayService` per module, publishing to the shared `capstone.collection-events` Service Bus topic via `DefaultAzureCredential` |
| 7 | `*ServiceBusConsumerHost` per subscribing module (Moderation, Curation, Publishing), `ProcessedMessages` idempotency table, keyed `IIntegrationEventHandler` dispatch (no handlers registered yet) |
| 8 | Catalog: `POST /api/quotes`, `GET /api/quotes/{id}`, `POST /api/quotes/{id}/mark-publishable` |
| 9 | Curation: `POST /api/collections`, add item, submit — the first outbox write on the happy path |
| 10 | Moderation: `CollectionSubmittedForPublicationHandler` opens a `Review`; `POST /api/reviews/{id}/approve` publishes `CollectionApproved` |
| 11 | Curation: `CollectionApprovedHandler` applies the approval and publishes the fat `CollectionPublished` snapshot |
| 12 | Publishing: `CollectionPublishedHandler` builds the `Edition` from the event alone; `GET /api/editions/{slug}` |
| 13 | This submission + the verification script |

## What "works against real infra" means here, precisely

Every hop above crosses a **real** boundary: SQL Server (schemas, migrations,
real transactions) and Azure Service Bus (real publish/receive over the
`moderation-review-requests`, `curation-review-decisions` and
`publishing-editions` subscriptions). Nothing is faked or in-memory.

**It has still not been run, and the first version of this document was wrong
about why.** It said the only obstacle was that this environment has no
reachable SQL Server or Service Bus namespace. A review found four reasons it
could not have run even with both in front of it — three of them defects in
today's own code, all now fixed:

| # | What | Where it was |
|---|---|---|
| 1 | Every outbox relay threw while the host was **starting** | `_owner` was built with `[..64]`, which is `Substring(0, 64)` and therefore throws whenever the string is shorter than 64. A Windows machine name is at most 15 characters, so the composed id is ~51 and it threw every time. A hosted service that throws in a field initializer takes the host down before it listens. |
| 2 | The happy path stopped at hop 2, silently | All four modules registered their own implementation against the one shared `IIntegrationEventPublisher`. The container keeps the last registration, so Curation's submit endpoint and its `CollectionApprovedHandler` both received **Moderation's** publisher and staged their outbox row on `ModerationDbContext` — which their own `SaveChangesAsync` never saves. The row was discarded, the endpoint returned 200, and the event was never published. Moderation's own approve endpoint worked only because it happened to be the winning registration. |
| 3 | The Service Bus topology did not exist | Nothing in this repository creates `capstone.collection-events` or its three subscriptions. `Day7/piece2/infra` provisions the namespace and the *old* topology (`quote-events` / `audit` / `search-index`). `CreateSender` resolves nothing at construction, so the relay starts cleanly and fails on the first send with `MessagingEntityNotFound`. |
| 4 | `happy-path.ps1` could not have passed | `mark-publishable` returns the updated quote, so its response fell into the pipeline and `$quotes` held six entries instead of three; the add-item loop then added every QuoteId twice and `Collection.AddItem` refuses that with a 400. And `$collection.id.ToString("N")` was called on a `String` — `ConvertFrom-Json` does not produce a `Guid`, and `String` has no `ToString(string)` overload. |

None of these was catchable by a build, and none by any test that existed.
Which is the fifth finding, and the one that made the other four possible:

**CI never built this code.** `ci.yml`'s three jobs target
`Day5/piece2/QuotesApi.slnx` and `Day7/piece2/infra`. Six thousand lines landed
on a pull request reporting "all checks have passed" — a green tick that was
true about other code entirely.

## What the review changed

| Fix | Where |
|---|---|
| `BuildOwnerId()` truncates only when there is something to truncate | all four `*OutboxRelayService.cs` |
| Each module declares and registers `I<Module>IntegrationEventPublisher`; the shared type is never registered | four new `I*IntegrationEventPublisher.cs`, four registrations, three injection sites, and the rule recorded on `IIntegrationEventPublisher` itself |
| `TryAddSingleton` for `ServiceBusClient` — four `AddSingleton` calls for one service type produced one client, not four, and the comment claimed otherwise | four `*ModuleRegistration.cs` |
| Migrations history table per schema — four DbContexts over one database were sharing `dbo.__EFMigrationsHistory` | four registrations + four design-time factories |
| Retry budget counts the attempt just spent (`ClaimBatchAsync` has already incremented it) | all four relays |
| `capstone.collection-events` and its three filtered subscriptions, provisioned | **new** `Day29/scripts/00-provision-servicebus-topology.ps1` |
| `Out-Null` on mark-publishable; `Get-Slug` walks characters exactly as `CollectionPublishedHandler.Slugify` does, and casts to `[guid]` | `Day29/verification/happy-path.ps1` |
| A `capstone` job that restores, builds and tests `Day22/Capstone/QuotesPlatform.slnx` | `.github/workflows/ci.yml` |
| Composition tests: no service type registered by two modules, every hosted service constructs, each module resolves its own publisher | **new** `Day22/Capstone/tests/QuotesPlatform.CompositionTests` |

**The CI job paid for itself before it ever passed.** Its first two runs failed
on the composition test project rather than on the code under review — a
package downgrade (`Microsoft.Extensions.Logging 10.0.0` against EF Core's own
`>= 10.0.10`), then an `InvalidOperationException` on teardown, because
`ServiceBusClient` implements `IAsyncDisposable` and not `IDisposable`, so a
synchronous `using` on a provider holding one throws after every assertion has
already passed. The Host never meets the second one — `WebApplication` disposes
asynchronously — which is exactly the kind of difference that only shows up
when something composes the container outside the Host.

The composition tests are the point. Defect 2 is now impossible to express —
a module cannot resolve another module's publisher because it cannot see the
type — and defect 1 is caught by constructing every hosted service, which is
exactly what `Every_hosted_service_can_be_constructed` does and what nothing
did before.

**One migration caveat, stated because it gets worse with time.** Moving each
module to its own `__EFMigrationsHistory` is free today only because no
database exists yet. If one has already been created, drop it (or move that
module's rows from `dbo.__EFMigrationsHistory` into its own schema) before the
next `dotnet ef database update`, or EF will find no history and try to re-apply
migrations over existing objects.

**To actually run it:**

```powershell
# Step 0a: the topology the code needs and nothing created
./Day29/scripts/00-provision-servicebus-topology.ps1 -DryRun
./Day29/scripts/00-provision-servicebus-topology.ps1

# Step 0b: a standing SQL Server
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=<local>" -p 1433:1433 -d mcr.microsoft.com/mssql/server:2022-latest

dotnet user-secrets --project Day22/Capstone/src/QuotesPlatform.Host set "ConnectionStrings:Default" "<value>"
dotnet user-secrets --project Day22/Capstone/src/QuotesPlatform.Host set "ServiceBus:FullyQualifiedNamespace" "<value>"

# Apply each module's migrations, then:
dotnet run --project Day22/Capstone/src/QuotesPlatform.Host

# In a second terminal:
./Day29/verification/happy-path.ps1 -BaseUrl https://localhost:<port>
```

Recording what could not be verified is part of the deliverable — the same
discipline Day 13's submission used. Recording it **accurately** is the part
this round had to correct: "the sandbox has no infrastructure" was true and was
not the whole reason, and a reason that is only partly true stops anyone
looking for the rest.

## Showing the happy path working

Two ways, and the second is the one to record.

### The one-command version

```powershell
./Day29/scripts/00-provision-servicebus-topology.ps1     # once per namespace
dotnet run --project Day22/Capstone/src/QuotesPlatform.Host
# second terminal:
./Day29/verification/happy-path.ps1 -BaseUrl https://localhost:<port>
```

It prints every hop as it happens and ends with the edition, its number, its
slug and its three items. That transcript is the evidence; save it as
`Day29/verification/happy-path-run.txt`.

### The walkthrough, hop by hop

Nine calls. Each one crosses a boundary the previous one did not, and the two
waits are real: nothing here polls a fake.

```bash
BASE=https://localhost:7113          # -k because it is the dev certificate

# ---- hop 1: Catalog. Submit a quote, then mark it publishable. -------------
curl -sk -X POST $BASE/api/quotes -H 'Content-Type: application/json' \
  -d '{"author":"Author 1","text":"Quote text number 1.","submittedByUserId":"curator-1"}'
curl -sk -X POST $BASE/api/quotes/<quoteId>/mark-publishable
# repeat for quotes 2 and 3 -- Collection.MinItemsToPublish is 3

# ---- hop 2: Curation. Create, fill, submit. The FIRST outbox write. --------
curl -sk -X POST $BASE/api/collections -H 'Content-Type: application/json' \
  -d '{"name":"Day 29 happy path","ownerId":"curator-1"}'

curl -sk -X POST $BASE/api/collections/<collectionId>/items -H 'Content-Type: application/json' \
  -d '{"quoteId":"<quoteId>","author":"Author 1","text":"Quote text number 1.","isPublishable":true,"actorId":"curator-1"}'
# x3

curl -sk -X POST $BASE/api/collections/<collectionId>/submit -H 'Content-Type: application/json' \
  -d '{"actorId":"curator-1"}'
# -> state: "PendingReview". Nothing else has happened YET.

# ---- hop 3: Moderation, reached only through the broker. -------------------
# Wait. Curation's relay claims the outbox row, publishes it to
# capstone.collection-events, Moderation's consumer receives it on
# moderation-review-requests and opens a Review. A few seconds.
curl -sk $BASE/api/reviews/by-subject/<collectionId>
# -> a review with outcome "Pending". THIS 200 is the proof the async hop ran.

curl -sk -X POST $BASE/api/reviews/<reviewId>/approve -H 'Content-Type: application/json' \
  -d '{"reviewerId":"reviewer-1"}'

# ---- hops 4 and 5: back across the broker, twice. -------------------------
# Curation receives CollectionApproved, applies it, publishes the fat
# CollectionPublished; Publishing receives it and builds the Edition from the
# payload alone.
curl -sk $BASE/api/collections/<collectionId>
# -> state: "Published", editionNumber: 1

curl -sk $BASE/api/editions/day-29-happy-path-<first8OfCollectionId>
# -> the edition, with its three items in position order
```

**What makes this a walkthrough rather than a demo:** the two waits are the
only way hops 3, 4 and 5 can happen. There is no synchronous call between
modules anywhere in this code — Publishing does not even hold a reference to
Curation — so an edition appearing at the last URL cannot be explained by
anything except the outbox relay, Service Bus, and two consumers having
actually run.

### The infrastructure half, worth one screenshot each

```sql
-- rows written in the same transaction as the domain change, then relayed
SELECT Id, EventType, Status, Attempts, SentAtUtc FROM curation.OutboxMessages ORDER BY Id;
SELECT Id, EventType, Status, SentAtUtc            FROM moderation.OutboxMessages ORDER BY Id;

-- the consumer-side dedupe key, one row per (message, subscription)
SELECT * FROM moderation.ProcessedMessages;
SELECT * FROM curation.ProcessedMessages;
SELECT * FROM publishing.ProcessedMessages;
```

Every outbox row should read `Sent`. In the portal, the three subscriptions
under `capstone.collection-events` should show a zero active message count and
a non-zero total — delivered and completed, nothing dead-lettered.

### Recording the clip

Sixty to ninety seconds is enough, and the terminal is the better subject than
a browser: the waits are the story.

- **Windows:** `Win` + `Alt` + `R` (Xbox Game Bar) records the focused window
  to `%USERPROFILE%\Videos\Captures`. No install.
- **A GIF instead:** ShareX → Capture → Screen recording (GIF). Smaller, and it
  plays inline in a pull request.

Run `happy-path.ps1` in the foreground with the Host's log visible beside it if
the terminal is wide enough — the relay and consumer log lines landing between
the two waits are what a reviewer wants to see. Save it as
`Day29/verification/happy-path.gif` (or `.mp4`) and link it here.

> **Not captured yet.** The run and the clip are still outstanding: this
> environment has no reachable SQL Server and the topology has not been
> provisioned. Replace this block with the transcript and the clip once it has
> run — and if a hop fails, that failure is worth pasting too, since a run
> nobody can see is the position this submission started in.

## Deliberately deferred (named, not silently dropped)

Per `day29-plan.md`'s ground rules — foundation only as deep as the happy path
needs:

- `Reject` / `Revising`, `BeginRevision`
- Quote-correction propagation (`QuoteRevised`)
- Retention/cleanup jobs for `OutboxMessages` and `ProcessedMessages`
- Authentication — endpoints take a plain `actorId`/`ownerId`/`reviewerId`
  string, the same way Day 2–3 of the original API built persistence before
  adding real auth
- Any UI

Each is a line item for the next build day, not a forgotten corner.

## What would break this, if changed carelessly

Same shape as Day 22's own list, extended with what today actually built:

- **A cross-schema foreign key.** Still none — every module's migration stays
  inside its own schema.
- **A handler that calls `SaveChangesAsync` itself.** Every commit-10/11/12
  handler deliberately does not: the consumer host's own `SaveChangesAsync`
  commits the handler's side effect and the `ProcessedMessages` row together.
  A handler that saved early would let a crash between the two leave a side
  effect applied with no record that it happened.
- **Publishing calling back into Curation** for an edition's items instead of
  using `CollectionPublished`'s payload. `CollectionPublishedHandler` never
  references `ICollectionRepository` — there is no way to reach into Curation
  by accident because the reference does not exist to reach through.
