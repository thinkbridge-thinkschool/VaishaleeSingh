# infra

The whole infrastructure of QuotesApi, as Bicep. Day 23.

## Layout

```
main.bicep              subscription scope: the resource group + the module graph
main.dev.bicepparam     dev values
main.prod.bicepparam    prod values (what-if only — never deployed)
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

## Two parameter mechanisms

They are not interchangeable, and assuming they are is the trap:

|  | `.bicepparam` | `main.parameters.json` |
|---|---|---|
| Typed against the template | yes (`using`) | no |
| Compile error on a typo | yes | no — silently ignored |
| Read by `az deployment sub` | yes | yes |
| Read by `azd` | **no** | yes, with `${TOKEN}` substitution |

## Secrets

`jwtSecret` is `@secure()` and **neither parameter file carries a value**.

It is read from the environment when the parameter file is compiled. It cannot
be passed as an inline override, because `az` refuses to mix a `.bicepparam`
file with `-p name=value` arguments:

```bash
export JWT_SECRET='<at least 32 characters>'
az deployment sub create -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

For `azd`, which reads `main.parameters.json` rather than the parameter files:

```bash
azd env set JWT_SECRET '<at least 32 characters>'
azd env set AZURE_PRINCIPAL_ID "$(az ad signed-in-user show --query id -o tsv)"
```

There is no SQL password anywhere, by design — see the header of
`modules/sql.bicep`.

## Verify

```bash
az bicep build       --file infra/main.bicep --stdout > /dev/null
az bicep lint        --file infra/main.bicep
export JWT_SECRET='<at least 32 characters>'   # read at compile time
az bicep build-params --file infra/main.dev.bicepparam --outfile /dev/null
az bicep build-params --file infra/main.prod.bicepparam --outfile /dev/null

az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.prod.bicepparam
```

Deploy, then prove idempotency — the second `what-if` must report no changes:

```bash
az deployment sub create  -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

## The azd path is unverified

`azd` reads `main.parameters.json`, which resolves everything from environment
variables and otherwise takes the template's defaults — and those defaults are
not the dev environment's values. `resourceGroupName` defaults to
`thinkschool-azd-rg` and `apiContainerAppName` to `quotes-api-cowork`, which are
an older deployment's, and `sqlAllowedClientIpAddresses` has no entry at all.

Day 23 deployed with `az deployment sub create` and the `.bicepparam` files.
Nothing here has been through `azd`, so `azd up` against this template should be
treated as untested rather than assumed to work. `SQL_ENTRA_ADMIN_LOGIN`
deliberately has no fallback value, so azd fails loudly rather than quietly
installing a different SQL administrator than the one the parameter files name.

## One post-deploy step this cannot do

The app's managed identity needs a contained database user, which is T-SQL and
outside ARM's reach. Run `../scripts/create-sql-user.ps1` once after the first
deployment. It is idempotent. See the header of `modules/sql.bicep`.
