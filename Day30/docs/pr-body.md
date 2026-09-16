# Day 30 — Build day 2: flows 1 and 2 complete

Closes the reject/revise loop in flow 1 and builds flow 2 (quote correction)
end to end. **Flow 3 (quote moderation) is deliberately not here** — see "What
is not in this PR".

Full write-up: `Day30/docs/day30-submission.md`. Plan and gap analysis:
`Day30/docs/day30-plan.md`.

## The headline: one defect fixed ahead of the code that triggers it

`POST /api/reviews/{id}/approve` built a `CollectionApproved` from
`review.SubjectId` **without ever reading `review.Subject`**. That is correct
only while collection reviews are the only kind of review. The moment flow 3
opens a review for a *quote*, approving it publishes a `CollectionApproved`
carrying a QuoteId — Curation's handler finds no collection, completes the
message, and leaves no trace. A wrong event is worse than a missing one,
because it is delivered, handled and acknowledged.

Fixed in commit 2, before the code that would trigger it exists. The mapping
now lives in `ModerationIntegrationEventTranslator`: exhaustive over
(subject, outcome), a pure function of the aggregate, testable without a
database or a broker. 7 tests, one asserting the negative.

## What the gap analysis found

The domain was well ahead of the wiring. `Collection.Reject`, `BeginRevision`,
`ApplyQuoteRevision`, `RemoveItem`, `Reorder`, `Rename`, `AddMember`,
`Review.Reject`, `Quote.Revise` were all implemented and tested on Day 22 and
reachable through **no endpoint and no handler**. Most of this PR is connecting
behaviour that already existed, not writing new behaviour.

Two planned items were **struck rather than done**, because they were already
there: the unique index on `(CollectionId, EditionNumber)` (Day 22 has it, and
`GetLatestBySlugAsync` already orders correctly), and domain tests for the
reject/revise/correction paths (`CollectionInvariantTests` covers all four).

## Please push back on these three

Each is argued in its commit message; I would rather be told I am wrong now
than have it found later.

1. **The rejection reason stays in Moderation**, so a curator makes a second
   call to `GET /api/reviews/by-subject/{id}/latest`. The alternative was
   storing it on the collection; rejected because a decision and its grounds
   belong to the module that made them.
2. **`QuoteRevisedHandler` commits N aggregates in one transaction**, against
   the rule on `ICollectionRepository.SaveChangesAsync`. My argument is that
   the rule guards against coupled *invariants* and these snapshots are
   independent — and that splitting it would break the consumer host's
   idempotency guarantee, since it commits handler work with the
   `ProcessedMessages` row. **This needs an ADR it does not have yet.**
3. **Remove is `POST .../items/{quoteId}/remove`, not `DELETE`**, to keep a
   user identifier out of the query string and therefore out of access logs.

## Infrastructure change, already applied

`curation-review-decisions`' filter now admits `QuoteRevised` and
`QuotePublishable`. Without it those messages are **never delivered and never
redelivered, with no error anywhere** — the same failure shape as Day 29's
missing topology. It is a separate commit, landed and applied to
`sb-quotes-7mo4cimyk4vnk` **before** the publisher commits, and verified with
`-DryRun` first.

Anyone pulling this branch to run it does not need to do anything; the
namespace is already updated.

## What is not in this PR

- **Flow 3 (quote moderation).** Cut at the track boundary rather than
  half-built: Catalog needs a consumer host, a `ProcessedMessages` migration
  and a fourth subscription. `mark-publishable` remains as the documented
  stand-in. Day 31.
- **Integration tests against a real database.** This is the real gap and I
  want it on the record: the three new composition tests prove every handler is
  registered, correctly keyed and constructible, but **no handler in this
  solution has ever been executed.** `CollectionRejectedHandler` and
  `QuoteRevisedHandler` are compiled and composed, not verified. The
  Testcontainers harness is first on Day 31, ahead of flow 3.

## Verification

- `dotnet build` and `dotnet test` green (47 tests).
- Topology applied to the live dev namespace and confirmed.
- **Not** run end to end against SQL Server and Service Bus. The Day 29
  happy-path transcript still stands; the new paths have no equivalent yet.

## Reviewing this

Commits are ordered so each builds on its own, and each message carries its own
reasoning — reading them in order is probably easier than reading the diff.
Comments get answered with a new commit that names the comment, or a reply
explaining why I disagree. No silent force-pushes.
