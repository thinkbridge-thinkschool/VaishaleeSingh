# Day 27 — Security pass

**Task.** Threat-model the capstone (STRIDE-lite), put the data tier behind
private endpoints, harden the OpenAPI surface (auth, versioning, input
limits), and run a basic pen test (OWASP ZAP baseline).

**Outcome.** One real, exploitable authorization bug found and fixed with
regression tests. The HTTP surface hardened on both origins. A pen test that
found a header the code claimed to send and did not. Private endpoints proved
impossible on this subscription, with the evidence. And one self-inflicted
outage, caused by a security fix, written up in full because it is the most
useful thing in the day.

---

## 1. The finding that mattered: broken object-level authorization

Three of the five `/api/collections` endpoints had no ownership check at all.

| Endpoint | Before | After |
|---|---|---|
| `GET /{id}` | any authenticated caller could read any collection | owner filtered **in the query**; 404 for others |
| `POST /{id}/items` | any caller could add a quote to anyone's collection | 403 |
| `DELETE /{id}/items/{quoteId}` | any caller could remove one | 403 |
| `DELETE /{id}` | already checked | unchanged |
| `GET /` | already scoped by owner | unchanged |

Ids are integers, so exploiting it is a `for` loop, not an attack.

**Why it happened**, which matters more than the fix. `can-edit-collections`
is a claim-based policy: it answers *may this caller edit collections*, which
the token knows. It cannot answer *may this caller edit **this** collection*,
because that lives in the loaded row. The two endpoints whose author was
thinking about ownership spelled the check out inline; the three who were not
never took a `ClaimsPrincipal`. **A rule that must hold on five endpoints and
is written on two is not a rule — it is a habit.**

**So the fix is not five checks.** The ownership filter moved *into the query*:

```csharp
.Where(c => c.Id == id && c.OwnerId == ownerId)
```

The row for another owner's collection never leaves the database, so no future
caller can forget to check. Defence by construction rather than by discipline.
The claim lookup became one helper that **throws** rather than returning null —
a null would compare unequal to every `OwnerId` and silently deny everyone,
which is a permissions bug hiding a real one.

**Read returns 404, write returns 403, and the difference is deliberate.** A
read is what an attacker uses to enumerate; answering "exists, not yours"
versus "does not exist" hands them a map of live ids. A write names an id the
caller already believes is theirs, so refusing it plainly is honest.

**Sixty integration tests passed the entire time this was live**, because every
one of them acts as a single user. `CollectionOwnershipTests` now covers all
four verbs cross-user plus list exclusion, **and a positive control** proving
the owner can still do everything — without it, a change that denied
*everybody* would leave every other test in the file green, and denying
everybody is an outage, not security.

---

## 2. Threat model

`Day27/docs/day27-threat-model.md` — six trust boundaries, STRIDE-lite, every
row either a measurement or a fix and labelled which. Nothing says "should be
fine"; that phrase is how the bug above survived nineteen days.

Boundaries: Browser→API, API→SQL, API→Service Bus→worker, API→Key Vault,
CI/CD→Azure, Operator→everything.

Notable measured results:

- **Diagnostics endpoints** — fourteen of them, several mutating (one can open
  the circuit breaker, i.e. take the app down). Gated by *registration*, not
  auth: in production the routes do not exist. Verified on both environments,
  not assumed — `/api/diagnostics/stats` returns 404 on each.
- **SQL firewall** — carried `AllowAllWindowsAzureIps` (which admits *every*
  Azure tenant, not just ours) plus three stale operator home addresses. All
  removed. See §5 for what that cost.
- **Key Vault, Service Bus, ACR, SQL auth** — already identity-only from
  Day 25; no credential exists to steal.

---

## 3. Private endpoints: measured, not attempted

Not possible on this subscription, and the evidence is in the model:

- The Container Apps environment is **Consumption-only**, `vnetConfiguration:
  null`.
- VNet integration is fixed **at environment creation** and cannot be added.
- The subscription permits exactly one environment
  (`MaxNumberOfGlobalEnvironmentsInSubExceeded`), which dev and prod share.

Accepted risk, stated: SQL is reachable over the public network path, defended
by Entra-only authentication and one IP rule. **That makes
`azureADOnlyAuthentication` a single point of prevention** — one setting change
removes the wall and nothing would notice. An alert on that property changing
is the highest-value open item in this document.

---

## 4. Hardening the surface

| Change | Detail |
|---|---|
| Security headers | CSP, nosniff, frame-deny, referrer, permissions policy, HSTS — on **both** origins |
| Rate limiting | 10/min per client on `/auth`, 300/min global, `/health` and `/ready` exempt |
| Request limits | 64 KB body, 32 KB headers, refused at the transport layer |
| Versioning | every group mapped under `/api/v1` **alongside** existing `/api` paths |

**Two of these were wrong in ways the code did not show.**

**The headers were on the wrong origin.** They were added to QuotesApi, whose
responses are JSON — and a Content-Security-Policy on a JSON body governs no
document. The page that loads and runs the application is served by nginx from
`quotes-web`, and the browser never contacts the API directly (nginx
reverse-proxies `/api/` same-origin). "We added a CSP" was true and useless
until the same headers went into `nginx/security-headers.conf`.

They are included there **three times**, not once at server level, because
nginx does not merge `add_header` across levels: a location block declaring any
`add_header` inherits none from its parent. Two such blocks exist here, so a
server-level declaration would have covered everything **except** `index.html`
and every script chunk — silently, with the config loading cleanly.

**The rate limiter's client key was spoofable.** It partitions on the first
entry of `X-Forwarded-For`, documented as trustworthy because the ingress
overwrites it. Through nginx that was false: `$proxy_add_x_forwarded_for`
*appends* to whatever the client sent, so any caller could supply a fresh value
per request, land in a fresh bucket, and reduce the 10/min auth limit to
decoration on the exact path the SPA uses. nginx now sends `$remote_addr` — its
own observation, not the caller's claim. The code comment had predicted this
failure in the abstract; it was live in this deployment the whole time.

---

## 5. The security fix that took production down

Removing `AllowAllWindowsAzureIps` left one rule naming the Container Apps
environment's outbound address, `20.203.119.48`, recorded as though it were a
property of the environment. Hours later every container failed to start:

```
Cannot open server 'sql-quotes-…' requested by the login.
Client with IP address '20.203.116.141' is not allowed to access the server.
Number:40615
```

A Consumption-only environment does not pin its egress address. Prod carried
the identical stale rule and would have failed the same way the moment it woke.

**What it looked like while it happened**, because that is the transferable
part: the deployment was green. The revision sat in `Activating` with
`ContainerBackOff ×21`. The site answered `stream timeout`. SQL 40615 reads
like a network problem. The truth appeared in exactly one place — the
container's own stdout.

**Fixed by reconciliation, not a better constant.**
`Day27/scripts/01-reconcile-sql-firewall.ps1` reads the apps' current outbound
addresses and makes the firewall match, pruning what no longer applies. Not in
the Bicep: the value only exists after the apps do, and it can change while
nothing is deploying. Not in CI: the pipeline holds no role on the SQL server,
and widening that to save one command is the wrong trade.

**The rule:** a security change that removes a permission is a change that can
take the system down. Verify it by watching the thing that used that permission
still work — not by observing that the deployment went green.

---

## 6. Pen test — OWASP ZAP baseline

Run against **dev** only; prod's error-rate alert is live and a scan would fire
it. Both origins scanned. Reports in `Day27/verification/`.

| Target | FAIL | WARN | PASS |
|---|---|---|---|
| `quotes-web-dev` | 0 | 6 | 61 |
| `quotes-api-dev` (`/health`) | 0 | 4 | 63 |

An earlier web run is **discarded rather than reported**: it executed while the
container was running an image the pipeline never built, and its results cannot
be attributed. A report whose target cannot be identified is not evidence.

Both scans needed the app warmed first — `minReplicas: 0` means the first
request pays a cold start and ZAP's spider times out on it, reporting `Read
timed out`, which looks like an unreachable host rather than a sleeping one.

### Every finding, with a verdict

| # | Finding | Where | Verdict |
|---|---|---|---|
| 10035 | Strict-Transport-Security not set | API | **Fixed** — see below |
| 10036 | Server leaks version information | web | **Fixed.** `server_tokens off`. nginx announced its patch level on every response, which tells an attacker which CVEs to try first. |
| 90004 | Cross-Origin-Resource-Policy missing | API | **Fixed.** `same-origin`. Nothing legitimate embeds this API cross-origin. |
| 90004 | Cross-Origin-Embedder-Policy missing | web | **Partly fixed, partly refused.** COOP and CORP added. COEP `require-corp` deliberately not set: it requires every subresource to opt in, buys nothing without SharedArrayBuffer, and fails by silently not loading resources. Adding a header because a scanner named it, at the risk of blanking the app, is how a security pass makes a site worse. |
| 10015 | Re-examine cache-control | both | **Accepted.** `index.html` is `no-cache` on purpose — it names the current chunk hashes, and caching it causes a 404 storm after every deploy. It holds no user data. |
| 10049 | Storable and cacheable content | web | **Accepted.** Fingerprinted assets served `immutable` by design. |
| 10049 | Non-storable content | API | **False positive in context.** An API declining to be cached is correct. |
| 10055 | CSP `style-src unsafe-inline` | web | **Accepted, cost stated.** Angular injects component styles at runtime; removing it blanks the app. A real weakening, confined to styles — `script-src` has no such allowance. Removing it is a front-end change (nonces or extracted styles), not a header change. |
| 10109 | Modern web application | web | **Informational.** ZAP noting the site is a SPA. |

### The one that justified running a scanner

```
WARN-NEW: Strict-Transport-Security Header Not Set [10035]
```

The middleware set HSTS inside `if (context.Request.IsHttps)`. Container Apps
terminates TLS at its ingress and forwards plain HTTP, so `IsHttps` is **false
on every production request** and the header never shipped. The code read
correctly and did nothing.

**No test could have caught it.** In-process integration tests speak to Kestrel
directly, where the request is whatever the test says it is. It took a scanner
talking to the deployed thing over the real network. That is the argument for
running a pen test at all, and it is worth more than the finding.

Now reads `X-Forwarded-Proto`. Verified directly against the API, not through
the proxy:

```
$ curl -sD - https://quotes-api-dev…/health
strict-transport-security: max-age=31536000; includeSubDomains
cross-origin-resource-policy: same-origin
content-security-policy: default-src 'self'; script-src 'self'; …
x-content-type-options: nosniff        x-frame-options: DENY
```

---

## 7. CSP verified in a browser

`Day27/verification/day27-csp-verification.md`, with screenshots.

Measured with `cache: 'no-store'` on the deployed revision: CSP, nosniff,
`X-Frame-Options`, `Referrer-Policy` and HSTS present on `/index.html`,
`/sign-in`, and the `.js` and `.css` served by a different location block.

**Enforcement tested, not assumed.** An inline `<script>` injected into the
live document:

```
result: BLOCKED by script-src-elem
script executed: false
```

The SPA renders normally; 15 application requests, all `200`; every console
message came from a browser extension, none from the application.

**One result deliberately not claimed.** The probe also reported `eval
ALLOWED`. That is not evidence about this policy — it ran in an extension's
isolated world, where the page's CSP does not apply. Reporting it would have
been a fabricated finding.

**And one false pass, recorded.** An earlier `BLOCKED` result was taken as
proof while the container was running an image the pipeline never built. A
`BLOCKED` from a document loaded at an unknown time proves nothing. Every
measurement after that was taken fresh, against a named revision.

---

## 8. CI/CD fixes found along the way

**`prod-deploy` was listening for a branch that does not exist.** The trigger
named `production`; this repository has `main` and `dev`. It had worked on
`main` (runs #1–#3) until a Day 24 commit changed the trigger, after which
three merges to `main` deployed nothing — **and nothing went red.** A workflow
that never runs and one that always passes look identical in the Actions tab.

**The prod preflight asked a question the pipeline was not allowed to answer.**
It called `az group exists` and reported `Resource group thinkschool-prod-rg
does not exist` about a group an operator had modified minutes earlier. That
call needs read *on the group*; this pipeline holds roles on *resources* —
registry and container apps — deliberately, since Day 25. ARM returns 404 for
what a caller cannot read, `az` turns that into `false`, and the step reported
an absence that was really a permission it was never meant to have. It now asks
about the registry and the container app it is about to update: answerable with
the roles it holds, and a stricter question, since a resource group can exist
while containing nothing.

---

## 9. Verification

| Gate | Result |
|---|---|
| `dotnet build` | clean |
| Unit tests | 192 / 192 |
| Integration tests | 66 / 66 |
| CSP in a browser | enforces; SPA unaffected |
| ZAP baseline, web | 0 FAIL / 6 WARN / 61 PASS, every WARN judged |
| ZAP baseline, API | 0 FAIL / 4 WARN / 63 PASS, every WARN judged |
| dev deployed | `9a57a6e14264`, headers measured live |
| prod deployed | `9a57a6e14264` — the same image dev tested, promoted not rebuilt |

---

## 10. Open, and honestly so

| Item | Why |
|---|---|
| Alert on `azureADOnlyAuthentication` changing | Highest value item here. With no private endpoint, one setting is the wall, and nothing watches it. |
| Reconciling the SQL firewall automatically | The script exists; it is run by hand. The detector for a moved egress address is still "the app crash-loops". |
| `SQLitePCLRaw.lib.e_sqlite3` 2.1.11 — NU1903 | Transitive, and production uses SQL Server rather than the SQLite provider, so runtime exposure is low. A version bump needs a test run of its own. |
| `CustomJwt` and Entra both live | Twice the token-validation surface. Retiring `CustomJwt` means migrating the SPA to MSAL and reworking sign-in, refresh and the `Users` table — its own day. |
| Promotion script leaves its SQL firewall rule behind | Known, small, not yet written. |
| Per-account login lockout | Deliberate non-goal: it is its own denial of service — lock a user out by guessing their username. Per-IP limiting is the trade taken, and it is a speed bump, not a wall. |
