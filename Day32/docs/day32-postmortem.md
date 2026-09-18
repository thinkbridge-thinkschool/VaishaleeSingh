# Day 32 — Postmortem

**Shipped:** https://ca-quotes-capstone.greenhill-88fb93d9.uaenorth.azurecontainerapps.io
**Date:** 2026-09-18 · **Branch:** `day32-ship-and-postmortem`

The capstone runs in Azure Container Apps against Azure SQL and the Day 29
Service Bus namespace, with Entra authentication on every endpoint but
`/health`. `happy-path.ps1` walked submit → moderate → approve → publish
against the live URL with two distinct identities. 76 tests green.

---

## What I'd do differently

**Check the environment's constraints before designing around them.** Three
Azure limits shaped today and I had verified exactly one in advance. I
carefully checked whether the university tenant allowed app registrations —
because I had thought of it — and never checked whether an Azure for Students
subscription offers ACR Tasks (it doesn't), or what kind of environment
`az containerapp env create` produces by default (an express one, which cannot
use managed identity for registry auth). The absence of constraints I hadn't
thought of felt like evidence there weren't any. A ten-minute capability
inventory would have saved ninety minutes.

**Read the error the system returns before inferring a cause from the
symptom.** Every 401 carried a `WWW-Authenticate` header naming the exact
validation that failed. I asked for a token decode and container logs first and
got to the header third — and it said, in one line, `The audience '(null)' is
invalid`, which was the whole answer. The token was fine; the validator had
nothing to compare it against.

**Wait out eventual consistency instead of adapting to it.** Setting
`requestedAccessTokenVersion=2` took effect minutes later. In the gap I
reconfigured the Host to match the v1 tokens it was still receiving — and by
the time that revision was healthy, Entra had switched to v2 and the app was
wrong in the opposite direction. Two edits, one root cause, zero progress.
After a change with propagation delay, the correct move is to re-observe, not
to reconfigure around a transient state.

**Don't put an unverified diagnosis into a tool's output.** See below.

---

## What the hardest bug taught me

The hardest bug was not hard. Assigning an Entra app role to a service
principal failed, and I diagnosed it as a tenant permission a student account
wouldn't have — plausible, consistent with the symptom, and written into the
script as a three-paragraph warning explaining the fallback plan.

It was wrong. The same call succeeded when run by hand. The real cause was my
own request encoding: `az` on Windows is `az.bat`, and a JSON body with real
double quotes does not survive PowerShell → cmd intact.

Then I "fixed" the follow-up check by blaming a `|` in a JMESPath query being
eaten as a shell pipe. Also wrong. The actual bug was that I was reading
`/servicePrincipals/{id}/appRoleAssignedTo` — *who may call me* — when I wanted
`/appRoleAssignments` — *what roles I hold*. Three near-identical characters,
opposite directions, and an empty list that is indistinguishable from "not
assigned".

Three confident explanations of one symptom; the first and third wrong. What
made it dangerous wasn't being wrong — it was that I wrote the first
explanation into the script's own warning text, where a future reader would
have trusted it, taken the weaker single-identity fallback, and never
discovered the tenant was fine all along. **A guess recorded as a diagnosis
outlives the person who guessed.** The rewritten warning now prints the command
that reveals the real error and says explicitly not to assume a permission
problem until Graph says so.

The narrower lesson underneath: every failure in that script — the terminating
stderr, the mangled JSON, the truncated query — was one cause wearing three
costumes. Fixing symptoms one at a time made each fix look like progress.

---

## What I'm proudest of

**The deployment cannot succeed while the thing that justified it is missing.**

ADR-0003 accepted shipping without authentication *"until 2026-10-31, or
immediately on first deployment to any shared environment, whichever comes
first"* — on the explicit argument that there was no attacker because there was
no route. Shipping creates the route. So `02-deploy.ps1` ends by sending an
unauthenticated `POST /api/collections` and **throws if it gets anything but
401**, with the message *"Do not leave this deployment running."*

A green `/health` on an unauthenticated API would have been the worst possible
outcome today: it looks exactly like a successful ship. The check means the
ADR's expiry is enforced by the deploy, not by my remembering it.

Second, close behind: **authentication did not touch the domain.**
`Collection.RequireOwner` is byte-identical to yesterday. It still compares two
strings — only the source of one changed, from the request body to a validated
token's `oid` claim. All 34 domain and application tests were unmodified. The
endpoint layer absorbed the entire change, which is what the module boundaries
were for.

And the test that makes the rest mean anything: `Anonymous_requests_are_refused`
exists because a test authentication handler that always succeeds turns a suite
green while proving nothing. The handler returns `NoResult` without an actor
header specifically so that test *can* fail.

---

## Open, honestly

- **`--min-replicas 1`** keeps four outbox relays polling continuously on a
  student credit. Correct for a demo, wrong for a bill.
- **Two apps in one Container App environment** (`cae-7mo4cimyk4vnk`) shared
  with Day 5's `quotes-api-dev`. Expedient, not designed.
- **The SQL admin password** is a Container App secret; Entra-only auth for SQL
  would remove the last password in the system.
- **`.capstone-demo-secrets.json`** holds two client secrets outside the repo.
  Delete it when the demo is done.
- **This is a student subscription.** Credit expires, and the deployment stops
  with it. "Permanent" is not the right word for it.
