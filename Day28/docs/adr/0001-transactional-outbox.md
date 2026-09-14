# 0001 — Transactional outbox for domain events

- **Status:** Accepted
- **Date:** 2026-09-14
- **Deciders:** Vaishalee Singh; reviewed at the Day 28 design review

## Context

Writing a quote has two effects that users perceive as one: the row exists, and
the things that react to it happen — an audit entry is recorded and the search
projection is updated. Today both reactions live in the same process; they were
not always going to, and the design assumes they may move out.

The row lives in Azure SQL. The notification travels over Azure Service Bus.
These are two systems with independent availability, and the application has no
control over either one's failure timing. A container can also stop between any
two statements: Container Apps scales this app to zero and back, and a
deployment replaces instances mid-flight.

What the domain tolerates is not uniform. An audit entry that never appears is
a compliance gap and a silent one — nothing later would reveal that a write
went unrecorded. A search projection that lags by seconds is unremarkable. A
projection that *never* catches up is a bug users eventually report as "my
quote is missing from search". So the requirement is not symmetric: some
reactions must be guaranteed, all of them can tolerate delay, and one of them
can tolerate being applied twice more easily than being skipped.

Service Bus has been unavailable to this application during development, and
Redis has failed in a way the app was designed to survive. Neither of those
outages should be able to reject a user's write or leave the database
disagreeing with what was published.

At-most-once and at-least-once are the two shapes available without a
distributed transaction. There is no third.

## Decision

A write and its domain event are committed in the **same database
transaction** — the event as a row in `OutboxMessages` — and a background relay
publishes from that table to Service Bus afterwards, independently of the
request.

## Alternatives considered

### Commit the row, then publish (dual write)

- **What it buys:** No extra table, no relay, no retention job. The event is
  published in the request, so downstream reacts immediately.
- **What it costs:** A window between commit and publish in which the row
  exists and the event does not. Retry does not close it: the process can die
  inside the window, and a caught exception cannot un-commit the row. Failures
  are silent and unrecoverable — nothing afterwards knows an event was owed.
- **It would have won if:** the events were advisory and cheaply reconstructible
  — for example, if the audit trail could be rebuilt by scanning the `Quotes`
  table. It cannot: the audit records *that an event occurred*, which the row
  alone does not tell you.

### Publish first, then commit

- **What it buys:** The event is never lost.
- **What it costs:** Ghost events. A publish that succeeds followed by a commit
  that fails leaves consumers reacting to a quote that does not exist, and the
  search projection then holds a row with no backing record.
- **It would have won if:** consumers were purely idempotent *and* tolerant of
  references to rows that never materialise. The search projection is not — a
  result that 404s when clicked is worse than a result that appears late.

### Distributed transaction across SQL and Service Bus

- **What it buys:** Genuine atomicity across both systems, no extra moving
  parts in application code.
- **What it costs:** Azure Service Bus does not participate in a two-phase
  commit with Azure SQL; there is no coordinator available in this deployment.
  Even where one exists, it introduces blocking and a new component whose
  failure is worse than either resource's.
- **It would have won if:** both resources supported a shared coordinator and
  the operational cost of running one were already paid. Neither is true here.

### Change data capture (CDC / Debezium / SQL change feed)

- **What it buys:** The write path stays completely unaware of messaging. No
  outbox table, no relay in the application, and it captures writes made by
  anything — including a migration or a manual fix.
- **What it costs:** A separate piece of infrastructure to run and monitor, and
  events derived from *row changes* rather than *domain intent*. "UPDATE
  Quotes SET Text = …" does not distinguish a correction from a rename; the
  domain event does.
- **It would have won if:** several services wrote to these tables, or the
  write path could not be modified. Here one service owns the schema, and it is
  the service emitting the events.

### Event sourcing

- **What it buys:** The problem disappears — the event log *is* the write
  model, so there is nothing to keep in sync.
- **What it costs:** A different system. Rebuilding read models, versioning
  events forever, and giving up the straightforward relational queries this
  application is largely made of.
- **It would have won if:** the domain were audit-first with temporal queries
  as a core requirement. This one is CRUD with reactions.

### Nothing: let consumers poll

- **What it buys:** The least machinery of all.
- **What it costs:** Polling latency, load proportional to poll frequency
  rather than to change rate, and every consumer reimplementing "what have I
  already seen".
- **It would have won if:** there were one consumer and minutes of latency were
  acceptable. There are two already, and the pattern is the point of the
  exercise.

## Consequences

**What we accept**

- **At-least-once delivery, not exactly-once.** A relay that publishes and then
  fails before marking the row `Sent` will publish again. Every consumer must
  be idempotent; that is not optional and it is enforced by
  `ProcessedMessages`.
- **Latency between commit and publish.** Bounded by the relay's poll interval,
  shortened by a signal (`ChannelOutboxSignal`) but never zero.
- **No global ordering.** Events for different aggregates can arrive out of
  order. Nothing in this domain depends on cross-aggregate order; if something
  did, this decision would need revisiting.
- **The outbox table is on the write path.** Every write costs one extra
  INSERT, in the same transaction — a real cost, paid on every write, in
  exchange for a guarantee.

**What we now owe**

- A relay to run, monitor and reason about — including what happens when two
  instances run it at once. Handled by a lease (`LockOwner`,
  `LockedUntilUtc`), which is itself a thing that can go wrong.
- Retention. An append-only table on the write path grows forever;
  `OutboxRetentionService` prunes what has been sent.
- Explicit failure classification. `MessageFailureClassifier` decides poison
  versus transient, because "retry everything" and "dead-letter everything" are
  both wrong.
- Operational visibility. `/api/outbox/status` is mapped in **every**
  environment, because the question "has the relay stopped?" is asked in
  production, not in Development.
- Trace continuity across the seam. `traceparent` is stored on the row and
  restored on the consumer, or one user action becomes three unrelated traces.

## Evidence

- Write path: `Day7/piece2/QuotesApi/Services/QuoteWriteService.cs`,
  `Messaging/Outbox/EfOutboxWriter.cs`
- Relay and retention: `Messaging/Outbox/OutboxRelayService.cs`,
  `OutboxRetentionService.cs`
- Consumer and idempotency: `Messaging/QuoteEventProcessorService.cs`,
  `EfProcessedMessageStore.cs`
- Failure handling: `Messaging/MessageFailureClassifier.cs`; dead-letter after
  `MaxDeliveryCount` 5
- Schema: `Migrations/…_AddOutboxMessages.cs` — `Status`, `Attempts`,
  `LastError`, `LockOwner`, `LockedUntilUtc`, `TraceParent`, `SchemaVersion`
- Operations: `GET /api/outbox/status`
- Proven: a Service Bus outage during development left writes succeeding and
  events queued; the relay drained them on recovery. The distributed trace
  spanning API → relay → consumer was verified against Application Insights.

## What would change our mind

- **Consumers move out of process and need ordering.** A cross-aggregate
  ordering requirement is not something this design can satisfy by tuning.
- **The relay becomes a throughput bottleneck.** At a write rate where batch
  claiming is the limiting factor, CDC's separate infrastructure starts to look
  cheap rather than expensive.
- **Another service starts writing these tables.** The outbox only captures
  intent expressed through this application; a second writer makes CDC the
  honest answer.
- **The event becomes user-visible-synchronous.** If a user must see a
  reaction's result before the response returns, an eventual path is the wrong
  shape and the reaction belongs in the transaction.
