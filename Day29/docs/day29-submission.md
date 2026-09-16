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

Newest first, in three rounds. The bottom thirteen **built** the happy path.
The middle group is the **review** round — what a reviewer found before anything
had been run (see "What the review changed"). The top group is the **run** round:
what only appeared once it was actually executed against real infrastructure, and
the reason that group exists at all is that the first two rounds were done
without running anything.

The listing below is a snapshot — the command underneath it is the source of
truth, and it will include this commit and anything after it:

```
49c6e7d docs(day29): the happy path has run; replace the placeholder with it
6bafd45 docs(day29): record the happy path running end to end
58dd92d fix(curation): adding an item to a saved collection issued an UPDATE
bb0d691 fix(day29): the port-in-use message printed the PID twice
d9265fd fix(day29): run-host refuses to start when the port is already taken
26bb96f feat(day29): add run-host.ps1 so the Host starts the same way every time
657f938 fix(host): remove the comment key from the LogLevel section
5d304df chore(host): quiet EF Core's per-command logging
ba7abeb fix(day29): correct the dead-lettering flag on subscription create
d5c643f fix(day29): dry run says "would create", not "created"
10c0507 fix(day29): make the topology script's existence probes actually work
89de8ce fix(tests): dispose the composition provider asynchronously
d564763 fix(tests): the composition test project pinned Microsoft.Extensions behind EF Core
342466d docs(day29): repo URL, the day's commit log, and the happy-path walkthrough
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

**It has now been run — see "It has now run" below — and this section has been
wrong twice on the way there, in opposite directions.**

The first version said the only obstacle was that this environment had no
reachable SQL Server or Service Bus namespace. A review then found four reasons
it could not have run even with both in front of it, three of them defects in
today's own code:

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

And then the second version of this section was wrong the other way: having
fixed those five, it implied the path was clear and only the environment stood
in the way. Running it found four more, listed under "It has now run". The
pattern is worth naming, because it is the lesson of the day rather than a
footnote to it: **each round of reasoning about why something would work found
less than one round of running it.**

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

### And what running it changed

| Fix | Where |
|---|---|
| Owned-collection keys declared `ValueGeneratedNever` — a client-set Guid on a **loaded** owner made EF issue an `UPDATE` for a row that was never inserted | `CollectionConfiguration.cs` (`58dd92d`) |
| The topology script's existence probes actually run: `$ErrorActionPreference = 'Stop'` plus `2>&1` made PowerShell throw on az's first stderr write before `$LASTEXITCODE` was read, so `-AllowFailure` was unreachable; and probes skipped under `-DryRun` returned null, which the caller read as "found" | `00-provision-servicebus-topology.ps1` (`10c0507`, `d5c643f`) |
| `--enable-dead-lettering-on-message-expiration`, verified against `az … --help` rather than guessed a second time | `00-provision-servicebus-topology.ps1` (`ba7abeb`) |
| EF Core command logging down to Warning — four relays polling on a short interval buried every real error under heartbeat queries | `appsettings.json` (`5d304df`, `657f938`) |
| `run-host.ps1`: one way to start the Host, password from the environment and never defaulted in the file, and a refusal-with-PID when the port is already held | **new** `Day29/scripts/run-host.ps1` (`26bb96f`, `d9265fd`, `bb0d691`) |
| The composition provider disposed asynchronously — `ServiceBusClient` is `IAsyncDisposable` only, so a synchronous `using` threw after every assertion passed | `ModuleCompositionTests.cs` (`89de8ce`) |

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

# Step 0b: data-plane access for your own principal.
# The namespace has disableLocalAuth = true, so there is no connection string
# and being subscription Owner is NOT enough -- data-plane roles are separate.
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $me --role "Azure Service Bus Data Owner" `
  --scope "/subscriptions/<sub>/resourceGroups/thinkschool-dev-rg/providers/Microsoft.ServiceBus/namespaces/sb-quotes-7mo4cimyk4vnk"
# Allow a few minutes to propagate. Before it does, outbox rows sit at Pending
# and nothing errors -- which looks exactly like a broken relay.

# Step 0c: a standing SQL Server
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=<local>" -p 1433:1433 -d `
  --name capstone-sql mcr.microsoft.com/mssql/server:2022-latest

# Step 1: migrations, all four contexts.
# --connection is NOT optional. The design-time factories hardcode
# Server=(local);Database=QuotesPlatform.DesignTime, which is correct for
# `migrations add` and wrong for `database update` -- without it the schema
# lands somewhere you are not about to run against.
$cs = "Server=localhost,1433;Database=QuotesPlatform;User Id=sa;Password=<local>;TrustServerCertificate=True"
foreach ($m in 'Catalog','Curation','Moderation','Publishing') {
  $p = "Day22/Capstone/src/Modules/$m/QuotesPlatform.Modules.$m.Infrastructure"
  dotnet ef database update --project $p --startup-project $p --context "${m}DbContext" --connection $cs
}

# Step 2: the Host. One script, so a fresh terminal cannot start it half-configured.
$env:CAPSTONE_SQL_PASSWORD = '<local>'
./Day29/scripts/run-host.ps1

# Step 3: in a second terminal. http, not https -- Windows PowerShell 5.1's
# Invoke-RestMethod has no -SkipCertificateCheck, so the dev certificate fails
# every call on trust.
./Day29/verification/happy-path.ps1 -BaseUrl http://localhost:5080 -TimeoutSeconds 60
```

Each of those comments is there because the step under it cost a failed run.
The sequence above is the one that produced
[`happy-path-run.txt`](../verification/happy-path-run.txt), not a reconstruction
of what should have worked.

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

### It has now run

Transcript: [`Day29/verification/happy-path-run.txt`](../verification/happy-path-run.txt)
— 16 September 2026, against SQL Server 2022 in Docker and the dev Service Bus
namespace `sb-quotes-7mo4cimyk4vnk`.

```
== Commit 8: Catalog -- submit and publish three quotes ==
  quote 80c13698-… publishable=True   (and two more)
== Commit 9: Curation -- create a collection and add all three quotes ==
  collection 3df18910-a18b-401a-8afd-10c1cdc2c213 submitted for publication
== Commit 10: waiting for Moderation to open a review (outbox -> Service Bus -> consumer) ==
  review 80e14abe-… opened, outcome=Pending
  review 80e14abe-… approved
== Commit 11 + 12: waiting for the edition (Curation applies the approval, Publishing builds it) ==

HAPPY PATH VERIFIED
  Collection: 3df18910-a18b-401a-8afd-10c1cdc2c213
  Edition:    1 at slug 'day-29-happy-path-3df18910'
  Items:      3
```

Hops 3 and 5 are reachable only through the message path — the script waits for
them rather than asserting on a response — so a broken relay, a missing
subscription or a wrong filter rule surfaces here as a timeout, not a pass.

**What the first four attempts cost, and why it belongs in the submission.**
The run failed four times, and only one cause was in the application:

| # | Failure | Where it was |
|---|---------|--------------|
| 1 | The Service Bus topology did not exist — and the provisioning script's dry run reported that it did, because its probes were skipped under `-DryRun` and a skipped probe returned null, which the caller read as "found" | verification tooling (`10c0507`) |
| 2 | `az` rejected `--dead-letter-on-message-expiration`; the flag is `--enable-dead-lettering-on-message-expiration` | verification tooling (`ba7abeb`) |
| 3 | EF Core logs every command at Information; four relays polling on a short interval buried the one real error under hundreds of heartbeat queries | operations (`5d304df`) |
| 4 | Adding an item to a **saved** collection issued an `UPDATE` for a row that was never inserted, failing with `DbUpdateConcurrencyException`. Creating a collection worked; adding to it did not — the owner's entity state decided which, and a client-set Guid key on an `Unchanged` owner reads to EF as "this row exists" | **application** (`58dd92d`) |

The fourth is the one a reviewer should care about, and it is worth being precise
about why nothing caught it earlier: it compiles, it passes every test in the
suite, and it only appears on the *second* write to an aggregate — the first
write, where the owner is `Added`, inserts correctly. No test performed a second
write to a loaded aggregate. Publishing's `EditionItem` is immune to the same
mistake because it keys on the composite `(EditionId, Position)` rather than a
client-generated Guid, which is the pattern that avoided the problem by
construction rather than by care.

The first three say something else. A dry run that reports success without
checking is worse than no dry run, because it converts "unknown" into "verified".
That the verification layer was the least verified part of the day is the honest
headline of this section.

> **Clip still outstanding.** The transcript above is the run; a screen recording
> of it has not been captured yet.

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
