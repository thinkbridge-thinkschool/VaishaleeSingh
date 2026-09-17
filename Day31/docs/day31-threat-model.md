# Day 31 — capstone threat model

Modelled on `Day27/docs/day27-threat-model.md`, which covers `quotes-api` and
its infrastructure. The capstone has never had one, and it is now the part of
this repository with the most code written most recently.

**Scope:** `Day22/Capstone` — the Host, its four modules, its database and its
Service Bus topology. Not `quotes-api`; that is Day 27's document and nothing
here changes it.

## The headline, stated first because everything else is secondary to it

**There is no authentication. Every endpoint trusts an identity supplied in the
request body.**

`Program.cs` calls no `AddAuthentication`, no `AddAuthorization`, and no
endpoint calls `RequireAuthorization`. Every write endpoint takes an `actorId`,
`ownerId` or `reviewerId` as a plain string in its request payload, and the
aggregate compares that string against the one it stored:

```csharp
private void RequireOwner(string actorId, string action)
{
    if (RequireUserId(actorId, nameof(actorId)) != OwnerId)
        throw new DomainException($"Only the owner may {action}.");
}
```

`Collection.RequireOwner` is an **ownership check, not an authentication
check.** It answers "does this string equal that string", and the caller
supplies both halves of the comparison.

### What that actually allows

Anyone who can reach the API and knows two public-ish identifiers — a collection
id and the owner id it was created with — can do everything its owner can.

| Attack | Request | Result |
|---|---|---|
| Rename someone's collection | `PATCH /api/collections/{id}` with `actorId` set to the real owner | Succeeds |
| Add yourself as a contributor | `POST /api/collections/{id}/members` with the owner's id as `actorId` | Succeeds |
| Submit an unfinished collection for review | `POST .../submit` as the owner | Succeeds |
| Approve your own collection | `POST /api/reviews/{id}/approve` with any `reviewerId` | Succeeds, publishes an edition |
| Attribute a decision to a named colleague | any `reviewerId` string | The `Review` records their name |

The last one is the worst and the least obvious. `Review` exists precisely so
that "who decided this, and when" is answerable — its own doc comment says
collapsing it into `Collection` would "make 'who rejected edition 3'
unanswerable". **The audit trail it provides is unauthenticated, so it records
whatever the caller typed.** An audit trail that can be written by the person
it incriminates is worse than no audit trail, because it is believed.

Collection ids appear in `Location` headers and in every response body; owner
ids appear in every collection response. Neither is secret.

### Why it is being recorded and not fixed today

Real authentication is a full day: a scheme, token validation, mapping a
principal to the `actorId` the aggregates expect, and reworking every endpoint
signature and every test that passes an actor string. Started and half-finished,
it is **worse than none**, because a login screen in front of an unauthorised
API is security that looks handled.

This is the same treatment `day28-build-plan.md` gives the two-auth-scheme debt
in `quotes-api`: an accepted risk gets an ADR **with an expiry date**, on the
argument that an accepted risk with no expiry is a forgotten risk. See
**ADR-0003**.

**What makes the acceptance defensible today, and what would end it:** the
capstone is not deployed. It runs against a local SQL container and a dev
Service Bus namespace, reachable only from a developer machine. The moment it
is exposed to anything — a shared environment, a demo URL, a container app —
the acceptance expires immediately regardless of the date in the ADR.

## Everything else, by where it sits

### The API surface

| # | Finding | Severity | State |
|---|---|---|---|
| 1 | No authentication (above) | **High** | Accepted, ADR-0003 |
| 2 | No rate limiting | Medium | Open |
| 3 | No request body size limit beyond Kestrel's default | Low | Open |
| 4 | No security headers on API responses | Low | Open, argued below |
| 5 | Domain error messages returned to the caller | Informational | Deliberate |

**2 — No rate limiting.** `POST /api/quotes` writes a row and an outbox row per
call, and the outbox is drained by a relay polling on a short interval. A loop
against it grows the database and the topic without bound. .NET's built-in
`AddRateLimiter` is a small change; it is listed rather than done because it
belongs with authentication — a limit per anonymous caller is a limit per IP,
which is the weakest version of the control.

**3 — Request size.** `Collection.MaxItems` is 50 and `Quote.MaxTextLength` is
1000, so the aggregates refuse oversized *content*. Nothing refuses an oversized
*request* before it is deserialised and reaches them.

**4 — Security headers.** Day 27 added these for the SPA through nginx. The
capstone Host serves JSON to API callers and no browser-rendered HTML, so CSP
and friends do less here than they look like they should. `X-Content-Type-Options:
nosniff` is still worth having. Recorded as a decision rather than an oversight.

**5 — `DomainException` messages reach the caller** as `400 { "error": "..." }`.
Read through them: they are written for a user ("A collection needs at least 3
items before it can be published"). None leaks a connection string, a path, or
a stack frame. This is deliberate and the alternative — a generic 400 — would
make the API unusable. Worth re-checking whenever a new message is written.

### Data and messaging

| # | Finding | Severity | State |
|---|---|---|---|
| 6 | SQL password supplied by environment, never defaulted in a file | — | **Good, keep** |
| 7 | Service Bus uses `DefaultAzureCredential`; `disableLocalAuth = true` | — | **Good, keep** |
| 8 | `OutboxMessages` and `ProcessedMessages` grow without bound | Medium | Open |
| 9 | Nothing watches the dead-letter queues | Medium | Open |
| 10 | No cross-schema foreign keys | — | **Good, keep** |

**6 and 7 are the things this codebase gets right**, and a threat model that
only lists faults teaches the wrong lesson. `run-host.ps1` refuses to start
rather than defaulting a password into a committed file; the namespace has no
connection-string path at all, so there is no key to leak. Both were deliberate
choices on Day 29.

**8 — Unbounded growth** is a availability finding rather than a confidentiality
one, and it is already recorded in the Day 29 and Day 30 submissions. Combined
with finding 2, an unauthenticated caller can grow those tables deliberately.

**9 — Dead letters.** A poison message stops being retried and nothing reports
it. Noted here because "the system silently stops doing something" is a security
property as much as an operational one.

### What was checked and found clean

Worth recording, because "not mentioned" and "checked and fine" look identical
in a document that only lists problems.

- **No raw SQL anywhere.** Every query is EF Core LINQ; the only string-built
  SQL in the repository is in `Day31/scripts/01-seed-editions.ps1`, which is a
  local seeding tool taking integers, not user input.
- **No secrets in the repository.** `appsettings.json` has the connection string
  and namespace deliberately empty.
- **No cross-schema foreign keys**, so a module compromise does not become a
  join into another module's data.
- **Idempotency on every consumer** via `ProcessedMessages`, so a replayed
  message is not a way to apply a side effect twice.

## What is NOT covered by this document

- `quotes-api` and its infrastructure — Day 27.
- Dependency vulnerabilities. The `SQLitePCLRaw` NU1903 in `Day7/piece2` is
  still open and still Day 28's item.
- Anything dynamic. **No ZAP scan has been run against the capstone Host.**
  Day 27 ran ZAP against `quotes-api` and the SPA; pointing it at this Host is
  the obvious next step and is not done. This document is a code and design
  review, not a test.
