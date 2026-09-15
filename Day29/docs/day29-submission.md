# Day 29 — Build day 1: foundation + happy path (submission)

**Branch:** `day29-foundation-happy-path`. Code changes in `Day22/Capstone`;
today's docs and verification artifact in `Day29/`.

| Deliverable | Where |
|---|---|
| Task prompt | `Day29/docs/day29-prompt.md` |
| Plan | `Day29/docs/day29-plan.md` |
| This submission | `Day29/docs/day29-submission.md` |
| Verification script | `Day29/verification/happy-path.ps1` |

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

**What was not run in this sandbox, stated plainly rather than glossed over:**
this environment has no reachable SQL Server instance and no Azure Service Bus
namespace, so `happy-path.ps1` has not been executed here and its output has
not been captured. Its correctness is by inspection — each call matches the
endpoint contracts built in commits 8–12, and the polling steps wait on the
real async hops rather than assuming a fixed delay. To actually run it:

```powershell
# Step 0 from the plan: a standing local SQL Server, and either the existing
# Azure dev Service Bus namespace or its local emulator
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=<local>" -p 1433:1433 -d mcr.microsoft.com/mssql/server:2022-latest

dotnet user-secrets --project Day22/Capstone/src/QuotesPlatform.Host set "ConnectionStrings:Default" "<value>"
dotnet user-secrets --project Day22/Capstone/src/QuotesPlatform.Host set "ServiceBus:FullyQualifiedNamespace" "<value>"

# Apply each module's migrations once EF is pointed at the real database, then:
dotnet run --project Day22/Capstone/src/QuotesPlatform.Host

# In a second terminal:
./Day29/verification/happy-path.ps1 -BaseUrl https://localhost:<port>
```

This is the same discipline Day 13's submission used when its C# changes could
not be compiled in that environment: recording what could not be verified is
part of the deliverable, not a gap in it.

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
