# Day 30 — Build day 2: feature completeness

**Branch:** `day30-feature-completeness` off `dev`, PR into `dev`. Code changes
land in `Day22/Capstone`; this folder holds today's docs and verification
artifacts.

## What "feature complete" means today, precisely

Day 29 built **one path through one of three flows**. The design
(`Day22/Capstone/docs/capstone-design.md`, "Async flows") names three, and each
one exists because a synchronous call would be wrong. Today closes all three
and the loop Day 29 cut out of the middle of flow 1.

| | Flow | Day 29 | Today |
|---|---|---|---|
| 1 | Publish: submit → review → approve → edition | Approve only | Reject, revise, edition *n* |
| 2 | Quote correction propagates to drafts only | Nothing | Whole flow |
| 3 | Quote moderation: submitted → review → publishable | `mark-publishable` stub | Whole flow |

Exit criterion for the day: **every path a reviewer can reach from the API is
either implemented or refuses with a domain error that says why.** No endpoint
returns 200 for something that did not happen — that was defect 2 of Day 29 and
it is the failure mode this day is most likely to repeat.

## Gap analysis — what the repo actually has

Read before planning, and it changes the shape of the day. The domain is
further ahead than the wiring, which is good news: most of today is plumbing
that already has a tested aggregate behind it.

**Already there, unwired.** `Collection.Reject`, `Collection.BeginRevision`,
`Collection.ApplyQuoteRevision`, `Collection.MarkQuotePublishable`,
`Collection.RemoveItem`, `Collection.Reorder`, `Collection.Rename`,
`Collection.AddMember`, `Review.Reject`, `Quote.Revise` — all implemented, all
covered by `CollectionInvariantTests`, none reachable through an endpoint or a
handler. Contracts `CollectionRejected`, `QuoteRevised`, `QuoteSubmitted`,
`QuotePublishable`, `QuoteApproved` are all declared and none is ever
published or consumed.

**Not there at all.** Catalog has no consumer host, no `ProcessedMessages`
table, no `IIntegrationEventHandler`, and no subscription. It is the only
module that is publish-only, and flow 3 makes it a consumer. That is the one
piece of net-new plumbing today, and it is why flow 3 is sequenced last.

### Five findings that are defects, not missing features

Worth stating separately because they are things that are wrong now, not things
that are absent, and three of them are invisible until a flow added today walks
into them.

**1. `POST /api/reviews/{id}/approve` publishes `CollectionApproved` for every
review regardless of subject.** `ModerationEndpoints` builds the event from
`review.SubjectId` without reading `review.Subject`. Today it is harmless —
only collection reviews exist. The moment flow 3 opens a `Quote` review,
approving it publishes a `CollectionApproved` carrying a QuoteId, Curation's
handler looks up a collection by that id, finds nothing, and the approval
vanishes silently. **Fix this in the first commit of the day, before the code
that triggers it exists**, not in the commit that discovers it.

**2. Re-submission after a rejection opens a second `Review` against the same
collection, and nothing supersedes the first.** `GetPendingBySubjectAsync`
returns *a* pending review; after a reject-then-resubmit there could be two, and
which one a reviewer approves decides whether the right round gets published.
The rejection path is the first thing that can produce this, so it has to be
decided in the same commit: a decided review is final (`RequirePending` already
enforces that), so the fix is on the open side — opening a review for a subject
that already has a pending one is either a no-op or an error, and it needs to be
one of the two on purpose.

**3. `ICollectionRepository` has no way to find collections by quote id, and the
port deliberately refuses to hand out `IQueryable`.** Flow 2 needs "every
editable collection holding this quote". Adding
`GetEditableByQuoteIdAsync` returning a list of aggregates is the shape that
respects the port's own reasoning. But that collides with the module's other
stated rule — **one aggregate per transaction, there is no SaveAll**. A
correction touching six collections is therefore six transactions, and a crash
after the third leaves three updated. That is acceptable (the event is
redelivered and `ApplyQuoteRevision` is idempotent), but it is a decision and it
belongs in an ADR rather than in a handler's control flow.

**4. Curation's subscription filter excludes everything today adds.**
`curation-review-decisions` carries
`eventType IN ('CollectionApproved','CollectionRejected')`. `QuoteRevised` and
`QuotePublishable` do not match, so Curation's consumer will never see them and
**nothing will error** — the messages are simply not delivered to that
subscription. This is Day 29 defect 3 in a new costume: a topology problem that
presents as silence. Two consequences: the topology script has to change, and
**the filter must be widened and applied before the publisher ships**, or the
first corrections published are dropped and never redelivered.

**5. `Collection.Reject` records the reason in a domain event and nowhere
durable.** `GET /api/collections/{id}` after a rejection shows `State: Draft`
with no indication why. The curator has to know to ask Moderation. Options are
to store the last rejection reason on the collection (duplicating Moderation's
data into Curation) or to leave it in Moderation and make the client do two
calls. **Recommendation: leave it in Moderation** — the decision and its
grounds belong to the module that made it, and copying it across the boundary
is the first step toward Curation growing a reviewer concept. Record the
reasoning; do not silently pick one.

## Ground rules (carried from Day 29, with one addition)

1. Small, reviewable, independently buildable commits. The sequence below is
   the commit sequence.
2. Every cross-module fact travels as an integration event through the outbox.
3. Architecture and composition tests stay green throughout.
4. **New:** every commit that adds a consumer also adds the test that proves
   the consumer is reachable. Day 29's five defects were all unreachable code
   paths that compiled. A handler with no test proving it runs is a handler
   nobody has run.

## The commit sequence

Four tracks, ordered so that each one's riskiest unknown is resolved before the
next one depends on it. Track A is entirely defect-fixing and ships first
because tracks C and D walk into those defects.

### Track A — correct what is wrong before adding to it (commits 1–2)

**1. `fix(moderation)`: approve and reject publish the event that matches the
review's subject.** Branch on `review.Subject`: `Collection` →
`CollectionApproved` / `CollectionRejected`, `Quote` → `QuoteApproved`. Add
`POST /api/reviews/{id}/reject` taking a required reason. Test: a `Quote`
review approved does not produce a `CollectionApproved`.

**2. `fix(moderation)`: opening a review for a subject that already has a
pending one is a no-op.** The handler is idempotent on `MessageId` already;
this makes it idempotent on *intent*, which is the property that survives a
resubmission rather than a redelivery. Test: two `CollectionSubmittedForPublication`
with different `MessageId` for the same collection produce one open review.

### Track B — close the flow 1 loop (commits 3–6)

**3. `feat(curation)`: `CollectionRejectedHandler`.** Applies
`Collection.Reject`, which returns the collection to `Draft` or `Revising`
depending on `EditionNumber`. Registered keyed on `nameof(CollectionRejected)`;
the subscription filter already admits it, so this one needs no infra change.

**4. `feat(curation)`: `POST /api/collections/{id}/revise`.** `BeginRevision`
on a published collection. The live edition keeps serving — that is the whole
point and it is what the verification has to show.

**5. `feat(curation)`: the editing endpoints the aggregate already supports** —
`DELETE /items/{quoteId}`, `POST /items/{quoteId}/reorder`, `PATCH` for rename,
`POST /members`. Cheap, and a curation module that cannot reorder a collection
is not feature complete in any sense a reviewer would accept.

**6. `fix(publishing)`: a unique index on `(CollectionId, EditionNumber)`.**
`ProcessedMessages` stops a redelivered message from building a second edition;
it does not stop Curation republishing edition 2 after a crash between its own
save and its relay. The index is the backstop that turns a duplicate edition
into a failed insert and a dead-lettered message instead of two editions at one
slug. Confirm `GetLatestBySlugAsync` returns the highest edition number, not
the most recently inserted row.

### Track C — flow 2, quote correction (commits 7–9)

**7. `feat(infra)`: widen Curation's subscription filter, and apply it.** Add
`QuoteRevised` and `QuotePublishable` to `curation-review-decisions`'s filter in
`00-provision-servicebus-topology.ps1`. The script already re-creates rules
rather than patching them, which is the behaviour this needs. **This commit
ships and the script runs before commit 8 exists** — publisher-before-filter is
the ordering that drops messages silently.

*Decision to record:* one widened subscription rather than a second
`curation-quote-updates`. One subscription means one receive loop and one
dead-letter queue to watch; two would let the review-decision path and the
correction path fail independently, which is worth having the day corrections
become high-volume and is not worth the second consumer host today.

**8. `feat(catalog)`: `PUT /api/quotes/{id}` revises canonical text and
publishes `QuoteRevised`.** Domain method exists; this is the endpoint, the
translator and the outbox write.

**9. `feat(curation)`: `QuoteRevisedHandler`.** Loads every editable collection
holding the quote via the new repository method, calls `ApplyQuoteRevision` on
each, saves each. `ApplyQuoteRevision` already returns quietly for published
collections, which is the rule from flow 2 and the reason a published edition
does not change under a reader. Test both halves: a draft's snapshot updates, a
published collection's does not.

### Track D — flow 3, quote moderation (commits 10–13)

The expensive track, last, because it is the only one that needs plumbing that
does not exist.

**10. `feat(catalog)`: consumer host, `ProcessedMessages` migration, keyed
handler dispatch.** Mirrors the three modules that already have it. Add
`catalog-quote-decisions` to the topology script filtered on
`eventType = 'QuoteApproved'`, applied before commit 12.

**11. `feat(catalog)`: `POST /api/quotes` publishes `QuoteSubmitted`.**

**12. `feat(moderation)`: `QuoteSubmittedHandler` opens a `Quote` review.**
Reuses the supersede rule from commit 2. Commit 1 already made the approve
endpoint publish `QuoteApproved` for this subject.

**13. `feat(catalog)`: `QuoteApprovedHandler` marks the quote publishable and
publishes `QuotePublishable`; `feat(curation)`: `QuotePublishableHandler`
applies it.** This is the commit that **retires `mark-publishable`** — the stub
Day 29 used in place of this flow. Deleting it is part of the commit, not a
follow-up: leaving both means two ways to make a quote publishable and only one
of them audited.

## Verification

**Integration tests against real SQL Server, in CI.** The Day 7 Testcontainers
setup already in this repo, reused rather than re-invented. Service Bus is
faked at the relay seam — the handler contract is "given this event, this
happens", and proving that does not need a broker; proving the *broker* works
is what the live run is for.

The tests that have to exist by end of day, one per path added:

- Reject returns a published collection to `Revising` and an unpublished one to
  `Draft`.
- A rejected collection can be edited, resubmitted, and reaches edition 1.
- A published collection revised and resubmitted reaches edition 2, and
  edition 1's rows are unchanged.
- `QuoteRevised` updates a draft's snapshot and leaves a published edition's
  text alone.
- A quote is not publishable until its review is approved, and a collection
  holding it cannot be submitted before then.
- Every handler added today is reachable from its module's registered dispatch
  — extend `ModuleCompositionTests`, which is the test that would have caught
  Day 29 defects 1 and 2.

**And one live run**, because the integration tests deliberately do not cover
the broker: extend `happy-path.ps1` into `feature-complete.ps1` covering reject
→ edit → resubmit → approve → revise → resubmit → edition 2, plus a correction
that reaches a draft and stops at an edition. Save the transcript. Day 29's
lesson was that a round of running found more than a round of reasoning; the
tests are there so that this run is the *second* time each path executes, not
the first.

## Risk and the cut line

Thirteen commits is aggressive for one day, and the honest failure mode is
track D half-landed — a consumer host with no handler behind it, which is worse
than no consumer host.

**The cut is at the track boundary, not inside one.** If track D cannot be
finished and tested today, it does not start; commits 10–13 move to Day 31 and
`mark-publishable` stays with its comment updated to say the flow that replaces
it is dated and planned. Tracks A–C with tests is a better PR than A–D without.

**The likeliest surprise** is the subscription filter change (commit 7). If the
namespace rule cannot be re-created — a permissions gap, the same data-plane
role propagation delay that cost Day 29 an hour — track C stalls with its code
correct and undeliverable. Verify the rule change against the live namespace
first thing, not at the point commit 9 needs it.

## Deliberately deferred, again and by name

- **Authentication.** Endpoints still take a plain `actorId`. This is Day 31 in
  `Day28/docs/day28-build-plan.md` and it is a day, not an afternoon.
- **Retention for `OutboxMessages` and `ProcessedMessages`.** Both tables grow
  without bound. Named on Day 29, still true, and it becomes a real problem at
  a volume this project will not reach before it is addressed.
- **Poison-message handling beyond the Day 20 retry budget.** A handler that
  throws deterministically dead-letters after the budget. Nothing watches the
  dead-letter queues — that is an operations gap, and it is the one most worth
  closing next.
- **Any UI.**

## The PR

One PR into `dev`, opened when track C is green rather than at end of day, so
review comments arrive while there is still time to act on them. Draft while
track D is in flight.

Review protocol, since this is the part of the day being assessed as much as
the code:

- A comment I agree with gets a fix in a **new commit** that names the comment.
  No silent force-push — rewriting history under a reviewer mid-review makes
  their earlier reading unverifiable.
- A comment I disagree with gets a reply with the reasoning and the trade-off,
  and stays open until the reviewer closes it. "Fixed" on something I think was
  right before is worse than an argument.
- A comment that finds something neither of us had considered gets its own
  commit and a line in the submission, because that is the thing most worth
  recording.
- Rebase and squash only after approval, and only if the reviewer wants it.
