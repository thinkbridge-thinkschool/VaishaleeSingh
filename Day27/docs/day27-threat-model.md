# Day 27 — Threat model (STRIDE-lite)

Six questions per trust boundary. The method is worth one line before the
tables: STRIDE is not a checklist to complete, it is six prompts that make you
look at each boundary from the attacker's side rather than the designer's.

**Every row below is either a measurement or a fix, and says which.** Nothing
here is "should be fine" — that phrase is how the one real bug in this model
survived nineteen days of work and a passing test suite.

## The system

```
Browser (SPA)  ──HTTPS──▶  quotes-api (Container Apps, public ingress)
                                │
                   managed identity, Entra-only
                                ├──▶ Azure SQL          (one firewall rule)
                                ├──▶ Service Bus topic  ──▶ worker (same process)
                                ├──▶ Key Vault          (jwt-secret)
                                └──▶ App Insights

GitHub Actions ──OIDC──▶ Azure   (per-environment roles, no stored secret)
```

## 1. Browser → API

| STRIDE | Threat | Status |
|---|---|---|
| **S** | Steal or forge a token and act as another user | **Mitigated.** JWT signed with a key that lives only in Key Vault; `ValidateOnStart` + minimum length means the app refuses to boot without it. Entra tokens validated against the tenant that owns the subscription (Day 25 fixed the audience, which was a scope and would have failed every real token). |
| **S/D** | Guess passwords against `/api/auth/login` without limit | **Fixed today.** No rate limit existed. `/api/auth/*` now 10 requests/minute per address, everything else 300/minute, `/health` and `/ready` exempt so a throttled probe cannot take a revision down. Per-IP is a speed bump, not a wall — stated in the code. |
| **T** | Injected script runs in a user's session | **Fixed today.** No security headers existed. CSP with `script-src 'self'` (no `unsafe-inline` for scripts), plus nosniff, frame-deny, no-referrer, Permissions-Policy, and HSTS over HTTPS only. |
| **I** | Error responses leak internals | **Mitigated.** `ExceptionHandlingMiddleware` turns everything into ProblemDetails; no stack traces leave the process. |
| **D** | Large or deeply nested request bodies | **Fixed today.** Field validation existed (author 200, text 1000, name 3..80) but ran *after* the body was read and parsed, with Kestrel's 30 MB default behind it. Now 64 KB body / 32 KB headers, refused at the transport layer. |
| **E** | **A user reads and modifies another user's collections** | **Fixed today — this was real and exploitable.** See below. |

### The one that mattered

Three of the five `/api/collections` endpoints had no ownership check at all:

| Endpoint | Before | After |
|---|---|---|
| `GET /{id}` | any authenticated caller could read any collection | owner filtered **in the query** |
| `POST /{id}/items` | any caller could add a quote to anyone's collection | 403 |
| `DELETE /{id}/items/{quoteId}` | any caller could remove one | 403 |
| `DELETE /{id}` | already checked | unchanged |
| `GET /` | already scoped by owner | unchanged |

Integer ids make this a `for` loop, not an attack.

**Why it happened, which matters more than the fix.** `can-edit-collections` is
a claim-based policy: it answers *may this caller edit collections*, which the
token knows. It cannot answer *may this caller edit **this** collection*,
because that lives in the loaded row. The two endpoints whose author was
thinking about ownership spelled the check out inline; the three who were not
simply did not take a `ClaimsPrincipal`. A rule that must hold on five
endpoints and is written on two is not a rule — it is a habit.

**So the fix is not five checks.** The claim lookup became one helper that
throws rather than returning null (a null would compare unequal to every
`OwnerId` and silently deny everything — a permissions bug hiding a real one),
and the read path's ownership moved **into the query**: `GetDetailAsync` now
takes `ownerId` and puts it in the `WHERE`. The row for someone else's
collection never leaves the database, so no future caller can forget to check.
Defence by construction rather than by discipline.

**And the suite was green the whole time.** Sixty integration tests passed
while this was live, because every one of them acts as a single user.
`CollectionOwnershipTests` now covers all five endpoints cross-user, plus a
positive control proving the owner can still do everything — without it, a
change that denied *everybody* would leave every other test in the file green,
and denying everybody is an outage rather than security.

## 2. API → SQL

| STRIDE | Threat | Status |
|---|---|---|
| **S** | Connect with a stolen password | **Mitigated by design.** `azureADOnlyAuthentication` — no SQL login exists to hold a password (Day 25). |
| **I** | Reach the server from the internet | **Improved today, not eliminated.** The server carried `AllowAllWindowsAzureIps` (0.0.0.0–0.0.0.0), whose name misleads: it admits **every Azure tenant's** resources, not just ours. Plus three stale `QueryEditorClientIPAddress_*` rules — operator home addresses left permanently open. All removed; both servers now have exactly one rule, the Container Apps environment's outbound address — **which is not a fixed value, and treating it as one caused an outage the same day. See "The fix that broke production" below.** |
| **I** | Private endpoint instead of a firewall | **Not possible here, measured not assumed.** The environment is Consumption-only with `vnetConfiguration: null`; VNet integration is fixed at environment creation and cannot be added, and the subscription permits exactly one environment (`MaxNumberOfGlobalEnvironmentsInSubExceeded`, Day 24). Accepted risk: SQL is reachable over the public network path, defended by Entra-only auth and one IP rule. |
| **T** | SQL injection | **Mitigated.** EF Core parameterises; the one raw T-SQL path (`create-sql-user.ps1`) uses `QUOTENAME` rather than concatenation. |
| **E** | The app's identity can do more than it needs | **Mitigated.** Contained user with `db_datareader`/`db_datawriter`/`db_ddladmin` only — no server-level role. |

**One prevention, one point of failure.** With no private endpoint, Entra-only
auth is the wall. It is a strong wall — but a single settings change
(`azureADOnlyAuthentication` to false, then create a login) removes it, and
nothing would notice. **Recommendation not yet implemented:** an Azure Monitor
alert on that property changing. When prevention rests on one setting, that
setting needs watching.

## 3. API → Service Bus → worker

| STRIDE | Threat | Status |
|---|---|---|
| **S** | Publish with a SAS connection string | **Mitigated by design.** `disableLocalAuth` — the namespace rejects SAS outright (Day 25). |
| **T** | Tamper with a message in flight | **Mitigated.** TLS to the namespace; managed identity both ends; Data Sender on the topic and Data Receiver per subscription, nothing wider. |
| **R** | A message processed with no record of it | **Mitigated.** `traceparent` travels as an application property and the consumer span is now exported (Day 26 fixed that — the span existed but belonged to no `ActivitySource`, so it was created and silently dropped). |
| **D** | Poison message loops forever | **Mitigated.** `MaxDeliveryCount` 5 then dead-letter; the consumer classifies poison versus transient explicitly rather than abandoning everything. |

## 4. API → Key Vault

| STRIDE | Threat | Status |
|---|---|---|
| **I** | The signing key appears in a log or a template | **Mitigated by design.** The vault is created empty; the key is written straight from the operator. `@secure()` was deliberately *not* used, because its promise is narrower than it reads — it hides a value from deployment logs while it still exists in the operator's shell, azd's `.env`, the CI runner and the ARM request body. Four copies of something that needs one. |
| **E** | The app can overwrite its own signing key | **Mitigated.** `Key Vault Secrets User`, not Officer. An app that can rewrite its signing key can lock out every user. |
| **D** | The vault name is held hostage after teardown | **Fixed during Day 24.** Purge protection was on with 90-day retention on an environment whose lifecycle includes teardown — a deleted vault would have held its deterministic name for a quarter of a year. Now off with 7-day retention, and the reasoning is recorded in the parameter file. |

## 5. CI/CD → Azure

| STRIDE | Threat | Status |
|---|---|---|
| **S** | A leaked deploy credential | **Mitigated by design.** OIDC federated credentials, no stored secret to leak or rotate. Subjects registered per ref, in both the documented and this org's immutable spelling. |
| **E** | The dev pipeline deploys production | **Mitigated.** `dev` builds and deploys dev; `main` promotes to prod. Separate OIDC subjects, and roles scoped per environment's resources rather than once at the subscription — with a subscription-wide grant the two branches, the GitHub Environment and its required reviewer would all be procedure, and procedure gets bypassed. |
| **E** | The pipeline can do more to the registry than push | **Reviewed today.** `az acr import` needs a control-plane action `AcrPush` does not grant. Granted through a custom role holding exactly `registries/importImage/action` and `registries/read`, rather than Contributor — which would also let the pipeline delete the registry and re-enable the admin account Day 25 turned off. |
| **T** | Something other than the tested artefact reaches prod | **Mitigated.** Prod never compiles; `az acr import` copies the manifest dev already built and ran. |

## 6. Operator → everything

| STRIDE | Threat | Status |
|---|---|---|
| **I** | Diagnostics endpoints exposed in production | **Verified today, not assumed.** Fourteen endpoints, several of them mutating (`/seed`, `/author-index`, `/resilience/isolate` — that last one can open the circuit breaker, i.e. take the app down). They are gated by *registration*, not auth: `MapDiagnosticsEndpoints` maps nothing unless the environment is Development or `Diagnostics:Enabled` is true, so in production the routes do not exist. Stronger than an auth check, because no credential can reach them. **Measured:** both environments report `ASPNETCORE_ENVIRONMENT=Production`, neither sets the flag, and `/api/diagnostics/stats` returns 404 on both. |
| **I** | Operator IP rules outliving their purpose | **Fixed today.** Four such rules removed. The promotion script adds one per run and does not remove it — see open items. |
| **E** | An operator's laptop is the SQL administrator | **Accepted.** `quotes-sql-admins` is an Entra group; membership is the control. A group is the right shape (auditable, revocable without touching the server). |

## The fix that broke production

The row above is a real improvement and it is also the most expensive mistake
in this document, so it is written out rather than quietly amended.

Removing `AllowAllWindowsAzureIps` left one rule naming `20.203.119.48`, read
off the environment and recorded as though it were a property of it. Hours
later every container failed to start:

```
Cannot open server 'sql-quotes-…' requested by the login.
Client with IP address '20.203.116.141' is not allowed to access the server.
Number:40615
```

The address had moved. A Consumption-only Container Apps environment does not
pin its egress address, and nothing in this project's notes said otherwise —
nothing said it did, either, which is exactly the gap: an unexamined
assumption was written down as a fact and then depended on.

**What it looked like while it was happening**, because the shape of the
failure matters more than the cause: the deployment was green. The revision
sat in `Activating` with `ContainerBackOff ×21`. The site answered `stream
timeout`. SQL 40615 reads like a network problem. Nothing anywhere said
"a firewall rule is stale", and the only place the truth appeared was the
container's own stdout.

**Prod carried the identical stale rule** and would have failed the same way
the moment it woke — which, with `minReplicas: 0`, would have been the next
time anyone opened it.

**The fix is reconciliation, not a better constant.** `Day27/scripts/01-reconcile-sql-firewall.ps1`
reads the apps' current outbound addresses and makes the firewall match,
pruning what no longer applies. It is not in the Bicep, because the value only
exists after the apps do and can change while nothing is deploying. It is not
in CI, because the pipeline holds no role on the SQL server and widening that
to save one command is the wrong trade.

**The lesson, stated plainly:** a security change that removes a permission
should be treated as a change that can take the system down, and verified by
watching the thing that used that permission actually work — not by observing
that the deployment went green.

## Supply chain

`SQLitePCLRaw.lib.e_sqlite3` 2.1.11 carries a known high-severity advisory
(NU1903, GHSA-2m69-gcr7-jv3q) and warns on every build. It reaches production
transitively through the SQLite provider, which production does not use — SQL
Server is the deployed provider — so runtime exposure is low, but a
known-vulnerable package is in the tree and the warning has been ignored on
every build for weeks. **Open.**

## Open items, honestly listed

| Item | Why not done today |
|---|---|
| Reconciling the SQL firewall on a schedule | The script exists and is run by hand. Nothing yet notices when the egress address moves — the app crash-looping is still the detector, and it should not be. |
| Security headers were first shipped to the wrong origin | Corrected the same day: they were added to the API, whose responses are JSON, when the document that executes script is served by nginx. Both origins now set them. Recorded because "we added CSP" was true and useless for most of that day. |
| Alert on `azureADOnlyAuthentication` changing | Identified while writing this; not yet built. It is the detection that matters most, because prevention rests on one setting. |
| Private endpoints | Not possible on this subscription. Measured, evidenced above. |
| Two auth schemes live at once (`CustomJwt` + Entra) | Twice the token-validation surface. Retiring `CustomJwt` means migrating the SPA to MSAL and reworking sign-in, refresh tokens and the `Users` table — its own day, and a decision rather than an oversight (Day 25 said the same). |
| `SQLitePCLRaw` bump | Needs a test run to see what a version change breaks. |
| Promotion script leaves its SQL firewall rule behind | Correct behaviour is to remove it when the deploy finishes. Known, small, not yet written. |
| Per-account login lockout | Deliberate non-goal: it introduces its own denial of service — lock a user out by guessing at their username. Per-IP limiting is the trade taken. |
