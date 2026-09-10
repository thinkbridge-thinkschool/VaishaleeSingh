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

Not yet run. `infra/main.prod.bicepparam` is written and region-checked
(`koreacentral`, confirmed permitted by this subscription's allowed-locations
policy via `01-region-fit.ps1`) and `az stack sub validate` passes against it,
but `az stack sub create` for `quotes-prod` has not been executed in this
subscription — promoting dev to prod, verifying it, and tearing it back down
is the next step, tracked separately from this submission rather than
reported here as done.

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
