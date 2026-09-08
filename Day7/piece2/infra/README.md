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
subscription  85567e22-432e-4648-aa68-ba2714167694   "Azure for Students"
tenant        8d46a076-d093-416d-a57b-8692cde13bf8   "Amity University"
```

The previous subscription (`80d20ef9-…`, tenant `f774bb68-…`) is out of credit.
Nothing was moved; everything here is re-created from this template.

**The Entra story spans two tenants on purpose.** A directory is free and does
not expire with a subscription's credits, so the API's Entra ID authentication
scheme still points at the *old* tenant and its app registration
`91566dbd-…` — token validation is an HTTPS call to an authority URL and has no
relationship to which tenant owns the subscription. What must live in the Amity
tenant is the SQL administrator (a server only accepts an admin from the tenant
its subscription trusts), the managed identity, and the GitHub OIDC principal.

Do not delete the old tenant when decommissioning the old subscription.

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

## What is still not described here

The Static Web App, its linked backend, and the Container Apps authentication
that keeps the API unreachable from the internet were wired by hand on Day 17
and remain outside this template. They are re-created by hand in the new
subscription. A knowingly-carried gap, not an oversight — writing them in now
would mean shipping infrastructure that has never been deployed.
