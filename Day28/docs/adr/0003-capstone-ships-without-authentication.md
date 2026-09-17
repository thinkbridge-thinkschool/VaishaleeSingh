# 0003 — The capstone runs without authentication, until 31 October 2026

- **Status:** Accepted
- **Date:** 2026-09-17
- **Expires:** **2026-10-31**, or immediately on first deployment to any shared
  environment, whichever comes first
- **Deciders:** Vaishalee Singh

## Context

Every write endpoint in `Day22/Capstone` takes the acting user's identity as a
plain string in the request body — `actorId`, `ownerId`, `reviewerId` — and the
aggregates compare that string against the one they stored.
`Collection.RequireOwner` is an ownership check, and the caller supplies both
sides of the comparison. `Program.cs` calls no `AddAuthentication` and no
endpoint calls `RequireAuthorization`.

So anyone who can reach the API and knows a collection id and its owner id can
act as that owner, and anyone at all can approve a review under any reviewer's
name. `Day31/docs/day31-threat-model.md` sets out the exploit paths; the one
that matters most is that `Review` exists to answer "who decided this", and it
currently records whatever the caller typed.

This was a deliberate scoping decision on Day 29 — *"endpoints take a plain
`actorId` for now, the same way Day 2–3 of the original API built persistence
before adding real auth"* — and it has been carried forward unexamined through
Days 29, 30 and 31.

What is true alongside it: the capstone **is not deployed**. It runs against a
local SQL Server container and a dev Service Bus namespace, reachable from a
developer machine and nothing else. There is no anonymous user because there is
no user; there is no attacker because there is no route.

What was uncertain when deciding: whether adding authentication now is cheaper
than adding it after the API surface settles. The surface grew by seven
endpoints on Day 30 alone.

## Decision

The capstone continues without authentication until **31 October 2026**, or
until it is deployed anywhere reachable by anyone other than its developer,
whichever comes first.

## Alternatives considered

### Add authentication now

- **What it buys:** The risk closes, and every endpoint added afterwards is
  written against a real principal rather than retrofitted.
- **What it costs:** A full day. A scheme, token validation, mapping a principal
  to the `actorId` the aggregates already expect, then reworking every endpoint
  signature, every integration test and every API test that currently passes an
  actor string — and `happy-path.ps1` besides. Day 31's brief is tests, perf and
  security, and spending it all here would deliver the security item by dropping
  the other two.
- **It would have won if:** the capstone were deployed, or if a second person
  were using it.

### A cheap guard — an API key, or the actor moved to a header

- **What it buys:** The actor id stops being attacker-supplied in the body, and
  a shared key keeps casual callers out.
- **What it costs:** **It is security theatre and this is the argument for
  rejecting it.** A header is exactly as forgeable as a body field; moving the
  string does not authenticate it. A single shared API key authenticates the
  deployment, not the user, so `RequireOwner` still compares two caller-supplied
  values. The real cost is that it *looks* handled — a reviewer seeing an API
  key stops asking about auth, and the finding goes quiet without going away.
- **It would have won if:** the goal were keeping strangers off a demo URL
  rather than knowing who did what. That is a real goal and this is a real tool
  for it — but it should be adopted as rate-limiting-with-a-password, not
  described as authentication.

### Accept it silently and carry on

- **What it buys:** Nothing this ADR does not.
- **What it costs:** The thing being avoided. Days 29 and 30 both recorded auth
  as deferred and both moved on; a third day of the same is how "deferred"
  becomes "the way it works".
- **It would have won if:** never.

## Consequences

**What we accept.**

- Any caller who reaches the API can act as any user, and the `Review` audit
  trail records an unverified name. **The audit trail is the sharpest edge
  here**, because it is believed precisely when it matters.
- The API tests added today assert that a non-owner is refused
  (`Acting_on_a_collection_you_do_not_own_is_refused`), which is true and
  narrow: it proves the aggregate compares the strings, not that the caller is
  who they claim. That test's comment says so, so it cannot be read later as
  evidence of access control.
- Rate limiting is not worth adding before this, because a limit per anonymous
  caller is a limit per IP — the weakest form of the control.

**What we now owe.**

- Authentication, before the expiry date or before any deployment.
- A decision on what `actorId` becomes afterwards: the aggregates take a string
  and should probably keep taking one, with the endpoint deriving it from the
  principal rather than the payload. Making that change endpoint-side keeps the
  domain unaware of authentication, which is worth preserving.
- A ZAP scan against the capstone Host. Day 27 ran one against `quotes-api`;
  this Host has never been scanned, so this ADR rests on a code review rather
  than a test.

## Evidence

- `Day31/docs/day31-threat-model.md` — exploit paths and the rest of the review.
- `Collection.RequireOwner`, `Collection.RequireMember` — the checks that look
  like authorisation and are not.
- `QuotesPlatform.Host/Program.cs` — no authentication middleware.
- `EndpointTests.Acting_on_a_collection_you_do_not_own_is_refused` — the narrow
  guarantee that does hold.

## What would change our mind

Any one of these ends the acceptance immediately, ahead of the date:

- The capstone is deployed anywhere reachable by anyone else — a container app,
  a demo URL, a shared environment.
- A second person starts using it, even locally.
- The `Review` audit trail is cited as evidence of anything by anyone.
- The API surface stops growing, which makes retrofitting cheap and removes the
  main argument for waiting.
