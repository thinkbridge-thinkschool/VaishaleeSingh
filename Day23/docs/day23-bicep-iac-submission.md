# Day 23 — Bicep IaC: submission

## Task, as given

> Describe your infra as code. Author Bicep modules (parameterized) for the API,
> SQL, and Service Bus, with separate dev/prod parameter files. No portal
> click-ops.

## What is here

| | |
|---|---|
| Modules | `Day7/piece2/infra/modules/` — eight of them |
| Orchestration | `Day7/piece2/infra/main.bicep` |
| Parameter files | `main.dev.bicepparam`, `main.prod.bicepparam` |
| azd's entrypoint | `main.parameters.json` (azd does **not** read `.bicepparam`) |
| Linter | `bicepconfig.json`, several rules raised to error |
| Deployment order | [`day23-deployment-runbook.md`](day23-deployment-runbook.md) |
| The plan, kept as written | [`day23-bicep-iac-implementation-plan.md`](day23-bicep-iac-implementation-plan.md) |
| Evidence | `../verification/` |

Deployed and verified against a real subscription. `thinkschool-day23-rg`,
`centralindia`, 19 resources, `provisioningState: Succeeded`.

## What it replaced

`infra/resources.bicep` — 13 KB, every resource in one file, no parameters
beyond a name and a location. Deleted.

Two things were missing from it entirely:

- **SQL.** `Microsoft.Sql` appeared in **zero** templates in this repository.
  The deployed container app had never had a `ConnectionStrings__DefaultConnection`
  set, so it had been running on the SQLite file baked into its image.
- **Service Bus.** `Day19/infra/servicebus.bicep` existed and was referenced by
  nothing — a template describing a topology no deployment ever created. Moved
  into the graph, not copied: two divergent Service Bus templates in one
  repository is the failure this exercise is about.

## The modules

| Module | What it owns |
|---|---|
| `monitoring.bicep` | Log Analytics + workspace-based Application Insights |
| `registry.bicep` | Container Registry, and the AcrPull grant |
| `identity.bicep` | The user-assigned managed identity the app runs as |
| `environment.bicep` | Container Apps Environment — created, or referenced |
| `api.bicep` | The Container App |
| `sql.bicep` | Azure SQL server + database, Entra-only auth |
| `servicebus.bicep` | Namespace, topic, subscriptions, filter rule, RBAC |
| `fetch-container-image.bicep` | Reads the image the app is already running |

Eight, where the task names three. The other five are extracted in the same pass
because leaving them inline would just have been a smaller monolith. Two of them
exist for reasons the deployment itself produced, and are explained below.

**Where a role assignment lives.** A `roleAssignment`'s `scope:` needs a
symbolic reference to the resource being granted on, and that reference only
exists in the file declaring it. So AcrPull lives in `registry.bicep` taking the
principal as a parameter, and the Service Bus grants live in `servicebus.bicep`.
The `guid()` seeds are byte-identical to the pre-Day-23 ones: change what you
feed `guid()` and the next deployment creates a second assignment rather than
recognising the first.

## dev vs prod

One template. The parameter files differ in values only.

| | dev | prod |
|---|---|---|
| `apiMinReplicas` / `apiMaxReplicas` | 0 / 2 | 2 / 10 |
| `apiCpu` / `apiMemory` | 0.5 / 1Gi | 1.0 / 2Gi |
| `createContainerAppsEnvironment` | false — reuse `thinkschool-env` | true |
| `sqlSkuName` | `GP_S_Gen5` serverless | `GP_Gen5` provisioned |
| `sqlAutoPauseDelayMinutes` | 60 | n/a — illegal on provisioned |
| `sqlMaxSizeBytes` | 2 GB | 32 GB |
| `sqlBackupStorageRedundancy` | Local | Geo |
| `sqlEntraAdminPrincipalType` | User | Group |
| `serviceBusSkuName` | Standard | Premium |
| `serviceBusMessageTimeToLive` | P1D | P7D |
| `serviceBusMaxDeliveryCount` | 3 | 5 |
| `logRetentionInDays` | 30 | 90 |
| `logDailyQuotaGb` | 1 | -1 (uncapped) |

Three of these are decisions rather than dials. `apiMinReplicas: 0` is a cost
choice in dev and a cold start on a customer request in prod. `logDailyQuotaGb: 1`
is a cost guard in dev and, in prod, guarantees that the one incident big enough
to blow the cap is the one you cannot investigate. And `sqlEntraAdminPrincipalType`
is `Group` in prod because a production database whose only administrator is one
named individual loses its administrator when that person changes role.

**prod has never been deployed.** It is `what-if`'d to show one template
produces both shapes; nothing in it has been observed running. Its own header
says so.

## The secret that used to be in source control

`resources.bicep` set a Container Apps secret to the literal
`Vaishalee-A41105222049-QuotesApiJwt2026`, with a comment acknowledging it. A
dev/prod split is where that stops being defensible: it would have had to be
duplicated into two committed files.

`jwtSecret` is now `@secure()` and **neither parameter file carries a value** —
they read `JWT_SECRET` from the environment at compile time. The deployment
record confirms the mechanism works: the parameter appears as

```json
"jwtSecret": { "type": "SecureString" }
```

with no `value` field. It is not readable by someone who can read the
deployment.

The same reasoning drives the SQL design: `azureADOnlyAuthentication: true`, no
`administratorLogin`, no password parameter anywhere. There is no SQL password
to place in two files because the server has no SQL login at all. That decision
is what made the parameter-file split tractable rather than awkward.

## Idempotency — the claim, stated exactly

Deploy, then plan again:

```
Resource changes: 6 to modify, 9 no change, 3 unsupported, 1 to ignore.
```

Not "no changes" — and that is the honest answer rather than the disappointing
one. `what-if` does not evaluate `reference()`, so any template that composes a
connection string from a deployed resource will always show those properties as
changing. Reaching a literal "no changes" would mean not using `reference()`.

The claim is: **every remaining modify is what-if measurement error, in one of
three named categories**, and none of them describes a resource this template
fails to describe correctly. Each of the 6 is attributed line by line in
[`../verification/idempotency-analysis.txt`](../verification/idempotency-analysis.txt):
`reference()` unresolved at plan time; service-populated properties the template
does not declare, reported as removals that Incremental mode does not perform;
and comparisons what-if declines to make.

The check earned its keep on its first run by finding two **real** drifts, both
mine, both since fixed:

**1. The `$Default` Service Bus rule — Day 19's premise was wrong.** Day 19
declared a `$Default` rule redefined as `1=0`, on the stated reasoning that
"adding a rule does NOT replace `$Default`". That template was never deployed by
anything, so the reasoning was never tested. The idempotency plan showed
`$Default` as a **create** against resources nothing had touched: it did not
exist. Service Bus deletes the default rule when the first explicit rule is
added. ARM created it, `content-changes-only` made the service delete it, and
every deployment would have repeated that forever. Removed;
`content-changes-only` now reads `= Nochange`. The `audit` subscription keeps
its TrueFilter precisely because it has no explicit rule — the same behaviour
seen from the other side, and what makes audit receive everything.

**2. The HTTP scale rule shape.** Declared as `custom:` with `type: 'http'`.
Container Apps accepts that and normalises it into a native `http` rule, so the
template described a resource the service cannot store — permanent drift on a
correct resource. That is how a team learns to ignore what-if output, and
ignoring it is how the real change hides. Changed to `http:`.

## No portal click-ops

Read as: **the template is the only source of truth, and a redeploy is
idempotent and non-destructive.** Three things test that honestly.

**What the first what-if prevented.** Run against the original parameter file,
it wanted to modify a *live* container app — rewriting its identity and
registry, and reverting its running image to a hello-world placeholder, on a
deployment that changed nothing about the application. The subscription carries
two earlier deployments with different environment names, and the template sat
between them. Day 23 deploys to a fresh environment instead; the reasoning is in
`main.dev.bicepparam`'s own header, against what was actually observed.

**The image footgun is closed in the template, not in a habit.**
`fetch-container-image.bicep` resolves the image as: an explicitly supplied
name, else *the image the app is already running*, else the placeholder. The
idempotency run passes no image name and the image does not appear in the diff
at all.

**The firewall rule went through the template.** `create-sql-user.ps1` first
failed with *"Client with IP address '...' is not allowed to access the
server"* — the server's only rule admitted Azure services, not administrators.
The fix was a parameter and a redeploy, not `az sql server firewall-rule create`
and not a portal blade. A rule added by hand would have been invisible to the
template and reported as drift by the very next plan. The address is read from
`SQL_CLIENT_IP` rather than written into the committed file: an IP address is
personal data, and a home address changes between sessions.

### Gaps, named rather than hidden

1. **The contained SQL database user is T-SQL, and ARM has no verb for it.**
   `scripts/create-sql-user.ps1`, idempotent, run once between the
   infrastructure deploy and pushing the real image. A
   `Microsoft.Resources/deploymentScripts` resource would keep it in the
   template and needs its own managed identity, a storage account and a
   `forceUpdateTag`; judged more machinery than the gap is worth here. That is a
   trade, recorded rather than made silently.
2. **The azd image-path bug survives.** `QuotesApi.csproj` pins
   `ContainerRepository: quotes-api` while azd computes a different path, so
   `azd up` still needs one corrective `az containerapp update --image`. It is a
   packaging bug, not an infrastructure one, and bundling it into this change
   would have made both harder to review.
3. **A second, working provisioner sat beside the first.**
   `scripts/deploy-aca.ps1` creates a resource group, a Container Apps
   Environment and a container app imperatively with `az cli` — Day 5's
   approach, which `infra/` replaces. The problem was not that it was broken;
   it was that it would have worked, creating resources the template does not
   describe in a group it does not own. Two sources of truth for one set of
   infrastructure is exactly what this exercise removes, and a repository
   keeping a working imperative provisioner next to a declarative one has not
   really removed it. It now carries a header saying it is superseded and must
   not be run, and pointing at the runbook. Kept rather than deleted because
   Day 5's write-ups reference it and describe an exercise that really
   happened — deleting it would leave those documents citing a file that never
   existed. Same class of problem as the orphaned
   `Day19/infra/servicebus.bicep`, resolved the other way round because that
   one had no reader.

4. **There is a hand-created SQL server in the subscription.**
   `thinkschoolsql45921`, with a `quotesdb`, in `thinkschool-rg`. Nothing in
   this repository describes it. It is the best click-ops evidence in the
   subscription and it is not this change's to remove, but it should not go
   unmentioned in a submission about exactly this.

## What the compiler and the cloud caught that reading did not

These templates were written where no `az`, no `bicep` and no network to install
either was available. Everything below was found by a compiler or by a
deployment, not by review — which is the argument for `what-if` and a linter
turned up, rather than for more careful reading.

| | Found by | What it was |
|---|---|---|
| BCP104 | Bicep extension | `#disable-next-line` placed above the decorator instead of above the `param` line, so the suppression missed — and `no-unused-params` is an error in this repo's own `bicepconfig.json` |
| BCP427 | Bicep extension | `readEnvironmentVariable('JWT_SECRET')` one-arg form: fails at *open*, so the file is red in every editor without the variable exported |
| BCP333 | Bicep extension | the fix for the above, plus `@minLength(32)` on `main.bicep`'s parameter — Bicep validates length on a `.bicepparam` assignment at *compile* time |
| `no-hardcoded-env-urls` | `az bicep lint` | the Entra authority copied literally from `appsettings.json`; now derived from `environment().authentication.loginEndpoint`, correct in sovereign clouds |
| BCP318 | `az bicep build` | a conditional `existing` resource is `T \| null`; a ternary on `exists` is not proof the null branch is unreachable |
| `AzureAd__*` removed | first `what-if` | the template did not set them, so the plan showed them being deleted from the app — an infrastructure refactor silently breaking one of two auth schemes |
| SQL firewall | deployment | see above |
| `sp_executesql` | deployment | it takes a *variable*, never an expression; `(N'ALTER ROLE ...' + @member)` fails with an error that blames the T-SQL inside the string |
| script lied about success | deployment | `Invoke-Sqlcmd` reports T-SQL errors as non-terminating, so the script printed "Done" after three failed grants. `-ErrorAction Stop` |
| `$Default`, scale rule | idempotency what-if | see above |

The one worth generalising is BCP333: a constraint on a **pass-through**
parameter is checked at a different time, and against a different input, than
the same constraint on the parameter that **consumes** the value. `@minLength(32)`
now lives on `modules/api.bicep`, where the key is used; ARM enforces it at
deployment, before a single resource is touched. Fail at deploy, not at open.

## What was not done

- **The real QuotesApi image was not pushed.** The container app runs the
  hello-world placeholder. Pushing it needs Docker or an equivalent, which was
  not available; the infrastructure is what this exercise asked for, and half a
  deployment described as a whole one would be worse than this sentence.
- **prod was not deployed.** `what-if` only.
- **Key Vault.** The `@secure()` parameter is the interim answer; a vault with a
  `secretRef` is the follow-up this implies.
- **Private endpoints.** `sqlPublicNetworkAccess` stays `Enabled` with firewall
  rules in both files. `Disabled` needs a VNet-integrated Container Apps
  environment that this subscription's quota does not permit, so writing it
  would describe infrastructure that cannot exist and has never been tested.
- **CI's solution path.** Still `Day5/piece2` for the .NET jobs. A Bicep
  build/lint/build-params job was added pointing at `Day7/piece2/infra`; moving
  the .NET jobs is its own change.

## Evidence

| File | What it is |
|---|---|
| `../verification/build-and-lint.txt` | Compile and lint, clean, and the three compiler errors that preceded it |
| `../verification/what-if-dev.txt` | The plan: 15 to create, 0 to modify, 0 to delete |
| `../verification/deploy-dev.txt` | The deployment record |
| `../verification/deploy-dev-summary.txt` | What the run settled that reading could not |
| `../verification/create-sql-user.txt` | The contained user and its three role grants |
| `../verification/idempotency-second-what-if.txt` | The plan after the deployment |
| `../verification/idempotency-analysis.txt` | All 6 remaining modifies, attributed line by line |
