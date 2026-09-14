# Day 28 — Design review + ADR

**Task.** Mentor + peer critique of the capstone design. Write the ADR for the
one decision that matters most (the trade-off, the alternatives, why), and plan
the build day by day.

| Deliverable | File |
|---|---|
| Design brief — current architecture | `Day28/docs/day28-design-brief.md` |
| **ADR-0001 — transactional outbox** | `Day28/docs/adr/0001-transactional-outbox.md` |
| ADR index, statuses, how to add one | `Day28/docs/adr/README.md`, `0000-template.md` |
| Review notes | `Day28/docs/day28-review-notes.md` |
| Build plan, day by day | `Day28/docs/day28-build-plan.md` |
| Plan for this day | `Day28/docs/day28-plan.md` |

---

## 1. The brief describes what runs, not what was built

It is organised by how the system works — write path, read path, identity,
resilience, security, delivery — with no mention of which day added what.
Nobody inheriting this cares about the order things arrived in.

Before writing it, the deployed system was asked rather than remembered:

```
quotes-api-dev   …/quotes-api:9a57a6e14264   minReplicas 0
quotes-web-dev   …/quotes-web:9a57a6e14264   minReplicas 0
quotes-api-prod  …/quotes-api:9a57a6e14264   minReplicas 0
quotes-web-prod  …/quotes-web:9a57a6e14264   minReplicas 0

sql-quotes-7mo4cimyk4vnk   AzureAdOnlyAuthentication  True
sql-quotes-whppc5qu7yzzg   AzureAdOnlyAuthentication  True
sb-quotes-7mo4cimyk4vnk    disableLocalAuth           True
sb-quotes-whppc5qu7yzzg    disableLocalAuth           True
```

Two things that reading confirms and memory would have got wrong: **prod runs
the identical image dev tested** — promoted, never rebuilt — and **both
environments scale to zero**, which is a cost decision the deploy pipeline had
to be taught to understand.

The brief also names its own weaknesses before anyone else does — no private
endpoint, two live auth schemes, per-IP-only rate limiting, a single point of
prevention with no alert. A review spent *discovering* those is a review that
never got to *judge* them, and judgement is the part worth an hour of someone
else's time.

---

## 2. Choosing which decision to record

"The one that matters most" is a judgement, so it was made against stated
criteria rather than taste: blast radius, irreversibility, contestedness, and
whether its consequences have already been felt.

| Candidate | Why not chosen |
|---|---|
| Promotion by image import, not rebuild | High value, but barely contested — few would argue for rebuilding per environment |
| Public data tier with Entra-only auth | Largely *forced* by the subscription. How we responded was a decision; whether to was not. Queued as ADR-0002 |
| SPA in its own nginx container | Real trade-off, already reversed once — but local in blast radius |
| **Transactional outbox** | **Chosen.** Widest blast radius: it defines what "the write succeeded" means. Genuinely contested — dual write, CDC and publish-first are all defensible. Consequences already felt. |

---

## 3. ADR-0001 — the trade-off in one paragraph

A write and its domain event commit in the **same database transaction**, and a
relay publishes from that table afterwards.

The alternative most people reach for — commit, then publish — has a window in
which the row exists and the event does not, and **retry cannot close it**,
because the process can die inside the window and a caught exception cannot
un-commit a row. The outbox eliminates the window by making the event part of
the same commit.

What that costs, stated rather than glossed: at-least-once delivery (so every
consumer must be idempotent), latency between commit and publish, no global
ordering, and one extra INSERT on every write. What it obliges us to build: a
relay with a lease so two instances do not double-publish, a retention job
because an append-only table on the write path grows forever, explicit poison
classification, an operator-facing status endpoint, and trace propagation
across the seam.

Five alternatives are recorded — dual write, publish-first, distributed
transaction, CDC, event sourcing, and doing nothing — and **each one states the
condition under which it would have won**. That requirement is the ADR's
honesty test: an alternative with no winning condition was never considered,
only listed. CDC, for instance, would have won had a second service written
these tables; it did not, so it lost on grounds that could change.

The ADR ends with **what would change our mind** — consumers moving out of
process with an ordering requirement, the relay becoming a throughput
bottleneck, a second writer appearing, or a reaction becoming synchronous from
the user's point of view. A decision record without that section is a monument.

---

## 4. The review

Sent with the ADR marked **draft**, and with five specific questions rather
than "any feedback?", including two whose honest answer is uncomfortable:
whether the outbox is worth its complexity here at all, and what in this design
a reviewer would refuse to be on call for.

`day28-review-notes.md` quotes each critique **before** answering it, and every
entry carries a disposition — accepted, rejected with a reason, or deferred to
a named day. A critique with no disposition is one that was heard and ignored.

Where responses have not yet arrived, the file records *asked and unanswered*,
with the date. Writing up a review that did not happen would be the same
failure as an ADR that argues for a decision already made.

---

## 5. The build plan

Days 29–32 are drawn entirely from open findings already recorded in Day 27 —
no invented work. Ordering is **detection before hardening**: the alert on
`azureADOnlyAuthentication` comes first because, with no private endpoint
possible, that single setting is the wall in front of the database and nothing
watches it today.

Every day has an exit criterion someone else could check. The Day 29 one is
deliberately strict: the alert must have **fired once during a deliberate test
change**. An alert nobody has seen fire is a configuration, not a control.

Dates are labelled estimates. A plan projecting certainty makes the same
mistake as an ADR presenting its decision as inevitable — it hides the
judgement instead of exposing it.
