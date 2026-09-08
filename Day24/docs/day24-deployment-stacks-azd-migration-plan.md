# Day 24 — Deployment Stacks + azd, and the move to a new subscription

*Revision 3, 8 September 2026. Revisions 1 and 2 were written before the gates
were run and were wrong in three places — a same-tenant assumption, a region
that turned out to be forbidden, and a Static Web App that cannot exist here.
Each is corrected below with what actually happened, because in every case the
wrong answer is the instructive one.*

---

## 1. The facts, all measured

| | Value | How it was established |
|---|---|---|
| Subscription | `85567e22-432e-4648-aa68-ba2714167694` "Azure for Students" | `az account show` |
| Tenant | `8d46a076-d093-416d-a57b-8692cde13bf8` "Amity University" | same |
| Old subscription | `80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e`, tenant `f774bb68-…` | out of credit; still readable |
| Dev region | `uaenorth` | `01-region-fit.ps1` |
| Prod region | `koreacentral` | same |
| Subscription role | Owner | `az role assignment list` |
| Directory writes | **Permitted** | `az ad app create` succeeded |
| SQL admin (dev) | `a59d00a8-a829-49b4-83d1-952727eea166` / `vaishalee.singh@s.amity.edu` | `az ad signed-in-user show` |
| SQL admin (prod) | group `quotes-sql-admins`, `aad084c3-ebcf-495f-9c13-01415848fab4` | `az ad group create` |
| SQL SKU | `GP_S_Gen5_1` … `_80` offered in both regions | `az sql db list-editions` |
| Build state | 60/60 integration tests pass; Bicep and params compile clean | local run |

Nothing in Azure is being *moved*. Resources are re-created from
`Day7/piece2/infra`; only the database contents migrate.

---

## 2. Three things the gates got wrong, and what they cost

### 2.1 The tenant is different, but the directory did not have to move

A tenant is free and does not expire when a subscription's credit does. The old
directory `f774bb68-…` still exists and still owns the API's app registration
`91566dbd-d857-488a-858d-475e60b309b7`. Token validation is an HTTPS call to an
authority URL; it has no relationship to which tenant owns the subscription the
container runs in.

So the Entra story spans two tenants deliberately:

| Concern | Tenant |
|---|---|
| The API's Entra ID authentication scheme | **Old**, `f774bb68-…`, unchanged in `main.bicep` |
| SQL administrator | **Amity** — a server only accepts an admin from the tenant its subscription trusts |
| The app's managed identity | Amity, created by the template |
| GitHub Actions OIDC | Amity |

**Do not delete the old tenant or that app registration when decommissioning the
old subscription.** Deleting the directory breaks Entra authentication in the
new one.

Still open: `appsettings.json` declares `AzureAd:Audience` as
`api://quotes-api/access` while the app that ran in the old subscription used
the app-ID-URI form. Ask the directory rather than picking:

```powershell
az login --tenant f774bb68-0575-4cd2-9d4c-3b4e593d1110 --allow-no-subscriptions
az ad app show --id 91566dbd-d857-488a-858d-475e60b309b7 `
  --query "{uris:identifierUris, scopes:api.oauth2PermissionScopes[].value}"
```

### 2.2 The region probe produced a false pass

Revision 1 probed a region by creating and deleting an empty resource group.
`centralindia` passed. `centralindia` is not in this subscription's
allowed-locations policy at all.

Azure's built-in *Allowed locations* policy exempts
`Microsoft.Resources/subscriptions/resourceGroups` — where resource *groups* may
live is a separate policy. A resource group is a metadata record, so placing one
in a region whose resources are all refused is the design, not a loophole. The
probe measured the one thing the policy does not constrain, and a false pass is
worse than no answer: it was committed to a parameter file with a comment
claiming it had been verified.

The policy permits five regions. Membership turned out to be necessary and not
sufficient:

| | indonesiacentral | malaysiawest | indiasouthcentral | uaenorth | koreacentral |
|---|---|---|---|---|---|
| Container Apps | yes | yes | **no** | yes | yes |
| Log Analytics / App Insights | yes | yes | **no** | yes | yes |
| SQL, Service Bus, ACR, MI | yes | yes | yes | yes | yes |
| **Static Web App** | **no** | **no** | **no** | **no** | **no** |

`indiasouthcentral` is permitted and cannot host the application. Dev takes
`uaenorth` (lowest latency to India of the four viable, and mature); prod takes
`koreacentral`, deliberately a second region so two Container Apps Environments
never contend for one region's limit. Indonesia Central and Malaysia West were
avoided because the fit check reads provider/resourceType availability, which is
coarser than SKU availability — a new region can list Azure SQL and still not
offer `GP_S_Gen5`. That was then checked directly, and both chosen regions do.

### 2.3 A Static Web App cannot exist here, so the front end moved

`Microsoft.Web/staticSites` is offered in a handful of regions worldwide and
none of them are permitted. Phase D as originally written cannot happen.

The repository already contained the answer.
`Day13/quotes-web/src/environments/environment.production.ts` sets `apiBaseUrl`
to `''` and its own comment says that is correct "when the SPA is served from
the same host as the API — behind the same reverse proxy, ingress, or Azure
Container Apps ingress rule." So the Angular bundle is built into the API image
and served by the Container App. The front end needs no change at all: it has no
MSAL config, no client ID, no tenant, only that one setting.

**What this costs, and it is not nothing.** The Static Web App was also the
authentication boundary: the Container App had Container Apps authentication
enabled with the SWA as its linked identity provider, so unauthenticated traffic
never reached the container. The container's ingress is now external by design
and the API defends itself with its own authentication. That is a real reduction
in defence-in-depth, forced by a policy this project does not control. Also
gone: pull-request preview environments.

This belongs in the submission as a stated deviation, not a footnote.

---

## 3. What is already committed

Branch `day24-deployment-stacks`, five commits.

| Commit | What |
|---|---|
| `df6fec1` | Deployment stacks in `azure.yaml`; infra retargeted; `main.parameters.json` completed; workflow literals → repo variables |
| `2589d5c` | Measured gate values; corrected an overclaimed quota rationale |
| `c876c92` | Reverted the false region; replaced the bad probe with `01-region-fit.ps1` |
| `6e75ccd` | SPA served from the Container App; regions and prod admin group set |
| `a73ed27` | XML comments cannot contain two consecutive hyphens (`MSB4025`) |

The changes that matter, and why:

**`azure.yaml`** — `actionOnUnmanage: delete` for resources and resource groups,
so a resource dropped from the template is deleted rather than orphaned.
`denySettings.mode: denyDelete`, **not** `denyWriteAndDelete`: the stricter mode
would block `az containerapp update --image`, the packaging correction every
rollout still needs, and the workflow that performs it. `excludedPrincipals` is
commented out rather than stubbed with a placeholder GUID — ARM rejects an
unresolvable principal, so a stub would fail every deployment instead of only
the pipeline it protects. Fill it in at Phase E.

**`main.parameters.json`** — gained `resourceGroupName`, `apiContainerAppName`
and `createContainerAppsEnvironment`. Without them azd fell through to the
template's defaults, which name resources in the dead subscription, so `azd up`
would have built a different and broken environment than the parameter files
build. That closes the "the azd path is unverified" gap in `infra/README.md`.

**`main.dev.bicepparam`** — `createContainerAppsEnvironment = true`. Day 23
reused `thinkschool-env` in `thinkschool-rg` because the old subscription allowed
one environment per region; neither exists here, and left at `false` the
deployment fails on a dangling resource-group reference.

**`main.prod.bicepparam`** — Service Bus Premium → Standard, SQL provisioned →
serverless with auto-pause disabled, API ceiling 10×1.0 → 4×0.5 vCPU. The first
two together cost more per month than the whole student credit. Prod now differs
from dev in **shape** — dedicated environment, replica floor of 2, uncapped
telemetry, geo-redundant backups, group-owned database, more patient redelivery
— not in **tier**, and the file says so rather than reading as a careless copy.

**`Program.cs`** — serves the SPA from a gitignored `spa/` directory, not
`wwwroot` (which holds backend-owned assets this repo commits). The whole block
is conditional on the directory existing, because it does not during
`dotnet run`, in either test suite, or in `ci.yml` — an unconditional
`PhysicalFileProvider` on a missing directory throws at startup, turning "the
front end was not built" into "the API will not boot."

The fallback route excludes `api/` and `health/`, and that regex is
load-bearing. It replaces `staticwebapp.config.json`'s
`navigationFallback.exclude`, which the SWA workflow used to assert was present
because without it "API errors return index.html with a 200" — its own words. A
bare `MapFallbackToFile` answers an unmatched `/api/...` with the HTML shell and
a 200, so a client parsing JSON gets a syntax error instead of a 404 and a
status-only smoke test passes against a broken API.

---

## 4. Deploy dev

```powershell
az account set --subscription 85567e22-432e-4648-aa68-ba2714167694
cd C:\thinkschool\Day7\piece2

# A key from randomness. Not one derived from a name or an enrolment number,
# and not one that has ever been pasted into a chat window or a commit.
$env:JWT_SECRET = [Convert]::ToBase64String((1..48 | % { Get-Random -Max 256 }))
```

**C1 — Validate.** Stricter than what-if, and where a student subscription's
policy denials surface.

```powershell
az stack sub validate -n quotes-dev -l uaenorth `
  --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
  --action-on-unmanage deleteAll --deny-settings-mode denyDelete
```

**C2 — What-if.** Read three things, not the whole diff:

- **No `-` Delete lines.** New subscription; everything is `+ Create`.
- **The container app's image is the hello-world placeholder.** Correct on a
  first deployment. It must never revert to it later — proven at F7.
- **`Unsupported` diagnostics on the Service Bus and AcrPull role assignments.**
  Expected: what-if cannot evaluate an extension resource whose ID comes from a
  `reference()` resolved at deploy time.

```powershell
mkdir ..\..\Day24\verification -Force | Out-Null
az deployment sub what-if -l uaenorth -f infra/main.bicep -p infra/main.dev.bicepparam `
  | Tee-Object ..\..\Day24\verification\what-if-dev.txt
```

**C3 — Decide who owns the stack, then create it.**

With `alpha.deployment.stacks` on, `azd up` creates a stack of its own named
after the azd environment. Two stacks over the same resources conflict, and it
produces the most confusing failure in this whole plan.

- **Recommended — azd owns it.** Skip the command below; let `azd up` (C7)
  create the stack from `azure.yaml`. C1 still runs; it just creates nothing.
- **Alternative — the CLI owns it.** Run the command below, then use
  `azd deploy` and never `azd up`.

```powershell
az stack sub create -n quotes-dev -l uaenorth `
  --template-file infra/main.bicep --parameters infra/main.dev.bicepparam `
  --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
  --deny-settings-apply-to-child-scopes --description "QuotesApi dev - Day 24" --yes
```

**C4 — SQL firewall for your own machine.** The server's only other rule admits
Azure services — the container app and nobody else. The next step connects as a
person.

```powershell
$env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
# re-run C3; the parameter file reads that variable
```

**C5 — The contained database user. THIS STEP CANNOT MOVE.** An Entra-only
server gets the managed identity to the *server* and gives it no user *inside
the database*. Deploy the real image first and the app starts, fails with
`Login failed for user '<token-identified principal>'`, and sits permanently
unready — up, and never ready.

```powershell
./scripts/create-sql-user.ps1 `
  -SqlServerFqdn (az stack sub show -n quotes-dev --query "outputs.azurE_SQL_SERVER_FQDN.value" -o tsv) `
  -DatabaseName  (az stack sub show -n quotes-dev --query "outputs.azurE_SQL_DATABASE_NAME.value" -o tsv) `
  -IdentityName  (az stack sub show -n quotes-dev --query "outputs.servicE_QUOTES_API_IDENTITY_NAME.value" -o tsv)
```

**That casing is not a typo.** ARM camel-cases the first segment of every output
name, so `AZURE_SQL_SERVER_FQDN` returns as `azurE_SQL_SERVER_FQDN`. JMESPath is
case-sensitive; the name as written in the template returns null and the script
silently receives an empty parameter.

Run it as `vaishalee.singh@s.amity.edu`. Anyone else gets a permission error,
which is the Entra-only design working.

**C6 — Migrate the data.** From the old subscription, while it still answers:

```powershell
SqlPackage /Action:Export `
  /SourceConnectionString:"Server=tcp:<old-server>.database.windows.net,1433;Database=quotes;Authentication=Active Directory Interactive;" `
  /TargetFile:"C:\thinkschool-migration\quotes-pre-migration.bacpac"

SqlPackage /Action:Import `
  /SourceFile:"C:\thinkschool-migration\quotes-pre-migration.bacpac" `
  /TargetConnectionString:"Server=tcp:<new-server>.database.windows.net,1433;Database=quotes;Authentication=Active Directory Interactive;"
```

Row-count both sides **before** anything writes to the new database. A migration
that imported an empty schema looks identical to a successful one until the
first user complains. Keep the BACPAC outside the repository —
`C:\thinkschool-migration`, not `_staging`.

**C7 — Build and deploy.**

```powershell
azd env new thinkschool-dev
azd env set AZURE_SUBSCRIPTION_ID 85567e22-432e-4648-aa68-ba2714167694
azd env set AZURE_LOCATION uaenorth
azd env set AZURE_RESOURCE_GROUP_NAME thinkschool-dev-rg
azd env set AZURE_API_CONTAINER_APP_NAME quotes-api-dev
azd env set AZURE_CREATE_CAE true
azd env set JWT_SECRET $env:JWT_SECRET
azd env set AZURE_PRINCIPAL_ID a59d00a8-a829-49b4-83d1-952727eea166
azd env set SQL_ENTRA_ADMIN_LOGIN vaishalee.singh@s.amity.edu
azd up
```

A local `azd up` builds the API without the SPA — only the deploy workflow
stages the Angular bundle into `QuotesApi/spa/`. To include it locally:

```powershell
cd ..\..\Day13\quotes-web ; npm ci ; npx ng build
Copy-Item -Recurse -Force dist\quotes-web\browser\* ..\..\Day7\piece2\QuotesApi\spa\
```

**C8 — The known packaging correction.** `QuotesApi.csproj` pins
`ContainerRepository: quotes-api` while azd computes a different path, so the
container app needs one corrective update after each deploy. This is exactly why
`denySettings.mode` is `denyDelete`.

---

## 5. Phase D — GitHub Actions

Path A, since directory writes are permitted.

```powershell
az ad app create --display-name github-oidc-quotesapi
# record appId and the service principal's object id
az ad sp create --id <appId>

az ad app federated-credential create --id <appId> --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:thinkbridge-thinkschool/VaishaleeSingh:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

az role assignment create --assignee <appId> --role Contributor `
  --scope /subscriptions/85567e22-432e-4648-aa68-ba2714167694
az role assignment create --assignee <appId> --role "Role Based Access Control Administrator" `
  --scope /subscriptions/85567e22-432e-4648-aa68-ba2714167694
```

`Contributor` alone cannot create the AcrPull and Service Bus role assignments
the template declares. That second assignment is not optional.

Put the service principal's **object id** into `azure.yaml`'s
`denySettings.excludedPrincipals`.

| Name | Kind | Value |
|---|---|---|
| `AZURE_CLIENT_ID` | secret | the new app registration's appId |
| `AZURE_TENANT_ID` | secret | `8d46a076-d093-416d-a57b-8692cde13bf8` |
| `AZURE_SUBSCRIPTION_ID` | secret | `85567e22-432e-4648-aa68-ba2714167694` |
| `AZURE_RESOURCE_GROUP` | variable | `thinkschool-dev-rg` |
| `AZURE_CONTAINER_APP` | variable | `quotes-api-dev` |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | variable | from the stack outputs |

`AZURE_STATIC_WEB_APPS_API_TOKEN` and `SWA_ORIGIN` are no longer read by
anything and can be deleted once the old subscription is gone.

---

## 6. Phase F — verify before merging to `main`

A green deploy only means Azure accepted the request.

1. **Revision running** — `az containerapp revision list -n quotes-api-dev -g thinkschool-dev-rg --query "[?properties.active].properties.runningState"`
2. **`/health/ready` returns 200** — this is what fails if C5 was skipped or ran out of order.
3. **`POST /api/auth/login`** with an empty body returns 400 with `credentials`
   in the body. If it returns HTML, the fallback regex is not excluding `api/`.
4. **`GET /`** returns the Angular shell (`<app-root>`), and **`GET /quotes`**
   returns 200 — the deep-link fallback. A working API behind a missing bundle
   looks fine to a status check and shows a user a blank page.
5. **Service Bus end to end.** Create a quote; confirm the outbox drained and
   both subscriptions received it. A non-zero dead-letter count after a clean
   create means the managed identity's Service Bus role assignment did not land.
6. **Row counts match** what C6 recorded.
7. **Idempotency.** A second what-if reports no changes **and** does not revert
   the running image to the placeholder (`modules/fetch-container-image.bicep`
   is what prevents that).

The old Phase F check — "the Container App's own FQDN returns 401" — is deleted,
not skipped. That boundary went with the Static Web App.

Only then merge to `main`, which is what triggers both workflows.

---

## 7. Phase G — the Day 24 evidence

**Drift detection.** Change something out of band, the way a portal fix would:

```powershell
az containerapp update -n quotes-api-dev -g thinkschool-dev-rg --min-replicas 3
az deployment sub what-if -l uaenorth -f infra/main.bicep -p infra/main.dev.bicepparam `
  | Tee-Object ..\..\Day24\verification\drift-detected.txt
```

Expect `~ Modify` on `minReplicas` 3 → 0. Reconcile, capture the clean second
what-if. That pair of files is the evidence; asserting that drift detection
works is not.

**Deny settings.**

```powershell
az containerapp delete -n quotes-api-dev -g thinkschool-dev-rg --yes
```

Expect `RequestDisallowedByDeploymentStackDenyAssignment`. Capture it. **If the
delete succeeds, stop** — Phase H must not run until the deny setting applies.

---

## 8. Phase H — prod: deploy, verify, tear down

```powershell
$env:JWT_SECRET = [Convert]::ToBase64String((1..48 | % { Get-Random -Max 256 }))  # DIFFERENT from dev

az stack sub create -n quotes-prod -l koreacentral `
  --template-file infra/main.bicep --parameters infra/main.prod.bicepparam `
  --action-on-unmanage deleteAll --deny-settings-mode denyDelete `
  --deny-settings-apply-to-child-scopes --yes

# ... C5 again against the prod server, then verify ...

az stack sub delete -n quotes-prod --action-on-unmanage deleteAll --yes
az group exists -n thinkschool-prod-rg      # must print false
```

Capture that last pair to `Day24/verification/prod-teardown.txt`. A full
production environment provisioned and removed with nothing orphaned and nothing
left billing is the strongest evidence Day 24 can produce — and on a $100
twelve-month credit, a standing prod nobody uses is not a defensible allocation.

Prod has never been deployed in either subscription. Say that plainly rather
than letting a green pipeline imply a track record.

---

## 9. Phase I — decommission the old subscription

Last, and not before a week of the new dev environment being the one actually in
use.

```powershell
az account set --subscription 80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e
az group delete --name thinkschool-day23-rg --yes --no-wait
az group delete --name thinkschool-azd-rg   --yes --no-wait
az group delete --name thinkschool-rg       --yes --no-wait   # LAST, after the BACPAC is verified
```

**Not the tenant, and not app registration `91566dbd-…`** — §2.1.

---

## 10. Risk register

Resolved risks are kept rather than deleted; a register that only lists open
items loses the record of what was checked.

| # | Risk | Status |
|---|---|---|
| 1 | Dev param pointing at a Container Apps Environment in the old subscription | **Closed** — `createContainerAppsEnvironment = true` |
| 2 | Different tenant invalidating every Entra value | **Closed** — the API's scheme stays in the old tenant; only SQL/MI/OIDC moved |
| 3 | Region forbidden by policy | **Closed** — `uaenorth` / `koreacentral`, measured |
| 4 | Prod SQL admin an unresolvable GUID | **Closed** — real group |
| 5 | App registration blocked in a university tenant | **Closed** — permitted; OIDC path A |
| 6 | SQL SKU missing in the chosen region | **Closed** — `GP_S_Gen5_1/_2` offered in both |
| 7 | `az stack sub create` and `azd up` both claiming the same resources | **Open** — decide at C3 |
| 8 | `denyWriteAndDelete` blocking the image correction and CI | **Closed** — `denyDelete` + excluded principal |
| 9 | Contained SQL user created after the real image | **Open** — C5 before C7, always |
| 10 | BACPAC restored empty or partial | **Open** — row-count both sides at C6 |
| 11 | API now internet-reachable without the SWA boundary | **Open, accepted** — §2.3; record as a deviation |
| 12 | Container Apps quota binding prod's replica ceiling | **Open, unmeasured** — `az containerapp env list-usages` once the environment exists |
| 13 | Second Container Apps Environment refused in one region | **Mitigated** — prod is in a different region |
| 14 | Credit exhausted again | **Open** — the budget still needs creating; the CLI rejects it, so use the portal |
| 15 | Old tenant deleted during cleanup | **Open** — §9 |
| 16 | Deleting old resources too early | **Open** — Phase I is last |

---

## 11. Deviations to declare in the submission

1. **The front end is served by the Container App, not Azure Static Web Apps**,
   and the Container Apps authentication boundary is therefore gone. Forced by
   the subscription's region policy. §2.3.
2. **Prod's SKUs equal dev's SKUs.** Premium Service Bus and a provisioned SQL
   database exceed the entire credit. Prod differs in shape, not tier.
3. **Prod is torn down after verification** rather than left running.
4. **The Container App auth and linked-backend wiring were never in Bicep** and
   are now moot; the SPA-serving arrangement that replaced them *is* in code.
5. **`azd`'s deployment-stack support is an alpha feature**, opt-in today.
6. **Prod has never been deployed** in either subscription.
7. **The `azureAdAudience` disagreement is still unresolved** — §2.1 has the
   command that settles it.
