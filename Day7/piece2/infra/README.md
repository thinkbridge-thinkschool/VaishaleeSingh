# infra

The whole infrastructure of QuotesApi, as Bicep. Day 23 described it as modules;
Day 24 put it inside an Azure **deployment stack** and moved it to a new
subscription.

## Layout

```
main.bicep              subscription scope: the resource group + the module graph
main.dev.bicepparam     dev values
main.prod.bicepparam    prod values
main.parameters.json    azd's entrypoint. azd does NOT read .bicepparam files.
bicepconfig.json        linter, turned up
abbreviations.json      resource-name prefixes
modules/
  monitoring.bicep      Log Analytics + Application Insights
  registry.bicep        Container Registry + the AcrPull grant
  identity.bicep        the user-assigned managed identity the app runs as
  environment.bicep     Container Apps Environment — created, or referenced
  api.bicep             the Container App
  sql.bicep             Azure SQL server + database, Entra-only auth
  servicebus.bicep      namespace, topic, subscriptions, filter rules, RBAC
```

## Which subscription this targets

```
subscription  33c82ead-36a8-4d8f-b969-d8476690c224
tenant        803dced7-0a24-4857-8be8-280047561e95
```

Nothing was moved; everything here is re-created from this template.

**This migration changed the tenant as well as the subscription, and that is
the part with teeth.** The two earlier moves kept the directory, so object ids
and app registrations survived them. This one invalidates every
directory-scoped identifier: the operator's object id and UPN, the SQL
administrator group, both API app registrations, the SPA registration, and the
GitHub OIDC application. None of them is left at its old value — a stale client
id does not fail, it deploys and authenticates nothing.

Every one of them is a `SETME` sentinel in the parameter files, filled by a
script rather than by hand:

| Sentinel | Filled by |
|---|---|
| `SETME01…` | `migration/01-set-identities.ps1` |
| `SETME02…` | `Day25/scripts/02-entra-app-registrations.ps1` |
| `SETME10…` | `migration/10-refresh-derived-names.ps1`, after dev deploys |

`SETME10` exists because resource names are derived from
`uniqueString(subscription().id, environmentName, location)`. A new
subscription means a new token, so the registry, SQL server, Service Bus
namespace, Log Analytics workspace and Container Apps environment all get new
names — and everything that hardcoded the old ones had to stop.

`migration/README.md` is the order. `migration/90-verify-no-old-ids.ps1` fails
while any old identifier or any sentinel remains.

## Deployment stacks

The infrastructure is deployed as a stack, not as a loose subscription
deployment. Two properties come with that: **teardown is clean** (removing a
resource from the template deletes it rather than orphaning it), and **drift is
detectable** (an out-of-band portal change shows as a difference against the
template instead of surviving until something silently reverts it).

```bash
az stack sub create -n quotes-dev -l <region> \
  --template-file infra/main.bicep --parameters infra/main.dev.bicepparam \
  --action-on-unmanage deleteAll --deny-settings-mode denyDelete \
  --deny-settings-apply-to-child-scopes --yes
```

`azure.yaml` carries the same settings for the azd path, behind an alpha feature
that is **off by default**:

```bash
azd config set alpha.deployment.stacks on
```

Without it, azd ignores the `deploymentStacks` block entirely and does not warn.

**One owner, not two.** `az stack sub create` and `azd up` will both claim these
resources if you run both, and a stack claiming resources another stack manages
is the most confusing failure in this exercise. Either let azd own it (`azd up`,
with `az stack sub validate` for checks) or let the CLI own it (`az stack sub
create`, then `azd deploy` and never `azd up`).

`denySettings.mode` is `denyDelete`, not `denyWriteAndDelete` — see the comment
in `azure.yaml` for why the stricter mode would break the rollout path.

## Two parameter mechanisms

They are not interchangeable, and assuming they are is the trap:

|  | `.bicepparam` | `main.parameters.json` |
|---|---|---|
| Typed against the template | yes (`using`) | no |
| Compile error on a typo | yes | no — silently ignored |
| Read by `az deployment` / `az stack` | yes | yes |
| Read by `azd` | **no** | yes, with `${TOKEN}` substitution |

Day 24 added `resourceGroupName`, `apiContainerAppName` and
`createContainerAppsEnvironment` to `main.parameters.json`. Before that, azd fell
through to the template's own defaults for all three — and those defaults name
resources in the old subscription (`thinkschool-azd-rg`, `quotes-api-cowork`,
and a Container Apps Environment in `thinkschool-rg`). An `azd up` would
therefore have built a different, broken environment than the one the parameter
files build. That was the gap this file used to record as "the azd path is
unverified"; the two mechanisms now describe the same infrastructure, and the
check is a what-if after an azd deployment that reports no changes.

## Placeholders that fail on purpose

`main.dev.bicepparam` and `main.prod.bicepparam` ship with `REPLACE-WITH-…`
values for the region and the SQL administrator. They are not defaults waiting
to be improved — they are values that must be measured against this
subscription, and a placeholder that fails is better than a plausible one that
succeeds:

- **Region.** Azure for Students carries an allowed-regions policy whose contents
  vary per subscription. A refused region reports as a policy denial, which reads
  like a permissions problem.
- **SQL administrator.** With `azureADOnlyAuthentication` there is no SQL login to
  fall back on. A wrong object ID does not fail the deployment; it succeeds and
  leaves a server nobody can administer, and the only fix is redeploying it.

`Day24/scripts/00-preflight.ps1` measures both, plus quota, app-registration
rights, role assignments and tooling, and prints the exact lines to paste.

## Secrets

`jwtSecret` is `@secure()` and **neither parameter file carries a value**. It is
read from the environment when the parameter file is compiled, and it cannot be
passed as an inline override, because `az` refuses to mix a `.bicepparam` file
with `-p name=value`:

```bash
export JWT_SECRET='<at least 32 characters>'
az stack sub create ... --parameters infra/main.dev.bicepparam
```

For `azd`:

```bash
azd env set JWT_SECRET '<at least 32 characters>'
azd env set AZURE_PRINCIPAL_ID "$(az ad signed-in-user show --query id -o tsv)"
```

Use a **new** key. Not the literal still in this repository's git history, and
not the one the old subscription's app was signing with — a cutover is the right
moment to invalidate outstanding tokens rather than carry them across.

There is no SQL password anywhere, by design — see the header of
`modules/sql.bicep`.

## Verify

```bash
az bicep build        --file infra/main.bicep --stdout > /dev/null
az bicep lint         --file infra/main.bicep
export JWT_SECRET='<at least 32 characters>'   # read at compile time
az bicep build-params --file infra/main.dev.bicepparam  --outfile /dev/null
az bicep build-params --file infra/main.prod.bicepparam --outfile /dev/null

az stack sub validate -n quotes-dev -l <region> \
  --template-file infra/main.bicep --parameters infra/main.dev.bicepparam \
  --action-on-unmanage deleteAll --deny-settings-mode denyDelete
```

Deploy, then prove idempotency — the second what-if must report no changes, and
must not revert the running image to the placeholder:

```bash
az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam
```

## One post-deploy step this cannot do

The app's managed identity needs a contained database user, which is T-SQL and
outside ARM's reach. Run `../scripts/create-sql-user.ps1` once after the first
deployment, **before** the real image is deployed — an Entra-only server gives
the identity access to the server and no user inside the database, so an app
deployed first starts, fails to log in, and sits permanently unready. The script
is idempotent. See the header of `modules/sql.bicep`.

## Front end and back end deploy as two separate container apps

Azure Static Web Apps is not available in any region this subscription's
policy permits (`Microsoft.Web/staticSites` is not offered in
`indonesiacentral`/`malaysiawest`/`indiasouthcentral`/`uaenorth`/`koreacentral`),
so the Angular front end is not served by Static Web Apps here, and it is not
bundled into the API's container either. `modules/web.bicep` provisions it as
its own Container App (`quotes-web-<env>`), running the nginx image built from
`Day13/quotes-web/Dockerfile`, alongside `modules/api.bicep`'s API Container App
(`quotes-api-<env>`) — both in this stack, both behind the same Container Apps
Environment, deployed independently:

- the API rolls on pushes to `main` under `Day7/piece2/**` via
  `.github/workflows/day17-api-deploy.yml`;
- the front end rolls on pushes to `main` under `Day13/quotes-web/**` via
  `.github/workflows/day24-web-deploy.yml`.

`web.bicep` only receives `apiBaseUrl` (the API container app's ingress URI) as
a plain environment variable; nginx's `envsubst` templating
(`Day13/quotes-web/nginx/default.conf.template`) turns that into a same-region
reverse-proxy for `/api/` and `/health/` at container start, so the browser
still calls one same-origin host and CORS never enters the picture. Neither
app is part of `services:` in `azure.yaml` for the front end — only
`quotes-api` deploys through `azd`; the web container app is provisioned by
this stack but rolled by its own workflow, the same way the API's own image
updates are (see the `denySettings` comment in `azure.yaml` for why).

The Container Apps authentication that gated the old Static Web App's linked
backend has no equivalent here: the API's ingress is external by design and
the API defends itself with its own JWT authentication. That is a real
reduction in defence-in-depth versus the Day 17 arrangement, forced by a
policy this project does not control, and it is recorded as a deviation in
`Day24/docs/day24-deployment-stacks-azd-migration-plan.md`.
