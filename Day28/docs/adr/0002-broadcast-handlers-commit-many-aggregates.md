# 0002 — A broadcast handler commits every aggregate it touches in one transaction

- **Status:** Accepted
- **Date:** 2026-09-16
- **Deciders:** Vaishalee Singh

## Context

`ICollectionRepository.SaveChangesAsync` carries a rule stated on the interface
itself: *one aggregate per transaction. There is no SaveAll: a use case that
needs two aggregates committed together is a use case whose boundaries are
wrong, or one that needs an integration event.*

Flow 2 and flow 3 both need a handler that touches an unbounded number of
`Collection` aggregates at once. A quote's canonical text is corrected once in
Catalog and every editable collection holding a snapshot of it has to be
refreshed; a quote clears review once and every editable collection holding it
has to learn that. One event, N aggregates, N unknown at design time.

Two things were already true and constrain the answer:

**The consumer host owns the transaction, not the handler.**
`*ServiceBusConsumerHost` opens a transaction, invokes the handler, inserts its
own `ProcessedMessages` row, and commits both together. That coupling is
deliberate and is the module's idempotency guarantee: the side effect and the
record that the message was handled are committed atomically, so a crash
between them is impossible. Every handler in the solution is written with no
`SaveChangesAsync` of its own, and each one says so in a comment.

**The rule and the requirement genuinely conflict.** This is not a case where
one reading makes them agree. A handler that refreshes six collections either
commits six aggregates in one transaction, or it takes control of transactions
away from the consumer host.

What was uncertain at the time of deciding: whether the rule is about
transaction *cardinality* or about aggregate *coupling*. The interface comment
does not say, and the difference decides this.

## Decision

A handler reacting to a broadcast event applies it to every matching aggregate
and lets the consumer host commit them all in its single transaction, as a
named exception to the one-aggregate-per-transaction rule.

## Alternatives considered

### Handler calls `SaveChangesAsync` once per aggregate

- **What it buys:** Literal compliance with the rule. Each aggregate commits
  alone, and a failure part-way leaves earlier aggregates durably updated
  rather than rolling everything back.
- **What it costs:** The `ProcessedMessages` row is written by the consumer
  host *after* the handler returns, in a transaction the handler has already
  committed inside. A crash between the handler's last save and the host's
  insert leaves corrections applied with no record the message was handled —
  so redelivery reapplies them. `ApplyQuoteRevision` and `MarkQuotePublishable`
  are both idempotent, so the reapplication is harmless *today*; it is harmless
  by luck, and the guarantee it breaks is the one every other consumer relies
  on.
- **It would have won if:** the consumer host committed `ProcessedMessages`
  independently of the handler's work, or if the side effects were not
  idempotent and partial application were therefore unacceptable.

### One event per affected collection, fanned out by a router

Catalog publishes `QuoteRevised`; a router consumes it, looks up the affected
collections, and republishes one `CollectionQuoteRevised` per collection, each
handled in its own transaction.

- **What it buys:** Genuine one-aggregate-per-transaction, and per-collection
  retry and dead-lettering — a poison collection fails alone instead of taking
  the batch with it.
- **What it costs:** A router that must itself read across the boundary to know
  who to fan out to, a second event type per correction, and N messages per
  correction where one would do. It also moves the read that decides the fan-out
  into a component with no aggregate of its own.
- **It would have won if:** corrections were high-volume, or a single failing
  collection blocking the others were a real operational problem rather than a
  theoretical one. **This is the most likely future replacement.**

### Widen the rule on the interface to permit this

- **What it buys:** No exception to explain; the comment and the code agree.
- **What it costs:** The rule is load-bearing. It is what stops a use case
  quietly coupling two aggregates' invariants, which is the failure it was
  written to prevent. Weakening it for a case that does not couple invariants
  would also permit every case that does.
- **It would have won if:** the rule had turned out to be about cardinality
  rather than coupling — but the reasoning recorded with it is explicitly about
  boundaries drawn wrong, which is a coupling argument.

## Consequences

**What we accept.**

- A correction touching many collections is atomic across all of them. A
  failure on the last one rolls back the first, and the message is abandoned
  and redelivered — correct, but more work repeated than strictly necessary.
- One poison collection blocks the whole broadcast for that message, and after
  the retry budget it dead-letters the correction for every collection, not
  just the one that failed.
- The transaction's size is unbounded in principle. It is bounded in practice
  by `Collection.MaxItems = 50` only per collection, not by the number of
  collections holding one quote. A popular quote in a thousand drafts is one
  transaction over a thousand aggregates.
- The rule on `ICollectionRepository` now has an exception, and an exception
  that lives only in a comment is one refactor away from being forgotten.

**What we now owe.**

- A bound on the fan-out before it becomes a production concern — either a
  batch size with continuation, or the router alternative above.
- Dead-letter monitoring. A broadcast that dead-letters currently tells nobody,
  and this decision makes a single dead letter cost more than one aggregate's
  worth of work.
- Integration tests that actually execute these handlers against a real
  database. **At the time of writing this ADR, neither handler has ever run.**
  The reasoning here is sound and unverified, which is the weakest thing about
  it.

## Evidence

- `QuoteRevisedHandler` and `QuotePublishableHandler`
  (`Day22/Capstone/src/Modules/Curation/QuotesPlatform.Modules.Curation.Infrastructure`).
- `ICollectionRepository.GetEditableByQuoteIdAsync`, whose own doc comment
  names this tension and points here.
- `CurationServiceBusConsumerHost.OnMessageAsync` — the transaction and the
  `ProcessedMessages` insert that make the per-aggregate alternative unsafe.

**What proves it works: nothing yet.** Composition tests prove both handlers
are registered, correctly keyed and constructible. No test runs either one.

## What would change our mind

Any one of these reopens it:

- A correction fans out to more than ~100 collections in practice, making the
  transaction size a real cost rather than a theoretical one.
- A single collection poisons a broadcast in production and takes an unrelated
  collection's correction down with it.
- The consumer host changes so that `ProcessedMessages` is committed
  independently of the handler's work — at which point the per-aggregate
  alternative becomes safe and is strictly better.
- Consumers move out of the API process (the trigger ADR-0001 already names for
  revisiting the outbox), since that is the natural moment to introduce the
  router.
