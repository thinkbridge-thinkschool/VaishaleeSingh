# Day 24 — Deployment Stacks + azd, and the move to a new subscription

*Revision 2 — written after gate G0 was answered. The tenant is different, and
the new subscription is Azure for Students. Both facts change the plan
materially; revision 1's "same tenant, easy path" branch is deleted rather than
left in as a decoy.*

| | Old | New |
|---|---|---|
| Subscription | `80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e` | `85567e22-432e-4648-aa68-ba2714167694` |
| Offer | (exhausted) | **Azure for Students** |
| Tenant | `f774bb68-0575-4cd2-9d4c-3b4e593d1110` (`vaishalisinghsln5gmail.onmicrosoft.com`) | **`8d46a076-d093-416d-a57b-8692cde13bf8` (Amity University)** |

Nothing in Azure is "moved". Resources are re-created from `Day7/piece2/infra`
in the new subscription; only the database contents and the JWT signing key
actually migrate. Everything else is a redeploy.

**Read §1 before editing a single file.** A student subscription in a
university tenant has three constraints the current template violates, and all
three fail *late* — after a fifteen-minute deployment — unless they are checked
first.

---

## 0. The two findings that shape everything below

### 0.1 The Entra directory does not have to move

A tenant is free and does not expire with credits. The old directory
`f774bb68-…` still exists and still owns the API's app registration
`91566dbd-d857-488a-858d-475e60b309b7`.

So the Entra story **splits**, and this is the single most useful decision in
this plan:

| Concern | Which tenant | Why |
|---|---|---|
| The API's Entra ID auth scheme (`azureAdClientId`, `azureAdTenantId`, `azureAdAuthority`, `azureAdAudience`) | **Stays in the old tenant** `f774bb68-…` | JWT validation is an HTTPS call to an authority URL. It has no relationship to which tenant owns the subscription the container runs in. Nothing changes in `main.bicep`. |
| SQL Entra administrator (`sqlEntraAdminObjectId`, `sqlEntraAdminLogin`) | **Must be Amity** `8d46a076-…` | An Azure SQL server can only accept an Entra admin from the tenant its subscription trusts. The `#EXT#` gmail UPN is dead here. |
| The app's user-assigned managed identity | **Amity**, automatically | Created by the template, in the new subscription. |
| GitHub Actions OIDC | **Amity** | See §1.3 — and probably *not* as an app registration. |

This avoids needing app-registration rights in a university tenant for the API
itself, which is the thing most likely to be blocked.

**Confirm the old tenant is still reachable before relying on it:**

```powershell
az login --tenant f774bb68-0575-4cd2-9d4c-3b4e593d1110 --allow-no-subscriptions
az ad app show --id 91566dbd-d857-488a-858d-475e60b309b7 `
  --query "{uris:identifierUris, scopes:api.oauth2PermissionScopes[].value}"
```

That query also settles the `azureAdAudience` disagreement
`main.dev.bicepparam` records as unresolved (`api://quotes-api/access` vs the
app-ID-URI form). Resolve it here, from the directory, rather than carrying the
ambiguity into a new subscription.

If the old tenant turns out to be unreachable, the fallback is to disable the
Entra scheme in the new deployment (`AzureAd__*` unset) and run on the
first-party JWT only — stated as a deliberate reduction, not left to fail
silently at the first Entra-authenticated request.

### 0.2 The front end needs no Entra change at all

`Day13/quotes-web/src/environments/*` contains no client ID, no tenant, no
authority — only `apiBaseUrl`, and production sets it to `''` so every call is
same-origin through the Static Web App. Revision 1 listed "update MSAL config"
as a migration step. It does not exist. One less thing to break.

---

## 1. Gates — Azure for Students in a university tenant

Run all of §1 as read-only probes **before** editing anything. Each one has
already-known failure modes on this offer.

### G1 — Which regions are even allowed

Student subscriptions carry an *Allowed resource deployment regions* Azure
Policy, and the allowed set varies per subscription. `centralindia` — what
every parameter file currently names — may simply not be in it.

```powershell
az account set --subscription 85567e22-432e-4648-aa68-ba2714167694
az policy assignment list --query "[].{name:displayName, policy:policyDefinitionId}" -o table
az policy assignment list --query "[?contains(displayName,'region') || contains(displayName,'location')]" -o json
```

Then prove a region works rather than assuming:

```powershell
az group create --name probe-region-rg --location centralindia
az group delete --name probe-region-rg --yes
```

A policy denial here is unambiguous and costs nothing. **Whatever region
survives this probe is the value that goes into both parameter files** — do not
carry `centralindia` forward on habit.

### G2 — Compute quota

The published Azure for Students limit is around **4 vCPU regionally**, and
"Total Regional Core quota exceeded" is a routine error on this offer even with
credit remaining.

```powershell
az vm list-usage --location <region> --query "[?contains(name.value,'cores')].{name:localName, used:currentValue, limit:limit}" -o table
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.OperationalInsights --wait
az provider register --namespace Microsoft.ServiceBus --wait
az provider register --namespace Microsoft.Sql --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
```

`main.prod.bicepparam` currently asks for `apiCpu = '1.0'` with
`apiMaxReplicas = 10` — a ten-vCPU ceiling. On a four-vCPU subscription that
does not fail at deploy; it fails **at scale-out**, in production, under the
only load that would ever have justified prod. §2.3 brings it down.

### G3 — Can you create app registrations in the Amity tenant?

University tenants very often set *Users can register applications* to No. This
decides how GitHub OIDC is done, and it is the difference between ten minutes
and a support ticket.

```powershell
az rest --method GET --url https://graph.microsoft.com/v1.0/policies/authorizationPolicy `
  --query "value[0].defaultUserRolePermissions.allowedToCreateApplications"
```

- **`true`** → §6 path A: a normal app registration with a federated credential.
- **`false`** → §6 path B: a **user-assigned managed identity with a federated
  identity credential**. A UAMI is an ARM resource in your own subscription, so
  it needs no directory rights at all, and GitHub's `azure/login@v2` accepts it
  exactly like an app registration. This is the workaround; do not go asking
  Amity IT first.

### G4 — Are you Owner of the subscription?

The template creates role assignments (AcrPull, Service Bus Data Sender /
Receiver). `Contributor` cannot do that.

```powershell
az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) `
  --scope /subscriptions/85567e22-432e-4648-aa68-ba2714167694 `
  --query "[].roleDefinitionName" -o tsv
```

Expect `Owner` on a student subscription. If it says `Contributor`, the
deployment will get most of the way and then fail on the role assignments — the
worst place to find out.

### G5 — Your Amity identity, for the SQL admin

```powershell
az ad signed-in-user show --query "{id:id, upn:userPrincipalName, mail:mail}" -o json
```

Both values go into `main.dev.bicepparam` (§2.1). With
`azureADOnlyAuthentication` there is no SQL login to fall back on — a wrong
object ID means **nobody can administer the server at all**, and the fix is to
redeploy the server.

### G6 — Tooling version

`az stack` needs a recent CLI, and the azd stacks integration is an alpha
feature that must be switched on.

```powershell
az version
az upgrade                       # if az stack is missing
azd version
azd config set alpha.deployment.stacks on
azd config show
```

### G7 — Budget, before the second $100 goes the way of the first

A student subscription *disables itself* when the credit is exhausted. That is
what you are recovering from now.

```powershell
az consumption budget create --budget-name thinkschool-guard `
  --amount 25 --time-grain Monthly --category Cost `
  --time-period-start 2026-09-01 `
  --subscription 85567e22-432e-4648-aa68-ba2714167694
```

---

## 2. Repository changes — the exact edits

All paths relative to `Day7/piece2`. Work on a branch `day24-deployment-stacks`.
Merge to `main` only after Phase F passes — both deployment workflows trigger on
`main`, which is what you want and also means an unfinished merge deploys itself.

### 2.1 `infra/main.dev.bicepparam`

```diff
-param environmentName = 'thinkschool-day23'
-param location = 'centralindia'
-param resourceGroupName = 'thinkschool-day23-rg'
-param apiContainerAppName = 'quotes-api-day23'
+param environmentName = 'thinkschool-dev'
+param location = '<the region that survived G1>'
+param resourceGroupName = 'thinkschool-dev-rg'
+param apiContainerAppName = 'quotes-api-dev'
```

```diff
-param createContainerAppsEnvironment = false
-param containerAppsEnvironmentName = 'thinkschool-env'
-param containerAppsEnvironmentResourceGroup = 'thinkschool-rg'
+// New subscription: there is no environment to reuse. `thinkschool-env` and
+// `thinkschool-rg` live in the old subscription and are unreachable from here.
+// Left as false, the deployment fails on a reference to a resource group that
+// does not exist. This is the single most likely thing to break in the move.
+param createContainerAppsEnvironment = true
```

```diff
-param sqlEntraAdminObjectId = 'ddc82f6d-48cd-4406-adb6-a4b606833b34'
-param sqlEntraAdminLogin = 'vaishalisinghsln5_gmail.com#EXT#@vaishalisinghsln5gmail.onmicrosoft.com'
+// From G5, in the AMITY tenant 8d46a076-d093-416d-a57b-8692cde13bf8. The old
+// #EXT# gmail identity does not exist in this directory; an Azure SQL server
+// only accepts an Entra admin from the tenant its subscription trusts.
+param sqlEntraAdminObjectId = '<G5 id>'
+param sqlEntraAdminLogin = '<G5 userPrincipalName>'
 param sqlEntraAdminPrincipalType = 'User'
```

Also rewrite the long header comment. It currently explains a collision with two
old deployments in the old subscription; none of that applies now, and a stale
rationale is worse than none. Replace it with the tenant split from §0.1.

Renaming away from `day23` is free now and expensive later — `resourceToken` is
`uniqueString(subscription().id, environmentName, location)`, so the new
subscription already produces new names for everything regardless.

### 2.2 `infra/main.prod.bicepparam` — the honest version

Premium Service Bus and a provisioned 2-vCore SQL database are, together, more
per month than the entire student credit. Deploying them would exhaust the new
subscription in days — the exact failure being recovered from.

```diff
 param environmentName = 'thinkschool-prod'
-param location = 'centralindia'
+param location = '<region from G1 — a SECOND allowed region if G1 permits, else the same>'
 param resourceGroupName = 'thinkschool-prod-rg'
 param apiContainerAppName = 'quotes-api-prod'

-param sqlEntraAdminObjectId = '00000000-0000-0000-0000-000000000000'
-param sqlEntraAdminLogin = 'quotes-sql-admins'
-param sqlEntraAdminPrincipalType = 'Group'
+// A group, not a person — a production database whose only administrator is
+// one named individual loses its administrator when that person changes role.
+// Requires G3 = true; if group creation is blocked in the Amity tenant, use
+// the G5 user and record that as a deviation rather than shipping zeros.
+param sqlEntraAdminObjectId = '<real group object id>'
+param sqlEntraAdminLogin = 'quotes-sql-admins'
+param sqlEntraAdminPrincipalType = 'Group'

-param apiMinReplicas = 2
-param apiMaxReplicas = 10
-param apiCpu = '1.0'
-param apiMemory = '2Gi'
+// G2: this subscription's regional core quota is ~4 vCPU. maxReplicas 10 at
+// 1.0 vCPU is a 10-vCPU ceiling that does not fail at deploy — it fails at
+// scale-out, in production, under the only load that would have justified prod.
+param apiMinReplicas = 2
+param apiMaxReplicas = 4
+param apiCpu = '0.5'
+param apiMemory = '1Gi'

-param sqlSkuName = 'GP_Gen5'
-param sqlSkuCapacity = 2
-param sqlUseServerless = false
+// Serverless here too, unlike the original prod design. Stated as a constraint,
+// not a preference: a provisioned General Purpose database is roughly the whole
+// student credit per month. Auto-pause is disabled (-1) so prod keeps the
+// always-warm property that mattered; only the billing model changes.
+param sqlSkuName = 'GP_S_Gen5'
+param sqlSkuTier = 'GeneralPurpose'
+param sqlSkuCapacity = 2
+param sqlUseServerless = true
+param sqlAutoPauseDelayMinutes = -1

-param serviceBusSkuName = 'Premium'
+// Standard. Premium is dedicated capacity billed per messaging unit whether or
+// not a message flows, and it is not affordable on this offer. The topology is
+// identical; what is lost is latency predictability this workload has never
+// measured a need for.
+param serviceBusSkuName = 'Standard'
```

Leave `logRetentionInDays = 90`, `logDailyQuotaGb = -1`,
`createContainerAppsEnvironment = true`, `sqlBackupStorageRedundancy = 'Geo'`
and `serviceBusMaxDeliveryCount = 5` as they are. Those are the differences that
still hold — prod now differs from dev in **shape** (dedicated environment,
replica floor, no telemetry cap, geo-redundant backups, group-administered
database, more patient redelivery) rather than in **tier**. Say exactly that in
the submission; a reader who sees `GP_S_Gen5` in both files and no explanation
will assume prod was copied carelessly.

### 2.3 Prod is deployed, verified, and torn down

`createContainerAppsEnvironment = true` in both files means two Container Apps
environments. If G1 yields only one allowed region, the one-environment-per-
region limit blocks prod outright.

The resolution is the exercise itself: **deploy prod, verify it, then
`az stack sub delete` it.** Day 24 is about teardown being clean and provable —
so prove it on prod rather than on a throwaway. Phase H does this, and Phase G's
teardown probe becomes redundant if you take this route.

Standing prod costs roughly a Service Bus Standard namespace plus a Basic
registry plus a warm database, every month, for an environment nobody uses. On
$100 for twelve months that is not a defensible allocation.

### 2.4 `azure.yaml` — the Day 24 deliverable

```yaml
name: quotes-api

infra:
  provider: bicep
  path: infra
  deploymentStacks:
    actionOnUnmanage:
      resources: delete
      resourceGroups: delete
    denySettings:
      # denyDelete, NOT denyWriteAndDelete.
      #
      # denyWriteAndDelete would block the one corrective step this deployment
      # still needs -- `az containerapp update --image ...`, the packaging
      # workaround carried since Day 23 -- and would block the CI workflow that
      # rolls the app onto a new image. Deletion is what a stack exists to
      # prevent; a write to a resource the template already owns is not the
      # hazard here.
      mode: denyDelete
      applyToChildScopes: true
      excludedActions:
        - Microsoft.Resources/subscriptions/resourceGroups/delete
      excludedPrincipals:
        # The GitHub Actions OIDC principal (§6), so a control aimed at manual
        # portal deletes never blocks the pipeline.
        - <GITHUB_OIDC_PRINCIPAL_OBJECT_ID>

services:
  quotes-api:
    project: ./QuotesApi/QuotesApi.csproj
    language: dotnet
    host: containerapp
```

### 2.5 `infra/main.parameters.json`

azd reads this file and never the `.bicepparam` files. Every parameter whose
template *default* is wrong for the new subscription must appear here, or
`azd up` deploys a different shape than `az deployment sub create` does. Three
are missing today, and the defaults are the old subscription's.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "environmentName":                { "value": "${AZURE_ENV_NAME}" },
    "location":                       { "value": "${AZURE_LOCATION}" },
    "environmentType":                { "value": "${AZURE_ENVIRONMENT_TYPE=dev}" },
    "resourceGroupName":              { "value": "${AZURE_RESOURCE_GROUP_NAME}" },
    "apiContainerAppName":            { "value": "${AZURE_API_CONTAINER_APP_NAME}" },
    "createContainerAppsEnvironment": { "value": "${AZURE_CREATE_CAE=true}" },
    "quotesApiExists":                { "value": "${SERVICE_QUOTES_API_RESOURCE_EXISTS=false}" },
    "quotesApiImageName":             { "value": "${SERVICES_QUOTES_API_IMAGE_NAME}" },
    "jwtSecret":                      { "value": "${JWT_SECRET}" },
    "sqlEntraAdminObjectId":          { "value": "${AZURE_PRINCIPAL_ID}" },
    "sqlEntraAdminLogin":             { "value": "${SQL_ENTRA_ADMIN_LOGIN}" }
  }
}
```

This closes the "the azd path is unverified" gap `infra/README.md` records.
After Day 24 both mechanisms produce the same infrastructure, and Phase F step 7
proves it with a what-if that reports no changes.

### 2.6 `.github/workflows/day17-api-deploy.yml`

Every hardcoded value in the `env:` block belongs to the old subscription.

```diff
 env:
-  REGISTRY: crqn4pdkxclsa6s.azurecr.io
   IMAGE: quotes-api
-  RESOURCE_GROUP: thinkschool-rg
-  CONTAINER_APP: quotes-api-azd
+  REGISTRY: ${{ vars.AZURE_CONTAINER_REGISTRY_ENDPOINT }}
+  RESOURCE_GROUP: ${{ vars.AZURE_RESOURCE_GROUP }}
+  CONTAINER_APP: ${{ vars.AZURE_CONTAINER_APP }}
```

```diff
-          SWA_ORIGIN: https://yellow-river-074adb50f.7.azurestaticapps.net
+          SWA_ORIGIN: ${{ vars.SWA_ORIGIN }}
```

Trigger stays `branches: [main]`. Both workflows already deploy from `main`
only — that is what you asked for and it is already true. Use
`workflow_dispatch` to test from the branch; do not add the branch to the
trigger list.

### 2.7 Delete the stale azd state

`.azure/thinkschool-azd/.env` pins the old subscription, the old ACR
`crqn4pdkxclsa6s` and the old container app. Left in place, azd silently targets
a dead subscription.

```powershell
cd C:\thinkschool\Day7\piece2
Remove-Item -Recurse -Force .azure\thinkschool-azd
```

Add `.azure/` to `.gitignore` if it is not already there. `main.bicep`'s own
output comments note it is not ignored — which is how a connection string
reaches source control.

---

## 3. Phase B — capture from the old subscription, while it still answers

Credit exhaustion blocks new deployments; reads and exports usually keep working
for a while, but do not test how long.

```powershell
az account set --subscription 80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e
```

**B1 — Find which server holds the real data** before exporting the wrong one.
There are at least two candidates: the hand-created `thinkschoolsql45921` in
`thinkschool-rg` and Day 23's server in `thinkschool-day23-rg`. Row-count both.

**B2 — Export a BACPAC.** The Day 23 server is Entra-only, so
`az sql db export` (which wants a SQL admin) will not work against it. Use
SqlPackage with interactive Entra auth:

```powershell
SqlPackage /Action:Export `
  /SourceConnectionString:"Server=tcp:<old-server>.database.windows.net,1433;Database=quotes;Authentication=Active Directory Interactive;" `
  /TargetFile:"C:\thinkschool-migration\quotes-pre-migration.bacpac"
```

Write it to `C:\thinkschool-migration`, **outside the repository**. `_staging`
is inside it.

**B3 — Record the shape of the old deployment**, as a diffing reference:

```powershell
az group export --name thinkschool-rg       > C:\thinkschool-migration\old-thinkschool-rg.json
az group export --name thinkschool-day23-rg > C:\thinkschool-migration\old-day23-rg.json
```

**B4 — Generate a NEW JWT signing key.** Do not carry the old one across a
subscription boundary, and never the literal that is still in this repository's
git history. A cutover is the right moment to invalidate every outstanding
token.

**B5 — Delete nothing.** The old subscription stays untouched until Phase I.
Rollback is "point back at the old URLs", and that only exists while the old
resources do.

---

## 4. Phase C — dev into the new subscription

```powershell
az account set --subscription 85567e22-432e-4648-aa68-ba2714167694
az account show --query "{sub:name, id:id, tenant:tenantId}" -o table   # must show 8d46a076-...
cd C:\thinkschool\Day7\piece2
$env:JWT_SECRET = '<the new key from B4, at least 32 characters>'
```

**C1 — Compile. Silence is a pass.**

```powershell
az bicep build        --file infra/main.bicep --stdout > $null
az bicep lint         --file infra/main.bicep
az bicep build-params --file infra/main.dev.bicepparam  --stdout > $null
az bicep build-params --file infra/main.prod.bicepparam --stdout > $null
```

**C2 — Validate the stack.** Stricter than what-if, and it is where a student
subscription's Azure Policy denials surface.

```powershell
az stack sub validate `
  --name quotes-dev `
  --location <region> `
  --template-file infra/main.bicep `
  --parameters infra/main.dev.bicepparam `
  --action-on-unmanage deleteAll `
  --deny-settings-mode denyDelete
```

**C3 — What-if. Read three things, not the whole diff.**

```powershell
New-Item -ItemType Directory -Force ..\..\Day24\verification | Out-Null
az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam `
  | Tee-Object ..\..\Day24\verification\what-if-dev-newsub.txt
```

- **No `-` Delete lines.** New subscription — everything is `+ Create`.
- **The container app's image is the hello-world placeholder.** Correct on a
  first deployment. It must never revert to it later (proven at F7).
- **`Unsupported` diagnostics on the Service Bus and AcrPull role assignments.**
  Expected, not errors: what-if cannot evaluate an extension resource whose ID
  comes from a `reference()` resolved at deploy time.

**C4 — Decide who owns the stack, then create it.**

With `alpha.deployment.stacks` on, `azd up` creates a stack of its own named
after the azd environment. Two stacks over the same resources is a real
conflict, and it produces the most confusing failure in this whole plan.

- **Recommended — azd owns it.** Skip the `az stack sub create` below. Let
  `azd up` (C8) create the stack from `azure.yaml`'s `deploymentStacks` block.
  C2's `validate` still runs; it just does not create anything.
- **Alternative — the CLI owns it.** Run the command below, then use
  `azd deploy` (never `azd up`) so azd only ever pushes code.

```powershell
az stack sub create `
  --name quotes-dev `
  --location <region> `
  --template-file infra/main.bicep `
  --parameters infra/main.dev.bicepparam `
  --action-on-unmanage deleteAll `
  --deny-settings-mode denyDelete `
  --deny-settings-apply-to-child-scopes `
  --description "QuotesApi dev - Day 24" `
  --yes
```

`deleteAll` is what makes teardown clean: remove a resource from the template
and the next stack update deletes it, instead of leaving an orphan nobody
remembers provisioning.

**C5 — Let your own machine through the SQL firewall.** The server's only other
rule admits Azure services — the container app and nobody else. The next step
connects as a *person*.

```powershell
$env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
# re-run C4 -- the parameter file reads that variable
```

The IP stays out of the parameter file deliberately: it is personal data in a
committed file, and it changes between sessions.

**C6 — Create the contained database user. THIS STEP CANNOT MOVE.**

An Entra-only server gets the managed identity to the *server* and gives it no
user *inside the database*. Deploy the real image before this and the app
starts, fails with `Login failed for user '<token-identified principal>'`, and
sits permanently unready — up, and never ready.

```powershell
./scripts/create-sql-user.ps1 `
  -SqlServerFqdn (az stack sub show -n quotes-dev --query "outputs.azurE_SQL_SERVER_FQDN.value" -o tsv) `
  -DatabaseName  (az stack sub show -n quotes-dev --query "outputs.azurE_SQL_DATABASE_NAME.value" -o tsv) `
  -IdentityName  (az stack sub show -n quotes-dev --query "outputs.servicE_QUOTES_API_IDENTITY_NAME.value" -o tsv)
```

**That casing is not a typo.** ARM camel-cases the first segment of every output
name, so `AZURE_SQL_SERVER_FQDN` comes back as `azurE_SQL_SERVER_FQDN`. JMESPath
is case-sensitive; the name as written in the template returns null and the
script receives an empty parameter silently.

Run it as the account named in `sqlEntraAdminLogin` — the G5 Amity identity.
Anyone else gets a permission error, which is the Entra-only design working.

**C7 — Import the data.**

```powershell
SqlPackage /Action:Import `
  /SourceFile:"C:\thinkschool-migration\quotes-pre-migration.bacpac" `
  /TargetConnectionString:"Server=tcp:<new-server>.database.windows.net,1433;Database=quotes;Authentication=Active Directory Interactive;"
```

Verify row counts against B1 **before** anything writes to the new database. A
migration that imported an empty schema looks identical to a successful one
until the first user complains.

**C8 — Build and push the real image with azd.**

```powershell
azd env new thinkschool-dev
azd env set AZURE_SUBSCRIPTION_ID 85567e22-432e-4648-aa68-ba2714167694
azd env set AZURE_LOCATION <region>
azd env set AZURE_RESOURCE_GROUP_NAME thinkschool-dev-rg
azd env set AZURE_API_CONTAINER_APP_NAME quotes-api-dev
azd env set AZURE_CREATE_CAE true
azd env set JWT_SECRET '<the same key as C0>'
azd env set AZURE_PRINCIPAL_ID (az ad signed-in-user show --query id -o tsv)
azd env set SQL_ENTRA_ADMIN_LOGIN (az ad signed-in-user show --query userPrincipalName -o tsv)
azd up          # or `azd deploy`, per the C4 decision
```

**C9 — The known packaging correction.** `QuotesApi.csproj` pins
`ContainerRepository: quotes-api` while azd computes a different path, so the
container app still needs one corrective update:

```powershell
az containerapp update --name quotes-api-dev --resource-group thinkschool-dev-rg `
  --image <acr-endpoint>/quotes-api:<tag>
```

This is precisely why `denySettings.mode` is `denyDelete`. A
`denyWriteAndDelete` stack turns this known annoyance into a hard blocker.
Fixing the packaging bug properly is a follow-up, not a Day 24 item — but record
it as one.

---

## 5. Phase D — the front end

The Static Web App is not in the Bicep template, so it does not come across with
the stack.

**D1 — Create it. Standard, not Free** — linked backends require Standard, and
the Day 17 design depends on one.

```powershell
az staticwebapp create --name swa-quotes-dev --resource-group thinkschool-dev-rg `
  --location <region> --sku Standard
```

If Standard is unavailable or unaffordable on this offer, the fallback is Free
with the SPA calling the Container App's public FQDN directly — which means
turning **off** the Container Apps auth in D3 and adding the SWA origin to
`Cors:AllowedOrigins`. That is a materially weaker posture. Decide it
explicitly; do not arrive at it by accident because a `create` failed.

**D2 — Link the Container App as the backend.**

```powershell
az staticwebapp backends link --name swa-quotes-dev --resource-group thinkschool-dev-rg `
  --backend-resource-id (az containerapp show -n quotes-api-dev -g thinkschool-dev-rg --query id -o tsv) `
  --backend-region <region>
```

**D3 — Re-enable Container Apps authentication** with the SWA as the linked
identity provider. Hand-configured on Day 17, no Bicep. Without it the new
container app answers unauthenticated internet traffic — a regression the
migration introduces *silently*, because everything else still works.

**D4 — New deployment token, new GitHub secret.**

```powershell
az staticwebapp secrets list --name swa-quotes-dev --query "properties.apiKey" -o tsv
```

Save as repository secret `AZURE_STATIC_WEB_APPS_API_TOKEN`, replacing the old
one. The workflow's pre-flight step measures its length and fails loudly on a
truncated or whitespace-padded paste — trust that rather than eyeballing it.

**D5 — Record the new hostname** as repository variable `SWA_ORIGIN`, which §2.6
wired the API smoke test to read.

**D6 — Nothing to change in the Angular app.** Confirmed: no client ID, no
tenant, no authority anywhere in `Day13/quotes-web/src`, and production's
`apiBaseUrl` is `''` (same-origin). It just needs a merge to `main` to redeploy
against the new SWA.

---

## 6. Phase E — GitHub OIDC into the new subscription

**Path A — G3 returned `true`:** create an app registration in the Amity tenant
with a federated credential for
`repo:thinkbridge-thinkschool/VaishaleeSingh:ref:refs/heads/main`.

**Path B — G3 returned `false` (expect this):** use a **user-assigned managed
identity** with a federated identity credential. It is an ARM resource in your
own subscription, so it needs no directory rights, and `azure/login@v2` treats
it identically.

```powershell
az identity create -n id-github-oidc -g thinkschool-dev-rg -l <region>
az identity federated-credential create `
  --name github-main `
  --identity-name id-github-oidc `
  --resource-group thinkschool-dev-rg `
  --issuer https://token.actions.githubusercontent.com `
  --subject "repo:thinkbridge-thinkschool/VaishaleeSingh:ref:refs/heads/main" `
  --audiences api://AzureADTokenExchange
```

Either path, then grant it what the template needs:

```powershell
$appId = az identity show -n id-github-oidc -g thinkschool-dev-rg --query clientId -o tsv
$objId = az identity show -n id-github-oidc -g thinkschool-dev-rg --query principalId -o tsv

az role assignment create --assignee-object-id $objId --assignee-principal-type ServicePrincipal `
  --role Contributor --scope /subscriptions/85567e22-432e-4648-aa68-ba2714167694
az role assignment create --assignee-object-id $objId --assignee-principal-type ServicePrincipal `
  --role "Role Based Access Control Administrator" --scope /subscriptions/85567e22-432e-4648-aa68-ba2714167694
```

`Contributor` alone cannot create the AcrPull and Service Bus role assignments
the template declares. That second assignment is not optional.

Put `$objId` into `azure.yaml`'s `denySettings.excludedPrincipals` (§2.4) so the
deny setting never blocks the pipeline it is not aimed at.

Repository secrets and variables after this phase:

| Name | Kind | Value |
|---|---|---|
| `AZURE_CLIENT_ID` | secret | `$appId` from above |
| `AZURE_TENANT_ID` | secret | `8d46a076-d093-416d-a57b-8692cde13bf8` |
| `AZURE_SUBSCRIPTION_ID` | secret | `85567e22-432e-4648-aa68-ba2714167694` |
| `AZURE_STATIC_WEB_APPS_API_TOKEN` | secret | from D4 |
| `AZURE_RESOURCE_GROUP` | variable | `thinkschool-dev-rg` |
| `AZURE_CONTAINER_APP` | variable | `quotes-api-dev` |
| `AZURE_CONTAINER_REGISTRY_ENDPOINT` | variable | from the stack output |
| `SWA_ORIGIN` | variable | from D5 |

---

## 7. Phase F — verify dev end to end before merging to `main`

A green deploy only means Azure accepted the request. Run all seven.

1. **Revision running.**
   `az containerapp revision list -n quotes-api-dev -g thinkschool-dev-rg --query "[?properties.active].properties.runningState"`
2. **`/health/ready` returns 200.** This is what fails if C6 was skipped or ran
   out of order.
3. **API through the front door.** `POST {SWA_ORIGIN}/api/auth/login` with an
   empty body returns 400 with `credentials` in the body. A status-only check
   would pass on the SPA's fallback page; this one cannot.
4. **The Container App's own FQDN returns 401.** That is the security control
   working, not a failure — an earlier version of the Day 17 workflow read that
   401 as a broken deploy.
5. **Service Bus, end to end.** Create a quote; confirm the outbox drained and
   both subscriptions received it.
   ```powershell
   az servicebus topic subscription show --namespace-name <ns> -g thinkschool-dev-rg `
     --topic-name <topic> --name <audit-sub> `
     --query "{active:countDetails.activeMessageCount, dlq:countDetails.deadLetterMessageCount}"
   ```
   A non-zero `dlq` after a clean create means the managed identity's Service
   Bus role assignment did not land — check that before blaming the consumer.
6. **Row counts match B1.**
7. **Idempotency, and the image is not reverted.**
   ```powershell
   az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam `
     | Tee-Object ..\..\Day24\verification\idempotency-second-what-if.txt
   ```
   Two claims land on one command: the template does not drift against resources
   it just created, **and** the running image is not replaced by the placeholder
   (`modules/fetch-container-image.bicep` is what prevents that).

Only after all seven: merge `day24-deployment-stacks` to `main`, which is what
triggers both deployment workflows.

---

## 8. Phase G — drift detection and deny settings, the other half of Day 24

A stack makes drift *detectable*, which is only true if you look.

**Prove drift detection.** Change something out-of-band, the way a portal fix
would:

```powershell
az containerapp update -n quotes-api-dev -g thinkschool-dev-rg --min-replicas 3
az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam `
  | Tee-Object ..\..\Day24\verification\drift-detected.txt
```

Expect `~ Modify` on `minReplicas` 3 → 0. Then re-run the stack to reconcile and
capture the clean second what-if. That pair of files is the evidence; an
assertion that drift detection works is not.

**Prove the deny setting.**

```powershell
az containerapp delete -n quotes-api-dev -g thinkschool-dev-rg --yes
```

Expect `RequestDisallowedByDeploymentStackDenyAssignment` or equivalent. Capture
it to `Day24/verification/deny-settings-proof.txt`. **If the delete succeeds,
stop** — the deny setting is not applied, and Phase H must not run until it is.

**Prove clean teardown** — §2.3 makes prod the demonstration, so this is
optional. If you want it separately, note that `az stack sub validate` and
`create` cannot mix a `.bicepparam` file with inline `-p` overrides (the same
restriction `az deployment` has). Write a third small `.bicepparam` for the
probe rather than fighting the CLI.

---

## 9. Phase H — promote to prod, verify, tear down

Only after every box in Phase F is ticked and Phase G's proofs are on disk.

```powershell
$env:JWT_SECRET = '<a DIFFERENT key from dev>'

az deployment sub what-if -l <prod-region> -f infra/main.bicep -p infra/main.prod.bicepparam `
  | Tee-Object ..\..\Day24\verification\what-if-prod.txt

az stack sub create `
  --name quotes-prod `
  --location <prod-region> `
  --template-file infra/main.bicep `
  --parameters infra/main.prod.bicepparam `
  --action-on-unmanage deleteAll `
  --deny-settings-mode denyDelete `
  --deny-settings-apply-to-child-scopes `
  --yes
```

Prod-only steps that are easy to forget because dev did not need them:

- **A separate signing key.** Sharing dev's means a dev-issued token is valid in
  prod.
- **The contained SQL user again** (C6, against the prod server), before the
  real image.
- **A second Static Web App** with its own linked backend and its own token —
  and therefore a GitHub `prod` environment with its own variables, or a
  separate workflow file. Decide which and say so; the current workflows serve
  one environment.
- **`minReplicas = 2`.** One replica means every deployment and every node
  recycle is downtime.

Then, deliberately:

```powershell
az stack sub delete -n quotes-prod --action-on-unmanage deleteAll --yes
az group exists -n thinkschool-prod-rg     # must print false
```

Capture that to `Day24/verification/prod-teardown.txt`. That single command
pair is the strongest evidence Day 24 can produce: a full production
environment, provisioned and removed with nothing orphaned and nothing left
billing. It also keeps the credit for dev.

Prod has never been deployed in either subscription. Say that plainly in the
write-up rather than letting a green pipeline imply a track record.

---

## 10. Phase I — decommission the old subscription

Only after prod is verified, and not before a full week of the new dev
environment being the one actually in use.

```powershell
az account set --subscription 80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e
az group delete --name thinkschool-day23-rg --yes --no-wait
az group delete --name thinkschool-azd-rg   --yes --no-wait
# thinkschool-rg LAST, and only after the BACPAC has been restored and verified
az group delete --name thinkschool-rg --yes --no-wait
```

**Do not delete the old Entra tenant or the app registration
`91566dbd-…`** — §0.1 keeps the API's Entra scheme pointed at it. Deleting the
directory breaks Entra authentication in the new subscription.

Keep the BACPAC and the two `az group export` files for at least 30 days.

---

## 11. Risk register

| # | Risk | Where it bites | Mitigation |
|---|---|---|---|
| 1 | Dev param points at `thinkschool-env` / `thinkschool-rg`, which do not exist in the new subscription | Deployment fails on a dangling resource-group reference | §2.1 sets `createContainerAppsEnvironment = true` |
| 2 | `centralindia` blocked by the student region policy | Every deployment denied, with a policy error that reads like a permissions bug | G1 probes a region before any edit |
| 3 | ~4 vCPU regional quota vs prod's 10-vCPU ceiling | Not at deploy — at scale-out, in production | §2.2 caps prod at 4 replicas × 0.5 vCPU |
| 4 | App registration blocked in the Amity tenant | GitHub OIDC cannot be set up the usual way | G3, then §6 path B — a UAMI with a federated credential needs no directory rights |
| 5 | Old `#EXT#` gmail UPN used as SQL admin | Deployment succeeds and **nobody can administer the server**; fix is to redeploy it | G5 supplies the Amity identity |
| 6 | Prod `sqlEntraAdminObjectId` still `00000000-…` | Prod deployment rejected | §2.2 requires a real group (or a documented deviation) |
| 7 | Premium Service Bus + provisioned SQL in prod | The new $100 goes the way of the old one, in days | §2.2 drops both to the affordable tier and says so |
| 8 | `az stack sub create` and `azd up` both claim the same resources | A stack-ownership conflict with a genuinely confusing error | C4 — pick one owner before either runs |
| 9 | `denyWriteAndDelete` blocks C9's image correction and the CI rollout | Pipeline red with a permissions error that looks like a bad credential | §2.4 uses `denyDelete` + excluded CI principal |
| 10 | SQL contained user created after the real image | App up, permanently unready | C6 runs before C8, always |
| 11 | BACPAC restored empty or partial | Looks like a clean migration until a user notices | C7 verifies row counts against B1 |
| 12 | Container Apps auth not re-enabled | API openly reachable from the internet | D3, and F4 |
| 13 | Stale `.azure/thinkschool-azd/.env` | azd targets the dead subscription | §2.7 |
| 14 | Stale SWA token | "No matching Static Web App was found or the api key was invalid" — reads like an Azure fault | D4; the workflow's length pre-flight catches shape errors |
| 15 | Old tenant or app registration deleted during cleanup | Entra auth breaks in the *new* subscription | §10 — the directory is free and must survive |
| 16 | Deleting old resources too early | No rollback path | Phase I is last, gated on a week of real use |

---

## 12. Order of operations

```
G1 region policy   G2 quota   G3 app-reg rights   G4 Owner
G5 Amity identity  G6 tooling + azd alpha         G7 budget
0.1 confirm the old tenant still answers

B1..B5   row counts, BACPAC, group export, new JWT key, delete nothing

§2.1..§2.7  repo edits on branch day24-deployment-stacks

C1 compile        C2 stack validate    C3 what-if
C4 stack owner    C5 SQL firewall      C6 contained SQL user  ◄── cannot move
C7 import data    C8 azd up/deploy     C9 image correction

D1..D6   SWA Standard, linked backend, container-app auth, token, origin
E        OIDC (UAMI path expected) + secrets/variables

F1..F7   verify dev end to end     ◄── gate before merging to main
merge to main  ─────────────────►  both workflows deploy from main

G        drift proof, deny proof
H        prod: deploy, verify, THEN tear down with the stack  ◄── the Day 24 evidence
I        decommission the old subscription   ◄── last, after a week, tenant survives
```

---

## 13. What this plan does not claim

- Prod has never been deployed in either subscription. Everything in Phase H is
  a considered choice, not an observed one.
- Prod's SKUs are now dev's SKUs. The difference is shape — dedicated
  environment, replica floor, uncapped telemetry, geo backups, group-owned
  database, more patient redelivery — not tier. That is a budget constraint
  stated as one, not a design improvement.
- The Container App auth and SWA linked-backend wiring (D2, D3) remain outside
  Bicep. Reproduced by hand in the new subscription; the same gap Day 17 left,
  carried forward knowingly rather than quietly.
- `azd`'s deployment-stack support is an **alpha** feature. It is documented to
  become the default, but today it is opt-in and may change.
- The student subscription's exact allowed regions, SKU filtering and quota are
  applied per-subscription and are not fully published. G1 and G2 measure this
  one rather than trusting a general list.
