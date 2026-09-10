# Day 24 — Deployment Stacks + azd

**Exercise:** Deploy the full stack with Azure Deployment Stacks (so teardown
is clean and drift is detectable), driven by the `azd` CLI. Deploy to dev,
then promote to prod. Paste the azd config + the deploy output for both
environments, and one line on what Deployment Stacks give you over plain
deployments.

## What this deploys

One Azure Deployment Stack (`quotes-dev` in dev), scoped at the subscription,
containing: the resource group, Azure SQL (Entra-only auth) and its database,
Service Bus (namespace, topic, two subscriptions), Container Registry, the
user-assigned managed identity the apps run as, Log Analytics + Application
Insights, and two Container Apps — `quotes-api-dev` (the ASP.NET Core API) and
`quotes-web-dev` (the Angular front end, served by nginx) — sharing one
Container Apps Environment. Front end and back end are deployed as separate
container apps, each rolling on its own GitHub Actions workflow triggered only
by pushes to `main`; only the API is provisioned *and* rolled through `azd` —
the web container app is provisioned by the stack but rolled by its own
workflow, the same as the API's own image updates are.

## azd config — `Day7/piece2/azure.yaml`

The Day 24 addition is the `infra.deploymentStacks` block, which turns `azd
up`/`azd deploy` from a loose subscription deployment into a managed
Deployment Stack. It sits behind an alpha feature that is off by default:

```bash
azd config set alpha.deployment.stacks on
```

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
      mode: denyDelete
      applyToChildScopes: true

      excludedActions:
        - Microsoft.Resources/subscriptions/resourceGroups/delete
        - Microsoft.Sql/servers/firewallRules/delete

      # excludedPrincipals: left commented out until the operator's and the
      # GitHub OIDC principal's object IDs are added — see the reasoning
      # below.

services:
  quotes-api:
    project: ./QuotesApi/QuotesApi.csproj
    language: dotnet
    host: containerapp
```

`actionOnUnmanage.resources: delete` (not `detach`) is what makes removing a
resource from the template actually delete it, instead of leaving an orphan
that keeps billing — the failure mode that matters most on a student
subscription. `denySettings.mode` is `denyDelete`, not `denyWriteAndDelete`:
the stricter mode would also block the routine `az containerapp update
--image ...` that every rollout still needs, and the deploy workflows that do
exactly that.

`excludedActions` carries one entry that only exists because the stack
blocked its own cleanup: `sqlAllowedClientIpAddresses` names a SQL firewall
rule after the operator's IP, a home IP changes, and the old rule then leaves
the template. `actionOnUnmanage` correctly tries to delete it — and is
refused by the stack's *own* deny assignment, because the unmanage-delete
runs in the caller's security context and `applyToChildScopes: true` extends
`denyDelete` to every child of the SQL server, firewall rules included:

```
DenyAssignmentAuthorizationFailed: ... denied because of the deny assignment
... created by Deployment Stack '.../quotes-dev'
```

Excluding that one action (rather than turning `applyToChildScopes` off
entirely, which would also unprotect the database) is the fix.

`azd`'s own parameters come from `infra/main.parameters.json`, not the
`.bicepparam` files — `azd` does not read those. Day 24 added
`resourceGroupName`, `apiContainerAppName` and `createContainerAppsEnvironment`
there; without them `azd` fell through to the template's own defaults, which
name resources in the old, out-of-credit subscription.

## Deploy output — dev

Deployed via `az stack sub create`/`update` (CLI-owned; see `azure.yaml`'s
"one owner, not two" note — `azd` never claimed these resources itself in
this run) into subscription `85567e22-432e-4648-aa68-ba2714167694`, region
`uaenorth`.

The create plan (`az deployment sub what-if`, run before the first apply)
confirmed the stack was about to provision the resource group and the API
container app from nothing — excerpt below (the full run is not kept on disk;
the final stack state, not this initial plan, is the evidence that matters
once deployed):

```
Resource and property changes are indicated with these symbols:
  + Create

The deployment will update the following scopes:

Scope: /subscriptions/85567e22-432e-4648-aa68-ba2714167694

  + resourceGroups/thinkschool-dev-rg [2021-04-01]
      location:              "uaenorth"
      name:                  "thinkschool-dev-rg"
      tags.azd-env-name:     "thinkschool-dev"
      tags.environment-type: "dev"

Scope: /subscriptions/.../resourceGroups/thinkschool-dev-rg

  + Microsoft.App/containerApps/quotes-api-dev [2023-05-01]
      identity.type:                               "UserAssigned"
      properties.configuration.ingress.external:    true
      properties.configuration.ingress.targetPort:  8080
      ...
```

Final state: stack `quotes-dev` reached `succeeded` with 21 managed resources,
including both container apps, Azure SQL, and Service Bus. SQL Server
migrations were applied out of band (see `03-apply-sql-migrations.ps1` below)
and confirmed via `Day24/verification/sqlserver-migrations-applied.txt`.

Live endpoints (dev):

- API: `https://quotes-api-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io`
- Web: `https://quotes-web-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io`

## Deploy output — prod

**Not run, and the reason is a decision rather than an omission.** The
promotion path is built and validated; creating the stack is one command
behind an explicit switch. What stopped it is cost, stated below.

Reading the prod parameters properly turned up five things that would each
have produced a prod environment that deployed green and did not work. They
are worth more than a second copy of the dev deploy log.

**1. Prod would have run Microsoft's hello-world container.** With
`quotesApiExists = false` and `webAppExists = false`, `main.bicep` resolves the
image to `mcr.microsoft.com/azuredocs/aci-helloworld:latest` — the placeholder
that exists so an infra-only update cannot revert a running app. Prod also gets
its **own** registry, because the name derives from a resource token, and CI
only ever pushes to dev's. So promotion has to move the image, and it moves it
with `az acr import` rather than a rebuild: a rebuild on the release branch
compiles the same source into a *different* binary — different base digest,
different SDK patch, different restored packages — and what reaches production
is then something no test ever ran against.

**2. Prod had no Entra parameters, and the defaults were worse than nothing.**
`main.bicep` defaulted `azureAdClientId`, `azureAdTenantId` and
`azureAdAudience` to values copied out of `appsettings.json`: a tenant that no
longer owns anything here, a registration that does not live in the current
tenant, and `api://quotes-api/access` — a *scope*, not an audience, which is
the bug Day 25 found and fixed in dev's parameter file. Prod overrode none of
them, so prod would have deployed cleanly and authenticated nothing, silently,
because no genuine Entra token has been sent yet.

The three parameters are now **required, with no defaults**. A default that is
silently wrong is worse than a missing value, because a missing value stops the
deployment and asks. `02-entra-app-registrations.ps1` takes `-Environment
dev|prod` and writes them into the matching parameter file, and
`05-promote-prod.ps1` refuses to promote if prod's client id equals dev's —
sharing one registration means a token minted for dev is valid in production.

**3. The SQL administrator is a group that has to exist first.**
`sqlEntraAdminObjectId` names the group `quotes-sql-admins`. If it is not in
the tenant, the deployment fails on the SQL server — after the resource group
and registry already exist. Now a preflight check.

**4. Two steps ARM cannot do, both learned in dev.** The vault is created
empty on purpose, so the first deploy of any fresh environment *always* fails
once: the container app cannot resolve its `jwt-secret` reference. And an
Entra-only server grants the identity access to the *server*; the contained
user inside the *database* is T-SQL. Skipping it produces an app that starts
and never becomes ready. `main.bicep` now emits `AZURE_KEY_VAULT_NAME` so the
promotion script can find the vault it must seed rather than reading it out of
the portal, which is how a secret ends up in the wrong environment's vault.

**5. Cost, which is why this is not run.** Prod is deliberately not dev, and
four of the differences bill whether or not anyone uses the app:

| | dev | prod |
|---|---|---|
| `apiMinReplicas` | 0 | **2**, always on |
| `sqlAutoPauseDelayMinutes` | 60 | **-1**, never pauses — 2 vCores continuous |
| `sqlBackupStorageRedundancy` | Local | **Geo** |
| `logDailyQuotaGb` | 1 | **-1**, no cap at all |

Every one is correct for a real production environment. All of them are
continuous spend on a subscription with finite credits — and the last one
deserves naming twice: this project already blew dev's 1 GB cap with a log
flood, and in prod that flood would have had no ceiling. So
`05-promote-prod.ps1` prints this block and stops unless `-IAcceptTheCost` is
passed. Spending should be a decision somebody made, not a side effect of
running a script called "promote".

One security note, recorded rather than silently accepted:
`sqlPublicNetworkAccess = 'Enabled'` in prod. Entra-only authentication means
there is no password path, so this is not a credential exposure — but the
server is still reachable from any address the firewall rules permit, and for
production that deserves a private endpoint or an explicit decision.

### Promoting, once the cost is accepted

```
./Day24/scripts/05-promote-prod.ps1 -WhatIf          # preflight + validate only
./Day24/scripts/05-promote-prod.ps1 -IAcceptTheCost  # create, seed, import, roll, verify
az stack sub delete --name quotes-prod --action-on-unmanage deleteAll --yes
```

That teardown line is the exercise's other half working: the stack knows every
resource it created, so removing prod is one command rather than whatever the
operator remembers to select.

## Two environments, two merges

`main` deploys **dev**. `production` deploys **prod**. Nothing deploys both.

- `day17-api-deploy.yml` and `day24-web-deploy.yml` trigger on `main` and are
  scoped to dev's resources.
- `prod-deploy.yml` triggers only on `production`, runs under a GitHub
  Environment named `production` so a required reviewer gates it, and
  **promotes** — it imports the already-built image and never compiles.
- The OIDC principal holds `AcrPush` and `Contributor` on each environment's
  resources *separately*, never one Contributor at the subscription. With a
  subscription-wide grant the separate branch, the environment and the reviewer
  would all be procedure rather than permission, and procedure is what gets
  bypassed at 2am.

### One tag per app, not one per release — which the first run proved

The promotion was keyed on the release commit's sha, for both images. Preflight
rejected it immediately:

```
OK    quotes-api:b2ee57546f24 exists in the dev registry
FAIL  quotes-web:b2ee57546f24 is not in the dev registry
```

The API and the front end are built by **separate workflows with separate path
filters**, deliberately — an Angular change must not rebuild and redeploy the
API. So a commit touching only `Day7/piece2` produces `quotes-api:<sha>` and no
`quotes-web:<sha>`. **There is no single tag both images share, and there never
was**; a promotion keyed on one sha fails on whichever half the release did not
touch.

Each app now promotes the tag **its dev counterpart is currently running**,
resolved off the live container app. That is stronger than a sha as well as
correct: the running image is the only artefact that has actually been
exercised, and "prod runs what dev runs" is what promoting dev to prod means. A
tag can still be passed explicitly, for a rollback. Both the script and the
workflow also refuse to promote `:latest` — unversioned, impossible to roll
back to, and in this template it is the hello-world placeholder.

The gate is unchanged and is still one query: an image only reaches the dev
registry if the dev pipeline built it, and that pipeline only builds after the
unit and integration tests pass. So "is this tag in the dev registry" is
exactly "was this artefact tested".

**What that costs, stated plainly:** the sha check used to double as
enforcement that `production` was fast-forwarded, because a merge commit's sha
carried no image. Resolving tags from the running dev app removes that
side effect. Fast-forward is still how the branch should be advanced —

```
git checkout production && git merge --ff-only main && git push
```

— but nothing automatic enforces it now. A branch protection rule requiring
linear history on `production` is where that belongs, and it is not yet set.

One trap worth writing down, because it breaks a working pipeline the moment
the gate is added: a job declaring `environment: production` presents the OIDC
subject `repo:<owner>/<repo>:environment:production` **instead of** the branch
ref subject — it replaces it rather than being sent alongside. Add the
environment for the reviewer gate and authentication fails with AADSTS700213
naming a subject nobody registered. `01-github-oidc.ps1` registers the branch
form and the environment form, in both the documented and the immutable subject
spellings this organisation uses.

## What Deployment Stacks give you over a plain deployment

A plain `az deployment sub create` (or `azd up` without this block) leaves no
record of the resource *set* it created — removing something from the
template just orphans it, and a portal change nobody remembers making
survives silently forever; a Deployment Stack tracks that set as one managed
unit, so removing a resource from the template deletes it on the next update
instead of leaving an orphan that keeps billing, and any out-of-band change
shows up as drift against the template instead of surviving unnoticed.

## Changes made for this task

Scoped to the Deployment Stacks / azd work itself — not the region, SQL
administrator, or other values that only needed to change because this is a
new subscription:

- Added the `infra.deploymentStacks` block to `azure.yaml` (`actionOnUnmanage`,
  `denySettings`) and enabled the `alpha.deployment.stacks` feature flag.
- Added `resourceGroupName`, `apiContainerAppName` and
  `createContainerAppsEnvironment` to `infra/main.parameters.json` so `azd`'s
  own parameter path (which never reads `.bicepparam` files) targets the same
  resources as the CLI path instead of the template's stale defaults.
- Excluded `Microsoft.Sql/servers/firewallRules/delete` from
  `denySettings.excludedActions` after the stack's own deny assignment blocked
  its own cleanup of a superseded SQL firewall rule.
- Added `modules/fetch-container-image.bicep` plus the `quotesApiExists` /
  `webAppExists` parameters, so a stack update that only touches infrastructure
  preserves whatever image is already running instead of reverting the
  container app to the placeholder image.
- Added `modules/web.bicep` and wired it into `main.bicep`, so the front end
  is a second Container App inside the same stack, deployed and rolled
  independently of `azd`'s own `quotes-api` service.
- Moved SQL Server migrations out of app startup and into a deployment step
  (`Day24/scripts/03-apply-sql-migrations.ps1`, an idempotent script), because
  `Database.MigrateAsync()` at startup was diffing against the wrong
  (SQLite) migrations assembly and crashing the container before it could
  bind a port.
- `Day24/scripts/00-preflight.ps1`, `01-region-fit.ps1`, `02-deploy-dev.ps1`,
  `04-finish-dev.ps1` — the deployment automation itself: preflight checks,
  region/quota fit, the initial stack deploy, and an idempotent
  finish-and-smoke-test step.

## Cleanup done alongside this submission

- Removed the now-dead "Angular front end, served by this app" block from
  `Program.cs`, the orphaned `<Content Include="spa\**\*">` glob from
  `QuotesApi.csproj`, and the matching `.gitignore` entry — all leftover from
  an earlier, rejected approach (SPA served from inside the API container)
  that this stack no longer builds; the front end deploys as its own
  container app instead (see `modules/web.bicep`).
- Corrected `infra/README.md`'s "What is still not described here" section,
  which still described the front end as an unmodelled, hand-wired Static Web
  App — that section now describes the two-container-app architecture that is
  actually in the template.
- Deleted `Day7/piece2/.azure/_superseded/`, the old subscription's azd
  environment backup — its own note said to delete it once `thinkschool-dev`
  was confirmed working, which it now is.
