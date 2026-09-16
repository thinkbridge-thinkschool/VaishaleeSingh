# Day 30 — Build day 2: feature completeness (all three flows)

All three async flows in `capstone-design.md` are built: the reject/revise loop
completes flow 1, quote correction is flow 2, and quote moderation is flow 3.
`mark-publishable`, Day 29's stand-in, is deleted.

The concrete test of "feature complete": `Every_integration_event_has_a_consumer`
— no contract in `QuotesPlatform.Contracts` that nobody listens to.

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
2. **`QuoteRevisedHandler` and `QuotePublishableHandler` commit N aggregates in
   one transaction**, against the rule on
   `ICollectionRepository.SaveChangesAsync`. The argument — the rule guards
   against coupled *invariants*, these snapshots are independent, and splitting
   it would break the consumer host's idempotency guarantee — is now written up
   as **ADR-0002**, with the three alternatives and the condition under which
   each would have won.
3. **Remove is `POST .../items/{quoteId}/remove`, not `DELETE`**, to keep a
   user identifier out of the query string and therefore out of access logs.
4. **Deleting `mark-publishable` is a breaking change** to any caller relying
   on it. Justified because it was a stand-in for a flow that now exists, and
   leaving it would mean two ways to make a quote publishable with only one of
   them audited — but it is a deletion, and worth a second opinion.

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

- **Dead-letter monitoring.** Poison messages dead-letter after the retry
  budget and nothing watches the queues. Given three "silent message" failures
  in two days, and ADR-0002 making one dead letter cost a whole broadcast, this
  is the most valuable thing still missing.
- **A bound on the broadcast fan-out** (ADR-0002, "what we now owe").
- **Authentication.** Endpoints still take a plain `actorId`.

## Verification

- `dotnet build` and `dotnet test` green. Every commit claiming to be verified
  was built and tested **before** it was committed, after two CI failures
  earlier in the day proved the opposite order does not work.
- **`QuotesPlatform.IntegrationTests` is new and is the answer to this PR's
  original biggest weakness.** Ten tests against a real SQL Server 2022
  container: the reject/revise loop through to edition 2, a correction reaching
  a draft and stopping at a published edition, a quote announced twice opening
  exactly one review, approval producing both the flag and the outbox row, and
  a collection refusing submission until its quote clears review. These are the
  first tests in the solution that execute a handler.
- Both topology changes applied to the live dev namespace and confirmed.
- **57 tests, 0 failed**, including the 10 integration tests.

The new test project introduced a high-severity advisory (`NU1903`,
`SSH.NET 2024.1.0`, transitively via `Testcontainers.MsSql 4.1.0`) and cleared
it in the same day by bumping to `Testcontainers.MsSql 4.15.0`, which resolves
`SSH.NET 2026.0.0`. Flagged rather than waved through on "it is test-only and
never ships" — that argument is true here and is also how advisories
accumulate. The pre-existing `SQLitePCLRaw` NU1903 in `Day7/piece2` is
untouched and remains Day 28's item.

**Still not covered:** Service Bus itself — filters, subscriptions, delivery,
dead-lettering. All three failures that have cost this project real time live
in that gap and none is catchable by these tests, which is why
`happy-path.ps1` against the live namespace remains part of the deliverable.

## Reviewing this

Commits are ordered so each builds on its own, and each message carries its own
reasoning — reading them in order is probably easier than reading the diff.
Comments get answered with a new commit that names the comment, or a reply
explaining why I disagree. No silent force-pushes.
