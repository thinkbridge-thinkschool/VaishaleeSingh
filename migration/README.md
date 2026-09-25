# Migration runbook — new subscription, new tenant

**Target**

```
subscription  33c82ead-36a8-4d8f-b969-d8476690c224
tenant        803dced7-0a24-4857-8be8-280047561e95
region        uaenorth
```

Everything — dev, prod, the web front end and the capstone — is re-created here
from the templates in this repository. Nothing is moved: Azure has no "move a
resource to another tenant" operation for the resources this system uses, and
even where it exists it does not carry identity with it.

---

## Read this before you start

This migration is not the same shape as the two before it, and assuming it is
will cost you a day.

**The earlier moves changed only the subscription.** The directory stayed, so
object ids and app registrations survived and the change was essentially two
GUIDs in a parameter file.

**This one changes the tenant as well**, and a tenant move invalidates every
directory-scoped identifier there is:

| What | Why it cannot be carried |
|---|---|
| Your object id and UPN | You are a different principal in a different directory |
| The `quotes-sql-admins` group | A group exists inside one tenant |
| Both API app registrations | An app registration is a tenant object |
| The SPA registration | Same |
| The GitHub OIDC application | Same, plus its federated credential |

None of these is left at its old value. A stale client id is the worst kind of
wrong, because **it does not fail** — the deployment succeeds, the container
app starts, `/health` returns 200, and every genuine Entra token is rejected on
issuer or audience. Nothing points at that as the cause.

**And the resource names change too.** `main.bicep` derives them from
`uniqueString(subscription().id, environmentName, location)`, so a new
subscription produces a new token: the registry, SQL server, Service Bus
namespace, Log Analytics workspace and Container Apps environment all get new
names. The token cannot be computed offline — `uniqueString` is an ARM
function, not a published algorithm — so the only honest way to learn the new
names is to deploy dev and read them back.

### The sentinels

Every value that could not be carried is a **sentinel**, not a stale value:

| Sentinel | Means | Filled by |
|---|---|---|
| `SETME01…` | a directory object id or UPN | `migration/01-set-identities.ps1` |
| `SETME02…` | an app registration client id | `Day25/scripts/02-entra-app-registrations.ps1` |
| `SETME10…` | a name derived from the subscription | `migration/10-refresh-derived-names.ps1` |

A sentinel is not a valid GUID, so a deployment that reaches one **fails and
names it**. That is the entire reason for choosing a sentinel over a plausible
value: placeholders that fail are better than plausible values that succeed.

`migration/90-verify-no-old-ids.ps1` is the gate. It fails while any old
identifier survives in live configuration, and while any sentinel is unfilled.

---

## The order

Each step says what it needs from the step before it. The order is not
cosmetic — four of these steps cannot be moved.

### 1. Sign in to the new tenant

```powershell
az login --tenant 803dced7-0a24-4857-8be8-280047561e95
az account set --subscription 33c82ead-36a8-4d8f-b969-d8476690c224
```

`az account show` reporting the right subscription is **not** the same as being
signed in to the directory that owns it, and the difference surfaces much later
as a permissions error that reads like a missing role. Check `tenantId` in the
output, not just `id`.

### 2. Preflight

```powershell
./migration/00-preflight-new-subscription.ps1 -Region uaenorth
```

Six gates, and every one of them failed for somebody in this repository at
least once. The two worth waiting for:

- **G5, the Container Apps environment quota.** The old subscription permitted
  exactly one environment *in total* — not one per region — and prod found that
  out by being refused with `MaxNumberOfGlobalEnvironmentsInSubExceeded`. This
  script counts what exists; whether the new subscription has the same limit is
  measured at step 6, not assumed here.
- **G6, directory write rights.** Steps 3 and 4 create app registrations and a
  group. University and corporate tenants commonly withhold both. Better known
  now than with dev half-standing.

**Do not continue while a gate is red.**

### 3. Identities — fills `SETME01`

```powershell
./migration/01-set-identities.ps1 -WhatIf
./migration/01-set-identities.ps1
git diff Day7/piece2/infra Day24/scripts/02-deploy-dev.ps1
```

Reads `az ad signed-in-user show` and writes your new object id and UPN into
both parameter files and `Day24/scripts/02-deploy-dev.ps1`, and sets the two
azd environment values. It also creates `quotes-sql-admins` for prod and adds
you to it.

**If group creation is refused**, the script falls back to you as a `User`
administrator and prints that as a stated deviation. Record it. A production
database whose only administrator is one named individual loses its
administrator when that person changes role — that is a real weakening of the
design, not a formality.

Why a script and not "paste your object id": with `azureADOnlyAuthentication`
there is no SQL login to fall back on, so a wrong-but-well-formed object id
does not fail the deployment. It succeeds and leaves a server **nobody can
administer**, and the only repair is to redeploy the server.

### 4. App registrations — fills `SETME02`

```powershell
./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev -WhatIf
./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev
./Day25/scripts/02-entra-app-registrations.ps1 -Environment prod
```

Creates the API and SPA registrations in the new tenant and writes
`azureAdTenantId`, `azureAdClientId` and `azureAdAudience` into the parameter
file it targets. It is idempotent — it looks registrations up by display name
and updates in place, because duplicate registrations with the same name fail
later as an audience mismatch rather than as anything naming the duplicate.

**Prod gets its own registration and must not share dev's.** One registration
means one consent grant, one set of redirect URIs, and tokens both environments
accept — so a token minted for the dev SPA would be valid against production.
Neither registration has a client secret, so two cost nothing.

The dev `-WebUrl` default still contains a `SETME10` domain at this point. That
is fine: it is only a redirect URI, and step 7 re-runs this script once the real
domain exists.

### 5. Deploy dev

```powershell
./Day24/scripts/01-region-fit.ps1 -Region uaenorth
./Day24/scripts/02-deploy-dev.ps1 -WhatIf
./Day24/scripts/02-deploy-dev.ps1
```

This is the first thing that creates anything. It deploys the `quotes-dev`
stack with `--action-on-unmanage deleteAll`, which is also what makes step 13
short.

**Four things about a first deployment into a fresh subscription. None is
obvious from the templates, and every one of them cost a run.**

**(a) The `exists` flags must be `false` first, then `true`.**
`quotesApiExists` and `webAppExists` in `main.dev.bicepparam` — and the matching
`SERVICE_QUOTES_API_RESOURCE_EXISTS` in the azd environment — tell the template
to read the image off the *running* container app instead of using the
placeholder. Where the app does not exist yet, `true` makes `fetchLatestImage`
resolve against nothing and the deployment fails. So: deploy with both `false`,
and set both `true` the moment both apps run a real image. Leaving them `false`
is the opposite failure and a quieter one — every later deploy rewrites the
running app back to `mcr.microsoft.com/azuredocs/aci-helloworld`, whose probes
then fail, because it serves a static page and has no `/health/live`.

**(b) The Container Apps environment must state its mode.** Azure now
provisions an environment created without `properties.environmentMode` as an
**express** environment, and express environments reject
`configuration.secrets[].keyVaultUrl`:

```
ExpressEnvironmentFeatureNotSupported
'KeyVaultUrl in secrets' is not supported for container app '...'
```

Day 23/25 keep the JWT signing key in Key Vault and reach it by
managed-identity reference, so this design *requires* a workload-profiles
environment. `modules/environment.bicep` now pins a newer API version and states
`environmentMode: 'WorkloadProfiles'`. An existing express environment cannot be
converted in place; it has to be deleted and recreated. While the stack owns it,
that delete is refused by the stack's own deny assignment, so the sequence is:

```powershell
az stack sub delete --name quotes-dev --action-on-unmanage detachAll --yes
az containerapp env delete -n <env> -g thinkschool-dev-rg --yes
./Day24/scripts/02-deploy-dev.ps1
```

`detachAll` removes the stack and its deny assignments and **deletes nothing**;
the next create re-adopts every resource.

Nothing was wrong with the old environment — this broke because a platform
default moved underneath a template pinned to an older API version. That is
worth remembering as a category, not just as an incident.

**(c) The vault must hold `jwt-secret` before the container app is created.**
The reference resolves when a revision is created, so a stack run against an
empty vault fails with `Unable to get value using Managed identity ... for
secret jwt-secret`. The vault itself is created by the stack, so in practice the
first run fails, you seed (step 8's `01-seed-jwt-secret.ps1`), and you run again.
`05-promote-prod.ps1` automates that dance for prod; the dev script does not yet.

**(d) Dev's vault needs `keyVaultWriterPrincipalId`.** `keyvault.bicep` grants
that principal Key Vault Secrets Officer **on this vault alone** — deliberately,
because a hand-granted assignment dies with the vault on the next failed deploy.
Prod had always set it; dev never had, so dev's fresh vault arrived unwritable
and the seed script returned a flat 403. Both parameter files set it now. If you
do grant the role by hand to unblock yourself, delete that assignment before the
next deploy: it has a random name, the template's has a deterministic one, and
Azure refuses the second with `RoleAssignmentExists` — and refuses the delete
too, until the stack is detached, for the same deny-assignment reason as (b).

### 6. SQL user, then migrations, then the real image

```powershell
./Day7/piece2/scripts/create-sql-user.ps1
./Day24/scripts/03-apply-sql-migrations.ps1 -SqlServerFqdn sql-quotes-<token>.database.windows.net
./Day24/scripts/04-finish-dev.ps1
```

**The order inside this step is the one that catches people.** An Entra-only
SQL server grants the identity access to the *server*; it does not create a
user inside the *database*. ARM cannot do it — the contained user is T-SQL. Skip
it and the app **starts and then never becomes ready**, which looks like a hang
rather than a permissions error. (`02-deploy-dev.ps1` now creates the contained
user itself, so this is belt and braces rather than the only path.)

**Migrations are part of this step, not a later tidy-up.** The API refuses to
start against a database with no applied migrations — deliberately, and it says
so:

```
System.InvalidOperationException: The SQL Server database has no applied
migrations. They are applied by the deployment, not by this app
```

That exception is the best failure in this whole migration: to produce it the
app had already resolved its Key Vault secret, authenticated to an Entra-only
SQL server as its managed identity, and queried `__EFMigrationsHistory`. Three
things proven by one error.

One mechanical note: a revision that already failed does not retry itself, and
neither `revision restart` nor `revision copy` will help — copy produces no new
revision when the template is byte-identical. Force a genuinely new one:

```powershell
az containerapp update -n quotes-api-dev -g thinkschool-dev-rg `
  --image <acr>.azurecr.io/quotes-api:<tag> --revision-suffix postmigrate1
```

`04-finish-dev.ps1` still carries `SETME10` names at this point. Pass the real
ones on the command line, or run step 7 first and then this — either works; the
script takes them as parameters precisely so this is not a chicken-and-egg.

### 7. Refresh the derived names — fills `SETME10`

```powershell
./migration/10-refresh-derived-names.ps1 -WhatIf
./migration/10-refresh-derived-names.ps1
git diff
```

Reads back what Azure actually named things — registry, SQL server, Service Bus
namespace, Log Analytics workspace, Container Apps environment and its default
domain — and rewrites the hardcoded defaults across eleven files and the root
`README.md` URL table.

Then re-run step 4's dev command once, so the SPA redirect URI names the real
domain instead of a sentinel:

```powershell
./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev
```

### 8. The rest of dev

```powershell
./Day25/scripts/01-seed-jwt-secret.ps1      # the one secret that cannot be eliminated
./Day25/scripts/00-prove-no-secrets.ps1     # and the proof that it is the only one
./Day26/scripts/01-github-oidc.ps1          # creates the NEW OIDC app + role assignments
./Day26/scripts/02-verify-telemetry.ps1
./Day27/scripts/01-reconcile-sql-firewall.ps1
```

`01-github-oidc.ps1` prints the new application's `appId`. Keep it — step 9
needs it.

**It does not register a credential for the `dev` branch, and both deploy
workflows run on `dev`.** The script registers `main`, `pull_request`,
`production` and `environment:production`, in both the plain and the
organisation-id spelling of the subject. A run on `dev` presents a subject none
of those match and fails with `AADSTS700213`, which reads like a configuration
error anywhere but where it is. Until the script is fixed, add both spellings by
hand:

```powershell
$app = '<appId>'
@'
{"name":"dev","issuer":"https://token.actions.githubusercontent.com","subject":"repo:<org>/<repo>:ref:refs/heads/dev","audiences":["api://AzureADTokenExchange"]}
'@ | Set-Content -Path "$env:TEMP\fc-dev.json" -Encoding ascii
az ad app federated-credential create --id $app --parameters "@$env:TEMP\fc-dev.json"
```

and again with the `<org>@<orgId>/<repo>@<repoId>` spelling. `az ad app
federated-credential list --id $app --query "[].subject" -o tsv` should then show
six subjects.

The web front end also needs its own image built and pushed once, because it is a
separate nginx image that no .NET publish produces and that CI builds with
`docker build`:

```powershell
cd Day13/quotes-web
az acr login --name <acr>
docker build -t "<acr>.azurecr.io/quotes-web:<tag>" .
docker push "<acr>.azurecr.io/quotes-web:<tag>"
az containerapp update -n quotes-web-dev -g thinkschool-dev-rg --image "<acr>.azurecr.io/quotes-web:<tag>" --revision-suffix web1
```

`01-reconcile-sql-firewall.ps1` matters more here than it looks. A Consumption
Container Apps environment does not guarantee its outbound address, and when it
moved last time every container stopped booting **while the deployment stayed
green**. The rule is reconciled rather than pinned for that reason.

### 9. GitHub Actions

```powershell
./migration/20-set-github-secrets.ps1 -ClientId <appId from step 8> -WhatIf
./migration/20-set-github-secrets.ps1 -ClientId <appId from step 8>
```

**No workflow file needed editing**, and that is worth noticing: every workflow
already reads `client-id`, `tenant-id` and `subscription-id` from repository
secrets and its resource names from repository variables. Had those been
written into the YAML, this migration would have touched five workflow files
instead of zero.

The script needs the GitHub CLI. If `winget` is not available either, a portable
copy works and needs no administrator:

```powershell
$rel   = Invoke-RestMethod https://api.github.com/repos/cli/cli/releases/latest
$asset = $rel.assets | Where-Object { $_.name -like '*windows_amd64.zip' } | Select-Object -First 1
Invoke-WebRequest $asset.browser_download_url -OutFile "$env:TEMP\gh.zip"
Expand-Archive "$env:TEMP\gh.zip" -DestinationPath "$env:USERPROFILE\gh" -Force
$env:PATH = "$env:USERPROFILE\gh\bin;$env:PATH"
gh auth login
```

**One workflow does have to change: `day17-swa-deploy.yml` must be disabled.**
`Microsoft.Web/staticSites` is offered in a handful of regions worldwide and
none of them is permitted here, which is why the front end is an nginx container
app in the first place. Left enabled, it goes red on every push to `main`
forever — and a check that is always red is a check nobody reads.

```powershell
gh workflow disable day17-swa-deploy.yml --repo <org>/<repo>
```

### 10. Prod

```powershell
./Day24/scripts/05-promote-prod.ps1 -WhatIf
./Day24/scripts/05-promote-prod.ps1
```

Prod does not rebuild — it imports the image dev already built and tested with
`az acr import`, so the bytes that passed the tests are the bytes that run. The
promotion refuses any tag the dev registry does not hold, which is exactly the
question "was this commit tested in dev".

One permission trap, which cost a whole attempt last time: **`AcrPush` does not
include `import`.** The source registry needs its own read permission for the
principal doing the import. `01-github-oidc.ps1 -ProdRegistry <name>` creates a
custom `ACR Image Importer (quotes)` role for exactly this.

**Prod's Key Vault had to be renamed.** Key Vault names are *global*, not
per-subscription, and unlike everything else in `main.bicep` the prod vault name
is a literal rather than a `uniqueString` derivation. The old subscription's
`kv-quotes-prod` still holds the name, and waiting for it would make prod's
creation depend on the teardown that is meant to happen last. So
`main.prod.bicepparam` now says `kv-quotes-prod-v2` — the same reasoning that
renamed the capstone registry and SQL server. A soft-deleted vault is a different
case with a different fix (`az keyvault list-deleted`, then `az keyvault purge`);
check which one you have before reaching for either.

**Prod's `exists` flags start `false` too.** They were committed as `true`, which
was the truth on the old subscription and a lie on this one — the preflight
checks them against reality and says so. Set both `false` before the first prod
create, and both `true` immediately after step 9 of that script rolls the apps
onto the imported images.

After prod exists, re-run step 9 so
`AZURE_PROD_CONTAINER_REGISTRY_ENDPOINT` names the real prod registry, and
re-run `01-github-oidc.ps1 -ProdRegistry <name>` so the pipeline can reach it.

### 11. Capstone

```powershell
./Day32/scripts/00-provision-azure.ps1
./Day32/scripts/01-provision-identity.ps1
./Day29/scripts/00-provision-servicebus-topology.ps1
./Day32/scripts/02-deploy.ps1
./Day32/scripts/happy-path.ps1
```

Two capstone resources had **globally unique** names that still exist in the old
subscription, so creating them again would fail on a name already taken. They
have been renamed rather than left to collide:

| Was | Now |
|---|---|
| `acrquotescapstone` | `acrquotescapstonev2` |
| `sql-quotes-capstone` | `sql-quotes-capstone-v2` |

Everything else in the capstone is scoped to a resource group and does not
collide.

One thing to expect: after creating the Service Bus role assignments,
**propagation takes a few minutes, and during those minutes nothing errors** —
outbox rows sit at `Pending` and the relay looks broken when it is simply not
yet authorised. Wait before debugging.

### 12. Verify

```powershell
./migration/90-verify-no-old-ids.ps1
```

Must print **CLEAN**. If it does not, it names the file and line.

Then check the things a script cannot:

```powershell
curl https://quotes-api-dev.<new-domain>.uaenorth.azurecontainerapps.io/health
curl https://quotes-api-prod.<new-domain>.uaenorth.azurecontainerapps.io/health
```

A 200 on `/health` is a stronger signal than it looks: it means the app booted,
so its Key Vault reference resolved (the JWT signing key is bound with
`ValidateOnStart()` and a minimum length), and EF Core authenticated to an
Entra-only SQL server as its managed identity — where no password path exists to
explain the result.

Also worth doing by hand, because nothing else covers it: sign in through the
SPA and exercise one Entra-authenticated call. The `CustomJwt` scheme working
proves nothing about the `EntraId` scheme, and a wrong client id is invisible
until a genuine Entra token is sent.

### 13. Tear down the old subscription

Only now.

```powershell
./migration/99-teardown-old-subscription.ps1 -WhatIf
./migration/99-teardown-old-subscription.ps1
```

It refuses to run while `90-verify-no-old-ids.ps1` is not clean — until the new
environment is proven, the old subscription is the only place this system
exists, and deleting it removes what you would otherwise roll back to.

It deletes the two stacks (prod first, because prod references the shared
Container Apps environment that lives in dev's resource group), then any
resource group the stacks did not own — including `thinkschool-rg` from the
very first manual `az cli` exercise, which no stack ever managed and which would
otherwise keep billing quietly.

It does **not** delete the old directories or their app registrations. A tenant
is free, it does not expire with a subscription's credit, and deleting one is
irreversible in a way deleting a resource group is not. That is a separate
decision.

---

## What was changed in the repository, and what was not

**Changed** — live configuration, 30 files:

- `Day7/piece2/infra/main.dev.bicepparam`, `main.prod.bicepparam` — new tenant,
  sentinels for everything directory-scoped, and the stale rationale about a
  two-tenant Entra split deleted rather than left reading as current
- `Day7/piece2/infra/main.bicep` — the comment explaining why the three Entra
  parameters have no defaults now also records what a tenant move does to them
- `Day7/piece2/infra/README.md`, root `README.md`
- `Day7/piece2/.azure/thinkschool-dev/.env` — rewritten; the derived values
  (registry endpoint, principal id) removed so azd repopulates them rather than
  carrying a stale name forward
- thirteen PowerShell scripts across Day 24–32
- `Day17/.env.example`
- `Day24/scripts/00-preflight.ps1` gate G0b — it used to check that a *separate*
  directory was still reachable, which was only true while the Entra story was
  split across tenants. It now checks that the registration exists in *this*
  tenant.

**Not changed, on purpose** — historical record:

`docs/`, every `*submission*.md`, every `*postmortem*.md` and every
`verification/` output still names the old subscription, the old tenants and the
old resource names. They describe work that really was done there, against those
exact identifiers. Editing them would make them false, and a submission that
lies about which subscription it ran in is worth less than one that is merely
out of date. `90-verify-no-old-ids.ps1` excludes them by design and reports how
many it skipped; `-IncludeDocs` lists them.

**Not changed because it did not need to be**: `.github/workflows/*`. All five
already read identity from secrets and names from variables.

---

## If something goes wrong

| Symptom | Most likely cause |
|---|---|
| Deployment fails naming a `SETME…` value | A step was skipped. The sentinel names which one. |
| App starts, never becomes ready | The contained SQL user was not created (step 6). ARM cannot do it. |
| Every Entra token rejected, `CustomJwt` fine | `azureAdClientId` or `azureAdAudience` still wrong. The audience is `api://<appId>`, **not** a scope. |
| `MaxNumberOfGlobalEnvironmentsInSubExceeded` | This subscription also permits one Container Apps environment in total. Prod must reference dev's rather than create its own. |
| Workflow fails with 404 on the registry | A wrong subscription and a missing role look identical — ARM returns 404 for what you cannot read. Check both. |
| Containers stop booting, deployment green | The Container Apps outbound address moved. Re-run `Day27/scripts/01-reconcile-sql-firewall.ps1`. |
| Outbox rows stuck at `Pending`, no errors | Service Bus role assignment has not propagated yet. Wait a few minutes. |
| `az acr import` fails with permissions | `AcrPush` does not include `import`. The source registry needs its own read grant. |
| `ExpressEnvironmentFeatureNotSupported` on `keyVaultUrl` | The environment was created without `environmentMode`, so Azure made it express. Detach the stack, delete the environment, redeploy. It cannot be converted. |
| `VaultAlreadyExists` | Key Vault names are global. Either it is soft-deleted here (`az keyvault list-deleted` → `az keyvault purge`) or it is alive on another subscription (rename). |
| `RoleAssignmentExists` | A hand-granted assignment duplicates the template's. Delete the hand-made one — after detaching the stack, or the deny assignment refuses that too. |
| `DenyAssignmentAuthorizationFailed` | The stack is protecting its own resource. `az stack sub delete --action-on-unmanage detachAll` removes the protection and keeps everything. |
| App starts, then dies on `InvalidOperationException` about migrations | Migrations have not been applied to that database. The app refuses to self-migrate by design. |
| Revision stuck `ActivationFailed` after the cause was fixed | A failed revision does not retry, and `revision copy` creates nothing when the template is unchanged. Force one with `--revision-suffix`. |
| `NativeCommandError` against a PowerShell line, naming no az problem | Windows PowerShell 5.1 turns native-command stderr into a terminating error under `$ErrorActionPreference = 'Stop'`, and `2>$null` does not prevent it. Route the call through the `Invoke-Az` helper. |
| Workflow on `dev` fails `AADSTS700213` | No federated credential registers the `dev` subject. Add both spellings; do not widen the existing ones. |
