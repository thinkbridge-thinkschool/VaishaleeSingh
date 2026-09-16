# Day 30 — Build day 2: feature completeness (submission)

**Branch:** `day30-feature-completeness`. Code changes in `Day22/Capstone`;
today's docs in `Day30/`; two script changes in `Day29/scripts/`.

| Deliverable | Where |
|---|---|
| Plan and gap analysis | `Day30/docs/day30-plan.md` |
| This submission | `Day30/docs/day30-submission.md` |
| Pull request | *(link once opened, into `dev`)* |

## What "feature complete" means at the end of today, precisely

Two of the design's three async flows are complete. The third is not, and it
was cut at a track boundary rather than half-built.

| | Flow | Start of day | Now |
|---|---|---|---|
| 1 | Publish: submit → review → approve → edition | Approve only | Approve **and reject**, revise, edition *n* |
| 2 | Quote correction reaches drafts, stops at editions | Nothing | Complete |
| 3 | Quote moderation: submitted → review → publishable | `mark-publishable` stand-in | **Deferred to Day 31**, stand-in still in place |

Twelve commits. `dotnet build` and `dotnet test` green; the topology change is
applied to the live namespace.

## The gap analysis is most of the value

The plan's first job was to find out what was actually missing, and the answer
changed the shape of the day: **the domain was far ahead of the wiring.**
`Collection.Reject`, `BeginRevision`, `ApplyQuoteRevision`, `MarkQuotePublishable`,
`RemoveItem`, `Reorder`, `Rename`, `AddMember`, `Review.Reject` and
`Quote.Revise` were all implemented on Day 22, all covered by
`CollectionInvariantTests`, and **none of them reachable through an endpoint or
a handler.** Every contract for all three flows was declared and five of them
were published by nobody and consumed by nobody.

So most of today was not writing behaviour. It was connecting behaviour that
had been sitting there, tested, for eight days.

### Two plan items were struck rather than done

Recorded because deleting work from a plan is a result, and doing invented work
to make a plan look complete is the failure it prevents.

- **A unique index on `(CollectionId, EditionNumber)`** was planned as the
  backstop against two editions at one slug. It already exists in
  `EditionConfiguration`, and `GetLatestBySlugAsync` already orders by edition
  number rather than insertion order. Day 22 got both right.
- **Domain tests for reject, revise and correction** were planned. All of them
  already exist — `A_rejected_revision_returns_to_revising_not_to_draft`,
  `A_rejection_must_carry_a_reason`,
  `A_second_publish_increments_the_edition_rather_than_replacing_it`,
  `A_quote_revision_does_not_touch_a_published_collection`. Writing them again
  would have added a number to the test count and nothing to the confidence.

### And one finding was downgraded

The plan claimed re-submission after a rejection opens a second `Review` with
nothing superseding the first. Walking the states, that is hard to reach: a
collection `InReview` refuses another submit, resubmission only becomes
possible after a decision, and by then the previous review is decided rather
than pending. The guard shipped anyway, and **its commit message says outright
that it is defence in depth and not a fix for an observed bug.** What it buys is
that "the pending review for this collection" has one answer;
`GetPendingBySubjectAsync` orders by `OpenedAt` and takes the first, which is a
query written by somebody who expected more than one row to be possible.

Standing behind a claim that turned out to be weaker than stated, in the
document that made it, is the point.

## The defect worth the whole day

`POST /api/reviews/{id}/approve` built a `CollectionApproved` from
`review.SubjectId` **without ever reading `review.Subject`.**

Correct for exactly as long as collection reviews are the only kind of review.
The moment flow 3 opens a review for a *quote*, approving it publishes a
`CollectionApproved` carrying a QuoteId: Curation's handler looks for a
collection with that id, finds nothing, completes the message, and leaves no
trace. **A wrong event is worse than a missing one**, because it is delivered,
handled and acknowledged.

Fixed in the first commit of the day — ahead of the code that triggers it,
rather than in the commit that would have discovered it. The mapping now lives
in `ModerationIntegrationEventTranslator`: exhaustive over (subject, outcome),
a pure function of the aggregate, and therefore testable without a database, a
broker or a host. Seven tests, one of which asserts the negative.

A rejected quote maps to `null` deliberately. Nothing outside Moderation
changes — the quote was never publishable, so there is nothing to undo, and
telling the submitter is a notification, which the design defers. Publishing a
`QuoteRejected` that no module consumes would be a message shaped like a
feature.

## Three decisions a reviewer should push on

Each is in its commit message too, so they are arguable rather than discoverable.

**1. The rejection reason stays in Moderation.** `Collection.Reject` takes a
reason, raises a domain event with it, and persists it nowhere — so after a
rejection, `GET /api/collections/{id}` shows a `Draft` with no indication why.
The alternative was to store it on the collection. Rejected: a decision and its
grounds belong to the module that made them, and the first copy of a reviewer's
words into a curator's aggregate is the beginning of Curation growing a reviewer
concept it has no business owning. `GET /api/reviews/by-subject/{id}/latest` is
the second call, and the second call is the correct cost at a module boundary.

**2. `QuoteRevisedHandler` commits more than one aggregate**, against the rule
stated on `ICollectionRepository.SaveChangesAsync`. The rule exists to stop a
use case coupling two aggregates' *invariants* — "these must be consistent with
each other" is the signal a boundary is drawn wrong — and that is not this.
Each collection's snapshot is independent; none can leave another invalid.

Splitting it is also not available: the consumer host commits handler work
together with its own `ProcessedMessages` row, so a handler saving early would
let a crash between the two leave a correction applied with no record that the
message was handled. The real choice is one transaction over N independent
aggregates, or a broken idempotency guarantee.

**This belongs in an ADR and does not have one yet.** Named here so the debt is
not silent.

**3. Remove is `POST .../items/{quoteId}/remove`, not `DELETE`.** The actor has
to travel with the request, and on a DELETE that means a user identifier in the
query string, where it lands in access and proxy logs nobody scrubs. Less tidy
verb; the request that does not leak.

## The topology change shipped before the code that needs it

`curation-review-decisions` carried `eventType IN ('CollectionApproved','CollectionRejected')`.
Flows 2 and 3 both deliver to Curation and **neither `QuoteRevised` nor
`QuotePublishable` would have matched — and neither would have errored.** A
subscription whose filter does not match never receives the message and never
gets a redelivery.

That is Day 29's topology defect in a new costume, so the filter is its own
commit, landed and **applied to the live namespace before** the publisher
commits. Verified with `-DryRun` and then for real against
`sb-quotes-7mo4cimyk4vnk`.

One widened subscription rather than a second one for quote events: one receive
loop, one dead-letter queue to watch. The trade is that the review-decision path
and the correction path now fail together, worth revisiting the day corrections
become high-volume. The subscription's name is now narrower than its contents;
renaming means deleting and recreating it, losing anything in flight and
anything dead-lettered, which is not a price worth paying for a name.

## What the day cost, and where

Worth recording precisely, because the pattern is the same one Day 29 named.

| # | Failure | Where it was |
|---|---|---|
| 1 | `MSB4025` on restore: `--` inside an XML comment in the new test project's csproj. The house style in the `.cs` files is a syntax error in a project file | **my code**, caught by CI on the first run |
| 2 | Three builds lost to a `QuotesPlatform.Host` left running from Day 29, holding every module's DLL. 28 errors, 148 warnings, and the word "locked" only at the end of each line | environment |
| 3 | An hour spent on CS0246 errors reporting that types in one project did not exist. They did. The blocked DLL copy meant the language server kept resolving against a stale assembly | **diagnosis**, downstream of 2 |
| 4 | Nine files written with LF endings into a repo that normalises to native CRLF. Git normalised on commit so nothing was ever wrong in the repository, but the working tree drifted | **my tooling** |

Failure 3 is the one worth keeping. A blocked build and a stale language server
produce *a compile error in code that is fine* — and the instinct is to go
looking for the bug the IDE describes. What ended it was noticing the shape:
every type in one project unresolvable while its `using` directives resolved,
including a type nobody had touched since Day 29. **A file that "stopped
existing" without being edited is not a code problem.**

`Day29/scripts/stop-host.ps1` exists because of failure 2, and it was written
on the day it was annoying, which is the only day anybody writes that script.

## The real gap, stated plainly

**No handler in this solution has ever been run against a database.** The three
new composition tests prove each one is registered, correctly keyed and
constructible — which catches the failure shape that has now cost time three
times in two days of building (the Day 29 publisher collision, this morning's
subscription filter, and a mis-keyed handler, all of which are "the message
went nowhere and nothing complained").

What they do not do is run a handler. `CollectionRejectedHandler` and
`QuoteRevisedHandler` have never executed. Neither has any endpoint added
today. The Testcontainers harness the plan called for was not built, and until
it is, tracks B and C are **compiled and composed, not verified.**

That is the honest state, and it is the first thing on Day 31 — ahead of
flow 3, because more unverified surface is worth less than confidence in what
is already there.

## Deferred, by name

- **Flow 3, quote moderation.** Cut at the track boundary per the plan, not
  half-built. Catalog needs a consumer host, a `ProcessedMessages` migration, a
  fourth subscription, and four commits. `mark-publishable` remains the
  documented stand-in.
- **Integration tests against real SQL Server.** Above.
- **ADR-0002**, the one-transaction-over-N-aggregates decision.
- **Authentication.** Endpoints still take a plain `actorId`. Day 31 in
  `Day28/docs/day28-build-plan.md`; a day, not an afternoon.
- **Retention for `OutboxMessages` and `ProcessedMessages`.** Both grow without
  bound.
- **Dead-letter monitoring.** Poison messages dead-letter after the Day 20
  retry budget and nothing watches the queues. Given three "silent message"
  failures in two days, this is the most valuable thing not on today's list.
