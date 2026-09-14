# Architecture Decision Records

A decision goes here when someone inheriting this system would otherwise ask
"why is this not simpler?" and find no answer.

Not every choice needs one. A record is worth writing when the decision is
**hard to reverse**, has a **wide blast radius**, or is **contested** — where a
competent engineer could reasonably have chosen differently. Everything else
belongs in a code comment next to the thing it explains.

## Index

| # | Decision | Status | Date |
|---|---|---|---|
| [0001](0001-transactional-outbox.md) | Transactional outbox for domain events | Accepted | 2026-09-14 |

## Statuses

| Status | Meaning |
|---|---|
| **Proposed** | Written, not yet agreed |
| **Accepted** | In force. The code reflects it. |
| **Superseded by NNNN** | Replaced. The original text is left untouched. |
| **Deprecated** | No longer in force and nothing replaced it |

**History is never edited.** A decision that turned out badly is more useful
than one that was quietly rewritten to look right — the point of the record is
to show what was known at the time. To change a decision, add a new ADR and set
the old one to *Superseded by*.

## Adding one

Copy `0000-template.md`, take the next number, add a row above.

Two rules that make the difference between a record and a justification:

1. **The context must not give away the decision.** If someone can read the
   context alone and only reach one conclusion, it was written backwards — the
   forces have been trimmed to fit the answer.
2. **Every alternative needs the condition under which it would have won.** An
   alternative with no winning condition was not considered, only listed.
