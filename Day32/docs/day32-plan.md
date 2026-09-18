# Day 32 — Ship live, demo, postmortem

**Branch:** `day32-ship-and-postmortem`
**Date:** 2026-09-18
**Decision taken:** full authentication, permanent public deployment, Azure
Container Apps + Azure SQL serverless, demo via `happy-path.ps1` against the
live environment.

---

## Why authentication is not optional today

ADR-0003 accepts the missing authentication *"until 2026-10-31, or immediately
on first deployment to any shared environment, whichever comes first."* The
justification it rests on is that there is no attacker because there is no
route. Deploying creates the route, so the acceptance ends the moment we ship.

On a public URL, without auth: any caller who knows a collection id and an
owner id — both returned in ordinary responses — can act as that owner, and any
caller can approve a review under any reviewer's name. `Review` exists to answer
*who decided this*; it would be recording whatever the caller typed.

**So the order is: auth first, deploy second.** Shipping first and adding auth
after would mean a window where the audit trail is forgeable, and that window
has no honest length.

---

## The design decision that keeps this contained

**The domain keeps taking `actorId` as a string.** ADR-0003 already argued for
this and it is what stops the change from spreading:

- The endpoint reads the caller's `oid` claim from the validated token and
  passes it to the aggregate as `actorId`.
- `Collection.RequireOwner` is unchanged. It still compares two strings — but
  now only one of them comes from the caller, and it came from a signed token.
- All 34 domain and application tests are untouched, because the domain never
  learns that authentication exists.

What changes: ~12 endpoint signatures (the actor fields leave the request
bodies), the 14 API tests, and `happy-path.ps1`.

**Two identities are required, not one.** A demo where the same principal owns
the collection and approves the review proves nothing about the ownership
checks. Two app registrations with client credentials give two distinct `oid`
values and make the guards real.

---

## Phases

Azure provisioning is slow and independent of the code, so it runs first and in
parallel rather than after.

### Phase 0 — Verify nothing is already broken (15 min)

| Step | Must be true before continuing |
|---|---|
| Day 31 CI run | **Green.** Never confirmed. If the coverage gate is red, today starts by fixing yesterday. |
| `git status` | Clean on `day31-polish-tests-perf-security`, everything pushed |
| `dotnet test` | 72 passing locally |
| New branch | `day32-ship-and-postmortem` off the current branch |

Nothing else starts until these four are true.

### Phase 1 — Azure provisioning (parallel with Phase 2)

Driven in the portal. Resource group `rg-quotes-capstone` (or existing).

1. **Azure SQL** — serverless General Purpose, auto-pause 1 hour. Admin password
   generated in the portal, never written to the repo or pasted into chat.
   Firewall: allow Azure services + the developer IP for migrations.
2. **Container Registry** — Basic tier, admin user disabled (Container Apps pulls
   with a managed identity).
3. **Container Apps environment** + the app itself, external ingress on 8080.
4. **Two Entra app registrations** — `quotes-capstone-api` (exposes the scope the
   token is issued for) and two client apps, `curator-demo` and `reviewer-demo`,
   for the two demo identities.
5. **Managed identity RBAC** — the Container App's identity needs:
   - `Azure Service Bus Data Sender` + `Data Receiver` on the namespace
     (`disableLocalAuth = true`, so there is no connection-string fallback)
   - a contained database user on Azure SQL, if we go Entra-only for SQL

### Phase 2 — Authentication in code

1. `Microsoft.Identity.Web` on the Host; `AddAuthentication().AddMicrosoftIdentityWebApi(...)`.
2. `RequireAuthorization()` on every endpoint except `/health`.
3. A single helper that pulls `oid` from `ClaimsPrincipal` and fails closed —
   **no fallback to a body field.** A fallback would leave the old hole open and
   make it look closed, which is worse.
4. Actor fields removed from every request record.
5. `CapstoneApiFactory` gets a test authentication handler so the 14 API tests
   run with a synthetic principal. **This is the riskiest step** — the test host
   must not accidentally authorise everything, or the tests keep passing while
   proving nothing.
6. Add a test that an **unauthenticated** request gets 401 and a request for
   someone else's collection still gets refused. Without the first, nothing
   proves the middleware is wired at all.

**Gate: 72 + new tests green locally before anything is containerised.**

### Phase 3 — Containerise

Multi-stage `Dockerfile`, non-root user, `ASPNETCORE_HTTP_PORTS=8080`. Build and
push to ACR. Verify the image runs locally against the local SQL container
before it ever goes near Azure.

### Phase 4 — Deploy and migrate

1. Migrations applied against Azure SQL from the dev machine (the Host does not
   migrate on startup — that is deliberate and stays that way).
2. Container App revision deployed with configuration for the SQL connection,
   the Service Bus namespace, and the Entra tenant/audience.
3. `/health` answers over HTTPS.
4. An unauthenticated call to a write endpoint returns **401** — checked
   explicitly, because this is the whole point of the day.

### Phase 5 — Demo

`happy-path.ps1` updated to acquire two tokens (curator, reviewer) and run
against the live URL. Transcript captured to `Day32/verification/`.

The script proves the full cross-module flow — submit → moderate → approve →
publish — across the real broker. A health check screenshot proves that the
process started.

### Phase 6 — Postmortem

One page: what I'd do differently, what the hardest bug taught me, what I'm
proudest of. Written last, from what actually happened today, not from what was
planned this morning.

---

## Cut line

**Phases 0, 2 and 6 or the day did not happen.** Authentication working with
green tests, and the postmortem, are the parts with lasting value. A deployment
that slips to tomorrow is a schedule problem; auth that is half-finished is a
security problem, and the postmortem is the only deliverable nobody else can
write later.

If Phase 4 fails late in the day, the honest move is to stop, record exactly
where it stopped, and not leave a half-configured public endpoint running
overnight.

---

## Risks, in the order they are likely to bite

1. **The test authentication handler authorising everything.** Mitigated by a
   test that asserts 401 for an anonymous request. If that test cannot fail, it
   is not a test.
2. **`oid` not present in the token.** Client-credential tokens carry the
   service principal's `oid`; user tokens carry the user's. If a token type
   without `oid` is used, the helper must fail closed rather than fall back.
3. **Service Bus RBAC propagation.** Role assignments take minutes to take
   effect. A consumer failing to authenticate immediately after deployment is
   usually this, not a code fault — wait before debugging.
4. **Azure SQL firewall.** Migrations run from the dev machine and will be
   refused until that IP is allowed.
5. **The 403 on `FinalizeArtifact`** in the other CI job is still unresolved and
   unrelated. Not today's problem; do not "fix" it by adding
   `continue-on-error`.

---

## Secrets rule for today

Every secret is generated in the portal or the shell and goes straight into
Container App configuration. Nothing is pasted into the chat, committed, or put
in a script default. Yesterday the local SA password reached the transcript
three times; that was a local throwaway. Today's are not.
