# Day 27 — Security pass: the plan

**Task.** Threat-model the capstone (STRIDE-lite), put the data tier behind
private endpoints, harden the OpenAPI surface (auth, versioning, input limits),
and run a basic pen test (OWASP ZAP baseline).

This is the first day whose changes are mostly in **application code** rather
than infrastructure. Days 24–26 could break a deployment; this one can break
the app, the SPA and 135 tests. The plan is therefore built around not
breaking things, and says so at every step.

## What is already true, before doing anything

A security pass that starts from zero would waste the week that came before it.
Most of what a threat model asks about is already answered:

| Already in place | Since | What it closes |
|---|---|---|
| Managed identity for SQL, Service Bus, Key Vault, App Insights | Day 25 | No credential to steal from config |
| Entra-only SQL (`azureADOnlyAuthentication`) | Day 25 | No SQL password exists to guess |
| Service Bus `disableLocalAuth` | Day 25 | SAS connection strings rejected |
| ACR admin user disabled | Day 25 | Registry is identity-only |
| App Insights `DisableLocalAuth` | Day 25 | Instrumentation key is an address, not a credential |
| JWT signing key in Key Vault, never in a template | Day 25 | Key never enters a deployment log |
| Least-privilege role assignments, per resource | Days 25–26 | A compromised identity reaches little |
| Distributed tracing with correlation ids | Day 26 | Repudiation: who did what is answerable |
| Error-rate alert | Day 26 | An attack in progress is visible |
| CORS with one named policy | Day 13 | Browser origins are restricted |

The threat model's job is half to make that legible and half to find what is
left. What is left is listed in step 1.

## Ground rules, so nothing breaks

1. **One concern per commit.** Headers, rate limiting, versioning and the ZAP
   fixes are separate commits. A bisect should land on one idea.
2. **`dotnet test` after every commit**, locally, before pushing. CI is a gate,
   not a substitute — and this repo has 135 tests precisely so they can be run.
3. **Additive before subtractive.** New routes are added alongside the old ones
   and the old ones removed only once the SPA and the tests are on the new
   ones. Nothing is renamed in place.
4. **Dev first, always.** Every change goes to `dev`, is verified against the
   dev environment, and only then merges to `main`. The ZAP scan runs against
   dev — never against prod, whose error-rate alert is live and would fire.
5. **A finding that cannot be fixed is written down, not hidden.** Day 24 has
   several of these and they are the most useful paragraphs in it.

## Step 0 — Measure the private-endpoint constraint before designing for it

Private endpoints need the API to sit inside a VNet. Container Apps VNet
integration is fixed **when the environment is created** and cannot be added
afterwards — and this subscription permits exactly one Container Apps
environment, which dev and prod already share
(`MaxNumberOfGlobalEnvironmentsInSubExceeded`, Day 24).

So the honest first question is whether step 4 is buildable at all here.

```powershell
# Can a second environment exist? (Day 24 says no; confirm rather than assume.)
az rest --method get --url "https://management.azure.com/subscriptions/85567e22-432e-4648-aa68-ba2714167694/providers/Microsoft.App/locations/uaenorth/usages?api-version=2024-03-01" -o table

# Is the existing environment VNet-integrated?
az containerapp env show -n cae-7mo4cimyk4vnk -g thinkschool-dev-rg --query "properties.vnetConfiguration" -o json
```

**If it cannot be built**, the deliverable is still real: write the Bicep,
prove it with `what-if`, and record the constraint with the error as evidence.
That is a stronger answer than a private endpoint nobody can reach.

**Interim hardening that IS available either way** — and worth doing regardless:
tighten the SQL firewall to remove `AllowAllWindowsAzureIps` (it permits every
Azure tenant's IPs, not just yours) and rely on the Container Apps environment's
outbound addresses instead.

## Step 1 — The threat model (STRIDE-lite)

One table per trust boundary, six questions each. Boundaries:

1. Browser → API (public internet)
2. API → SQL
3. API → Service Bus → worker
4. API → Key Vault
5. CI/CD → Azure
6. Operator → everything

Gaps I expect it to surface, listed now so the model can confirm or refute them
rather than being written to fit:

| Gap | STRIDE | Fixed in step |
|---|---|---|
| No rate limit on `/api/auth/login` — passwords can be guessed indefinitely | S, D | 2 |
| No security headers (CSP, HSTS, X-Content-Type-Options) | T, I | 2 |
| No request body size limit | D | 2 |
| SQL `publicNetworkAccess = Enabled` | I | 0 / 4 |
| `AllowAllWindowsAzureIps` firewall rule | I | 0 |
| Two auth schemes live at once (`CustomJwt` + Entra) — twice the surface | S, E | documented, not fixed |
| Prod log ingestion uncapped — a log flood is a cost attack | D | 2 (cheap) |
| No API versioning — a breaking change is an outage | — | 3 |

**Deliverable:** `Day27/docs/day27-threat-model.md`, with a mitigation named for
every row, including "accepted, because…" where that is the honest answer.

## Step 2 — Quick wins (one commit each)

These are cheap, low-risk, and they are exactly what ZAP will look for — so
they come before the scan, and the scan is run twice to show the difference.

**2a. Security headers middleware.** A small `SecurityHeadersMiddleware`:
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
`Referrer-Policy: no-referrer`, `Strict-Transport-Security` (HTTPS only), and a
`Content-Security-Policy`. CSP is the one that can break the SPA — it is
written against what `wwwroot` actually loads, and tested by opening the app,
not by assuming.

**2b. Rate limiting.** Built into .NET (`Microsoft.AspNetCore.RateLimiting`), no
package needed. A strict fixed window on `/api/auth/*` (a handful of attempts
per minute per IP) and a looser global limit. Returns 429 with `Retry-After`.
Risk: too strict a limit breaks the SPA or the Day 26 telemetry probe, which
makes 25 writes in a loop — the limits are chosen with that probe in mind.

**2c. Request size limits.** Max body size, and `[MaxLength]` on the string
properties that reach the database. `MaxPageSize` already exists and is a good
model for the rest.

**2d. Cap prod log ingestion.** `logDailyQuotaGb` is `-1` in prod. One
parameter. A bug that logs in a loop currently has no ceiling, and this project
has already had one.

## Step 3 — Auth audit and versioning

**3a. Auth audit.** Walk every `MapGet`/`MapPost`/`MapPut`/`MapDelete` and
record whether it requires authorization and whether that is deliberate. The
output is a table in the submission: endpoint, auth, why. Anything anonymous
that should not be gets `.RequireAuthorization()`. Expect `/health`, `/ready`,
`/api/auth/login`, `/api/auth/register` to be legitimately anonymous.

**3b. Versioning, additively.** Mount the existing endpoint groups under
`/api/v1/...` **in addition to** the current `/api/...` paths, so nothing that
exists today stops working. The SPA and the probe scripts move to `/v1` in a
follow-up commit; the unversioned routes stay as deprecated aliases.

This is deliberately not the `Asp.Versioning` package: route groups do what the
exercise asks with no new dependency and no new failure mode.

**3c. An OpenAPI document — a decision, not a default.** There is none today.
Adding Swashbuckle only to then hide it in prod is theatre. Adding
`Microsoft.AspNetCore.OpenApi` and serving the document **in dev only** is
genuinely useful: it makes the surface reviewable and gives ZAP a map. Worth
doing; worth doing on purpose.

## Step 4 — Private endpoints, or the documented reason there are none

Driven by step 0. If buildable: private endpoints for SQL and Service Bus, both
`publicNetworkAccess = Disabled`, private DNS zones, and the environment
VNet-integrated. If not: the Bicep plus the `what-if` output plus the error,
and the interim firewall tightening from step 0.

## Step 5 — OWASP ZAP baseline, twice

```powershell
# Before (optional but much better evidence), and after
docker run --rm -v ${PWD}/Day27/verification:/zap/wrk/:rw `
  ghcr.io/zaproxy/zaproxy:stable zap-baseline.py `
  -t https://quotes-api-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io `
  -r zap-report.html -I
```

`-I` means "do not fail the build on warnings" — the report is the deliverable,
not a pass/fail gate. Run against **dev**.

Expect the before-run to flag the missing headers from step 2a. That is the
point of running it twice: the report becomes evidence that the fixes did
something, rather than a list of things that were always fine.

Each finding gets one of three verdicts: fixed, accepted with a reason, or
false positive with a reason. A ZAP report pasted without verdicts is not a pen
test result.

## Verification gates

| After | Gate |
|---|---|
| Every commit | `dotnet test Day7/piece2/Quotes.Tests.Unit` and `…Quotes.Tests.Integration` |
| Headers | Open the SPA in a browser — CSP breaks front ends silently |
| Rate limiting | Run `Day26/scripts/02-verify-telemetry.ps1`; its 25-write loop must still pass |
| Versioning | Both `/api/quotes?page=1&size=10` and `/api/v1/quotes?page=1&size=10` return 200 |
| Deploy to dev | `/health` returns Healthy |
| Before merging to main | dev green, and prod's own `/health` still Healthy afterwards |

## Rollback

Every step is one commit on `dev`. If a change breaks the app, `git revert`
that commit and push — the dev pipeline rebuilds and rolls back within minutes.
Nothing in this plan touches prod until dev is verified, and prod deploys are
promotions of an image dev has already run.

## What this day will produce

- `Day27/docs/day27-threat-model.md`
- `Day27/docs/day27-submission.md`
- `Day27/verification/zap-report-before.html`, `zap-report-after.html`
- Code: security headers, rate limiting, input limits, auth audit, `/api/v1`
- Infra: SQL firewall tightening, prod log cap, and either private endpoints or
  the evidenced reason there are none
