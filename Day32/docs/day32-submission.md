# Day 32 — Ship + demo + postmortem

**Branch:** `day32-ship-and-postmortem`
**Date:** 2026-09-18

---

## The three artefacts the brief asks for

### 1. Live URL

**https://ca-quotes-capstone.greenhill-88fb93d9.uaenorth.azurecontainerapps.io**

| | |
|---|---|
| Host | Azure Container Apps (`ca-quotes-capstone`, revision `0000004`) |
| Database | Azure SQL serverless, auto-pause 60 min |
| Broker | The Day 29 Service Bus namespace, `disableLocalAuth = true` |
| Registry | ACR, admin user **disabled** — the app pulls with its managed identity |
| Auth | Microsoft Entra, JWT bearer, default-deny |
| Region | `uaenorth` |

Two endpoints you can try without credentials, and they are meant to answer
differently:

```
GET  /health            -> 200 {"status":"ok"}   the one anonymous endpoint
POST /api/collections   -> 401                   everything else
```

**That 401 is the deliverable, not a side effect.** ADR-0003 accepted shipping
without authentication *"until 2026-10-31, or immediately on first deployment
to any shared environment, whichever comes first"*, on the explicit argument
that there was no attacker because there was no route. Shipping created the
route, so the acceptance ended before the first deploy, not after it.

### 2. Demo

**`Day32/verification/happy-path-live.txt`** — full transcript.
**`Day32/scripts/happy-path.ps1`** — the script that produced it.

Run against the live URL with **two distinct client-credential identities**:

```
1. Acquiring tokens for two distinct identities...
2. Anonymous write is refused...                     401
3. Curator creates a collection...                   owner=9ce0497c-... (from the token)
4. Curator adds three items...                       3 items
5. A DIFFERENT authenticated caller renames it...    400 (RequireOwner)
6. Curator submits for publication...                review opened after 2s
7. Reviewer approves...                              reviewerId=642f54eb-... (from the token)
                                                     reviewer != owner
8. Waiting for Publishing...                         Published after 2s
                                                     edition 1 with 3 items
```

**Two identities, not one, and the script enforces it.** With a single identity
the curator who owns the collection is also the reviewer who approves it, so
every ownership guard passes trivially and the run proves nothing. Step 7
asserts `reviewerId != ownerId` and throws if they match — a demo that cannot
fail is not evidence.

What this exercises that the 76 tests cannot: the API tests strip out every
hosted service, so nothing crosses the broker there. This is the only thing
that drives the outbox relays, the Service Bus topic and its SQL filters, and
all four consumers — against the real namespace, authenticated with a managed
identity.

### 3. Postmortem

**`Day32/docs/day32-postmortem.md`** — one page: what I'd do differently, what
the hardest bug taught me, what I'm proudest of.

Its three headings in one line each:

- **Differently:** check the environment's constraints before designing around
  them. I verified the one limit I had thought of (tenant app-registration
  policy) and discovered two I hadn't (ACR Tasks unavailable on Students,
  express environments cannot use managed identity for registry auth) by
  failing.
- **Hardest bug:** three confident explanations of one symptom, two of them
  wrong — and I wrote the first into the script's own warning text, where a
  future reader would have trusted it and taken a weaker fallback for no
  reason. A guess recorded as a diagnosis outlives the person who guessed.
- **Proudest:** the deploy script refuses to report success unless an
  unauthenticated write returns 401. The ADR's expiry is enforced by the
  deployment, not by anyone remembering it.

---

## What shipped today

| Piece | Where |
|---|---|
| Authentication | `Program.cs`, `SharedKernel/CallerIdentity.cs`, all four modules' endpoints |
| Container image | `Day22/Capstone/Dockerfile`, `.dockerignore` |
| Provisioning | `Day32/scripts/00-provision-azure.ps1` |
| Identity | `Day32/scripts/01-provision-identity.ps1` |
| Deploy | `Day32/scripts/02-deploy.ps1` |
| Demo | `Day32/scripts/happy-path.ps1` |

**Tests: 72 → 76**, all green, including three new anonymous-refusal cases and
one asserting the owner comes from the token rather than the payload.

### The design decision that kept this contained

**The domain never learned that authentication exists.**
`Collection.RequireOwner` is byte-identical to yesterday — it still compares
two strings. Only the *source* of one changed, from the request body to
`ClaimsPrincipal.ActorId()`, which reads the `oid` claim off a validated token.
All 34 domain and application tests were unmodified. The endpoint layer
absorbed the whole change.

`actorId`, `ownerId` and `submittedByUserId` were **removed** from the request
records rather than deprecated. A record that still accepts a field and ignores
it is one people keep filling in, believing it matters.

### The test that makes the others mean something

`Anonymous_requests_are_refused`. A test authentication handler that always
succeeds turns an entire suite green while proving nothing — the middleware
could be absent. So `TestAuthenticationHandler` returns `NoResult()` when the
actor header is missing, specifically so that test *can* fail. The live logs
confirmed it firing three times, once per case.

---

## Open, honestly

- **`--min-replicas 1`** keeps four outbox relays polling continuously. Right
  for a demo, wrong for a student credit.
- **Shares a Container Apps environment** with Day 5's `quotes-api-dev`.
  Expedient; the environment created for this (`cae-quotes-capstone`) turned
  out to be an express one and could not host it.
- **The SQL admin password** is a Container App secret. Entra-only SQL auth
  would remove the last password in the system.
- **`.capstone-demo-secrets.json`** holds two live client secrets outside the
  repository. Delete it when the demo is done.
- **This is a student subscription.** The credit expires and the deployment
  stops with it — "permanent" is not the right word, and the submission should
  not use it.
- **No load test against the live URL.** Day 31's perf work was inconclusive on
  a laptop; it would be no better through a public endpoint.
