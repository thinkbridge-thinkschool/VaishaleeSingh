# Day 23 — Bicep IaC

## Task, as given

> Describe your infra as code. Author Bicep modules (parameterized) for the API,
> SQL, and Service Bus, with separate dev/prod parameter files. No portal
> click-ops.

## Exercise, as given

> Paste the Bicep modules + the dev/prod parameter files, and show the same
> template deploying both environments without a portal edit.

---

## 1. What the task is actually asking for

Four things, and the last one is the one that fails silently if ignored.

1. **Modules** — not one file. `infra/resources.bicep` today is a 13 KB flat
   file holding every resource this application uses. The deliverable is a set
   of single-responsibility modules with declared inputs and outputs.
2. **Parameterized** — a module that hardcodes `Standard`, `PT1M`, `minReplicas: 1`
   or a resource name is not parameterized, it is a copy waiting to be forked.
   The test: could `prod` be produced from the same module by changing only a
   parameter file?
3. **Separate dev/prod parameter files** — the environments differ in the file
   that carries values, not in the file that carries logic. Two parameter files,
   one template graph.
4. **No portal click-ops** — the honest reading is not "don't open the portal",
   it is **the template is the only source of truth, and a redeploy is
   idempotent and non-destructive**. Any resource that exists because a human
   clicked it, or any post-deploy `az` command the deployment depends on, is a
   gap that must be either closed in Bicep or written down as a known gap with
   the reason. This repo already has two of those, named in §3.

What the task does **not** ask for: a live prod subscription, a new application
feature, or a CI/CD redesign. Day 23 is infrastructure description. A `what-if`
against a real subscription is sufficient proof for the environment that is not
actually being paid for.

---

## 2. Starting point — verified, not assumed

Checked against the repo at `main` (`e9dfc26`, Day 22 merged):

| Path | What it is | Verdict for Day 23 |
|---|---|---|
| `Day7/piece2/azure.yaml` | azd service definition, `host: containerapp` | Keep; azd is the deploy driver |
| `Day7/piece2/infra/main.bicep` | `targetScope = 'subscription'`, creates `thinkschool-azd-rg`, calls one module | Keep the shape, change what it calls |
| `Day7/piece2/infra/resources.bicep` | Everything else in one file: Log Analytics, App Insights, ACR, an **existing** Container Apps Environment, a user-assigned identity, an AcrPull role assignment, the Container App | **This is the thing being decomposed** |
| `Day7/piece2/infra/main.parameters.json` | azd token substitution (`${AZURE_ENV_NAME}` etc.) | Keep — azd reads only this file |
| `Day7/piece2/infra/abbreviations.json` | 6 abbreviations, `loadJsonContent`ed | Extend, don't replace |
| `Day19/infra/servicebus.bicep` | Namespace, topic, 2 subscriptions, filter rules, 3 role assignments — well written and heavily commented | **Orphaned.** Nothing references it. It is not called from `main.bicep` and does not live under `Day7/piece2/infra/` |

Three facts that shape the whole day:

- **There is no SQL infrastructure anywhere in this repo.** `grep` for
  `Microsoft.Sql` returns nothing. The app runs SQLite locally
  (`ConnectionStrings:DefaultConnection = "Data Source=quotes.db"`), SQL Server
  in Testcontainers, and — in Azure — nothing at all. The Container App in
  `resources.bicep` sets `Jwt__*` and `ApplicationInsights__ConnectionString`
  and no connection string. So the SQL module is **new**, and wiring it is the
  first time the deployed app has a real database.
- **The Service Bus module already exists but is not wired.** Day 19 wrote it
  for the topology exercise and stopped there. Day 23 is where it becomes part
  of the deployment graph, which means parameterizing what Day 19 hardcoded
  (`sku`, `P7D`, `PT1M`, `maxDeliveryCount: 3`, `quotes-${env}`).
- **The Container App carries a literal JWT secret in source control.**
  `resources.bicep` sets `value: 'Vaishalee-A41105222049-QuotesApiJwt2026'` on a
  Container Apps secret, with a comment acknowledging it. A parameter file split
  is exactly the moment this becomes untenable: it must not be duplicated into
  two parameter files. See §6, trap 6.

---

## 3. The two existing click-ops gaps, stated up front

Both are documented in `Day7/piece2/docs/azd-deployment.md` and both must be
addressed — closed or explicitly declared — for the "no portal click-ops" claim
to be true rather than decorative.

- **The Container Apps Environment is `existing`, in another resource group,
  created outside this template.** The comment explains why: the subscription
  allows one environment per region (`MaxNumberOfRegionalEnvironmentsInSubExceeded`)
  and `thinkschool-env` in `thinkschool-rg` already occupies `centralindia`.
  That is a real constraint, not sloppiness. The Day 23 answer: keep the
  `existing` reference but make it a **parameter pair**
  (`containerAppsEnvironmentName`, `containerAppsEnvironmentResourceGroup`) with
  a `createContainerAppsEnvironment bool` switch, so dev reuses the shared one
  and the prod parameter file describes a dedicated one the template would
  create if the quota allowed. The constraint is then in the parameter file,
  where constraints belong, not welded into the module.
- **Every `azd up` needs a corrective
  `az containerapp update --image <endpoint>/quotes-api:<tag>`** because the
  csproj pins `ContainerRepository: quotes-api` and azd computes a different
  path. This is a post-deploy imperative step the deployment depends on — the
  definition of the thing the task forbids. Either fix the image path so the
  template is self-sufficient, or state it in the submission as a known,
  reproduced gap with the reason. Do not quietly leave it out.

---

## 4. Recommended approach

### 4.1 Where the work lands

In `Day7/piece2/infra/`, in place. Not a new copy of the app.

`Day7/piece2` has been the current tree since Day 13 and every day since has
added to it rather than copying it forward (README, "The application"). Day 23
follows that. `Day23/` holds only the documents and the verification evidence,
the same shape Day 19–21 used.

Day 19's `Day19/infra/servicebus.bicep` is **moved** into the module tree, not
copied — leaving two divergent Service Bus templates in one repo is the failure
mode this whole exercise is about. Leave a one-line pointer in `Day19/infra/`.

### 4.2 Target layout

```
Day7/piece2/infra/
  main.bicep                      # subscription scope: RG + module orchestration
  main.parameters.json            # UNCHANGED — azd's only entrypoint
  main.dev.bicepparam             # the dev parameter file
  main.prod.bicepparam            # the prod parameter file
  abbreviations.json
  bicepconfig.json                # linter rules, ruleset turned up
  modules/
    monitoring.bicep              # Log Analytics + Application Insights
    registry.bicep                # Container Registry
    identity.bicep                # user-assigned MI + AcrPull role assignment
    api.bicep                     # Container App (the API)
    sql.bicep                     # Azure SQL logical server + database
    servicebus.bicep              # namespace, topic, subscriptions, rules, RBAC
```

Seven modules, not three. The task names three because those are the three that
carry real parameterization; monitoring, registry and identity are extracted in
the same pass because leaving them inline in `main.bicep` would just be a
smaller monolith. Say this in the submission rather than letting a reader
wonder why the count differs.

### 4.3 Parameter files — the decision that needs stating

Bicep has two parameter mechanisms and they are not interchangeable:

| | `.bicepparam` | `main.parameters.json` |
|---|---|---|
| Typed against the template | Yes (`using './main.bicep'`) | No |
| Compile-time error on a typo | Yes | No — silently ignored |
| Read by `az deployment sub create -p` | Yes | Yes |
| Read by `azd` | **No** | Yes, with `${TOKEN}` substitution |

**The approach: deliver both, and be explicit about which drives what.**
`main.dev.bicepparam` and `main.prod.bicepparam` are the exercise deliverable and
the typed, checkable artifacts — they are what `what-if` runs against.
`main.parameters.json` stays exactly as it is so `azd up` keeps working, and it
resolves the environment-shaped values from `AZURE_ENV_NAME`.

Writing `.bicepparam` files and then claiming `azd` uses them is the mistake
this table exists to prevent. Verify it: `azd` ignores them.

Keep the *number* of parameters that differ between dev and prod small and
meaningful. A parameter that has the same value in both files is a parameter
with a default, not a parameter.

### 4.4 What actually differs between dev and prod

Design the module signatures from this table, not the other way round.

| Parameter | dev | prod | Why it is a parameter |
|---|---|---|---|
| `environmentType` | `dev` | `prod` | `@allowed(['dev','prod'])`; drives tags and guards |
| `location` | `centralindia` | `centralindia` | Same today; still a parameter |
| **API** | | | |
| `apiMinReplicas` | `0` | `2` | Scale-to-zero is a dev cost decision and a prod availability bug |
| `apiMaxReplicas` | `2` | `10` | |
| `apiCpu` / `apiMemory` | `0.5` / `1Gi` | `1.0` / `2Gi` | |
| `apiConcurrentRequests` | `50` | `50` | |
| `createContainerAppsEnvironment` | `false` (reuse `thinkschool-env`) | `true` | §3 |
| **SQL** | | | |
| `sqlSkuName` | `GP_S_Gen5_1` (serverless) | `GP_Gen5_2` | Serverless auto-pause is right for dev, wrong for prod |
| `sqlAutoPauseDelayMinutes` | `60` | `-1` (disabled) | Only meaningful on serverless |
| `sqlMaxSizeBytes` | 2 GB | 32 GB | |
| `sqlBackupRedundancy` | `Local` | `Geo` | |
| `sqlPublicNetworkAccess` | `Enabled` + AzureServices rule | `Disabled` | The one that will bite; see trap 8 |
| `sqlZoneRedundant` | `false` | `true` | |
| **Service Bus** | | | |
| `serviceBusSku` | `Standard` | `Premium` | Topics need Standard minimum (Day 19 comment) |
| `messageTimeToLive` | `P1D` | `P7D` | |
| `maxDeliveryCount` | `3` | `5` | |
| `lockDuration` | `PT1M` | `PT1M` | |
| **Observability** | | | |
| `logRetentionInDays` | `30` | `90` | |
| `dailyQuotaGb` | `1` | `-1` (uncapped) | A dev quota cap is a cost guard; in prod it drops telemetry |

### 4.5 Module contracts

Write the interface first, the resources second. Each module: `@description` on
every parameter, `@allowed` on every enum-shaped one, `@minValue`/`@maxValue`
where a range exists, and outputs limited to what a caller needs.

**`modules/api.bicep`** — `targetScope = 'resourceGroup'`
- In: `name`, `location`, `tags`, `containerAppsEnvironmentId`,
  `userAssignedIdentityId`, `containerRegistryLoginServer`, `imageName`,
  `minReplicas`, `maxReplicas`, `cpu`, `memory`, `concurrentRequests`,
  `targetPort`, `env array` (the caller composes the environment variables),
  `secrets array` (Key Vault references, `@secure()` never inline).
- Out: `fqdn`, `name`, `principalId`.
- The `env` array is a parameter, not built inside the module. That is what
  keeps the module reusable and keeps the connection string / App Insights /
  Service Bus wiring visible in `main.bicep` where the graph is readable.

**`modules/sql.bicep`** — new
- In: `serverName`, `databaseName`, `location`, `tags`, `skuName`, `skuTier`,
  `maxSizeBytes`, `zoneRedundant`, `autoPauseDelay`, `backupStorageRedundancy`,
  `publicNetworkAccess`, `allowAzureServices bool`,
  `entraAdminObjectId`, `entraAdminLogin`, `appPrincipalId`, `appPrincipalName`.
- Out: `serverFqdn`, `databaseName`, and a **connection string with no secret in
  it**: `Server=tcp:<fqdn>,1433;Database=<db>;Authentication=Active Directory Default;Encrypt=True;`
- **Entra-only authentication.** Set `administrators.azureADOnlyAuthentication: true`
  and do not declare a `administratorLoginPassword` at all. This removes the
  single hardest problem in the exercise — a secret that would otherwise have to
  live in two parameter files — rather than solving it. The app already carries
  `DefaultAzureCredential` (Day 19's Service Bus wiring), so the pattern is
  established, not invented.
- The honest gap: **Bicep cannot create the contained database user.**
  `CREATE USER [<app-identity>] FROM EXTERNAL PROVIDER; ALTER ROLE db_datareader ...`
  is T-SQL and runs after the deployment. Options, in order of preference:
  a `Microsoft.Resources/deploymentScripts` resource running `sqlcmd` (keeps it
  in the template), or a documented script in `Day7/piece2/scripts/`. Pick one,
  and if it is the script, say so in the submission — this is a click-ops-adjacent
  step and hiding it would undercut the whole claim.

**`modules/servicebus.bicep`** — parameterized lift of Day 19
- In: `namespaceName`, `location`, `tags`, `skuName`, `topicName`,
  `defaultMessageTimeToLive`, `subscriptions array` (each: `name`,
  `maxDeliveryCount`, `lockDuration`, `sqlFilter string?`), `appPrincipalId`.
- Out: `namespaceFqdn`, `topicName`, subscription names.
- Keep every one of Day 19's comments. They are load-bearing — particularly the
  `$Default` TrueFilter overwrite (`1=0`), which is the single most common
  "my filter does nothing" bug and is already correctly solved there. Do not
  regress it while making the subscription list a loop.
- Making subscriptions a loop with an optional filter changes the rule
  resources from two named resources into a conditional nested loop. This is
  the trickiest refactor of the day; if the loop obscures the `$Default`
  handling, prefer keeping the two subscriptions explicit and parameterizing
  only their tuning values. Clarity beats generality here — say which you chose
  and why.

### 4.6 Sequencing

1. Branch off an up-to-date `main`: `day23-bicep-iac`.
2. `bicepconfig.json` first, linter turned up — it will flag things during the
   refactor rather than after.
3. Extract `monitoring`, `registry`, `identity` from `resources.bicep`. Build
   after each. These are mechanical and de-risk the rest.
4. Extract `api`. This is where `env`/`secrets` become parameters.
5. Move and parameterize `servicebus`. Wire it into `main.bicep` and into the
   API's env array (`ServiceBus__FullyQualifiedNamespace`, `ServiceBus__Enabled`).
6. Write `sql` from scratch. Wire `ConnectionStrings__DefaultConnection` into
   the API's env array.
7. Write both `.bicepparam` files.
8. Delete `resources.bicep` — only once `main.bicep` no longer references it and
   `what-if` shows no unintended deletions.
9. Verification pass (§7).
10. PR into `main`, CI green.

---

## 5. Where the app meets the infrastructure

The infrastructure is only correct if the app reads what it sets. Environment
variables use `__` for `:` (already established in `resources.bicep`). These
must match `Day7/piece2/QuotesApi/appsettings.json` exactly:

| Env var the template sets | Config key | Source |
|---|---|---|
| `ConnectionStrings__DefaultConnection` | `ConnectionStrings:DefaultConnection` | `sql` module output |
| `ServiceBus__Enabled` | `ServiceBus:Enabled` | `true` once wired |
| `ServiceBus__FullyQualifiedNamespace` | `ServiceBus:FullyQualifiedNamespace` | `servicebus` output |
| `ServiceBus__TopicName` | `ServiceBus:TopicName` | `servicebus` output |
| `ServiceBus__AuditSubscription` | `ServiceBus:AuditSubscription` | `servicebus` output |
| `ServiceBus__SearchIndexSubscription` | `ServiceBus:SearchIndexSubscription` | `servicebus` output |
| `Outbox__RelayEnabled` | `Outbox:RelayEnabled` | `true` in the deployed app |
| `ApplicationInsights__ConnectionString` | `ApplicationInsights:ConnectionString` | `monitoring` output |
| `Jwt__Secret` | `Jwt:Secret` | Key Vault `secretRef` — see trap 6 |

One live check worth doing before writing the SQL module:
`InfrastructureExtensions.cs` selects `UseSqlServer` vs `UseSqlite` from the
connection string. Confirm what it keys off, because an Entra connection string
with no `Data Source=` prefix must land on the SQL Server branch.

---

## 6. Traps

1. **`.bicepparam` is invisible to azd.** §4.3. Two mechanisms, both delivered,
   neither pretending to be the other.
2. **Moving a resource between modules can mean delete-then-create.** ARM keys
   on resource name and type, not module path, so a pure move is a no-op — but
   any incidental rename is a destroy. `what-if` before every merge, and read
   the `Delete` lines specifically.
3. **`guid()` inputs decide idempotency of role assignments.** Change what you
   feed `guid()` and the next deploy creates a second assignment instead of
   recognising the first. Keep the existing seeds (`containerRegistry.id`,
   identity id, `'AcrPull'`) byte-identical through the refactor.
4. **Role assignment scope must be reachable from the module that declares it.**
   `scope:` needs a symbolic reference in the same file. Either the RBAC lives
   with the resource it grants on (preferred), or the module takes the resource
   id and uses `existing`.
5. **Never `output` a connection string or key.** Already noted in
   `resources.bicep`: azd writes outputs to `.azure/<env>/.env` and `.azure` is
   not gitignored in this repo. The SQL connection string output is safe only
   because it contains no credential. Check that this stays true.
6. **The literal JWT secret must not be duplicated into two parameter files.**
   The right move is a Key Vault + `secretRef` with the Container App's identity
   granted `Key Vault Secrets User`, with the secret value supplied out of band
   (`az keyvault secret set`) and never in the repo. If that is too large for
   one day, the fallback is a single `@secure()` parameter supplied at deploy
   time — and the parameter files carry no value for it. What is *not*
   acceptable is copying the literal into `main.dev.bicepparam` and
   `main.prod.bicepparam`.
7. **Service Bus Basic has no topics.** Day 19 already documents this. Guard it:
   `@allowed(['Standard','Premium'])` on the sku parameter makes it unrepresentable.
8. **`sqlPublicNetworkAccess: 'Disabled'` in prod locks out the API too**
   unless a private endpoint or VNet-integrated Container Apps environment
   exists. Since prod is `what-if` only, either scope prod to
   `Enabled` + firewall rules and say why, or add the private endpoint and
   state that it is unverified. Do not write `Disabled` and imply it was tested.
9. **`autoPauseDelay` is invalid on non-serverless SKUs.** Guard it with a
   conditional expression on the tier rather than passing `-1` blindly.
10. **A `deploymentScripts` resource needs a managed identity and a storage
    account**, and it re-runs on every deployment unless `forceUpdateTag` is
    held constant. If the SQL user creation goes this route, make the T-SQL
    idempotent (`IF NOT EXISTS`).
11. **CI does not build this.** `.github/workflows/ci.yml` still points at
    `Day5/piece2` (README, "Working in this repo"). A Bicep build/lint job added
    to CI is small and makes the template's correctness continuously checked
    rather than checked once. Worth doing in this PR.

---

## 7. Verification — what proves it

Local, no subscription needed:

```bash
cd Day7/piece2
az bicep build --file infra/main.bicep --stdout > /dev/null   # compiles
az bicep lint  --file infra/main.bicep                        # zero warnings
az bicep build-params --file infra/main.dev.bicepparam        # dev params typecheck
az bicep build-params --file infra/main.prod.bicepparam       # prod params typecheck
```

`build-params` is the step that proves the parameter files match the template.
A JSON parameter file would pass a typo here; a `.bicepparam` will not.

Against a subscription:

```bash
az deployment sub what-if \
  --location centralindia \
  --template-file infra/main.bicep \
  --parameters infra/main.dev.bicepparam

# and, to show one template drives both, with no portal edit between them:
az deployment sub what-if \
  --location centralindia \
  --template-file infra/main.bicep \
  --parameters infra/main.prod.bicepparam
```

Then the claim the exercise actually asks for — **idempotency**:

```bash
az deployment sub create -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
az deployment sub what-if  -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

The second command must report **no changes**. A `what-if` that still shows
modifications after a successful deploy means something in the template is not
describing the resource it created — the exact condition under which someone
eventually "just fixes it in the portal".

Evidence to capture into `Day23/verification/`:

- `build-and-lint.txt` — the four local commands, unedited
- `what-if-dev.txt`, `what-if-prod.txt` — the two plans side by side
- `idempotency-second-what-if.txt` — the "no changes" run
- `deploy-dev.txt` — the real deployment output
- Screenshots of the deployed resources under `verification/screenshots/`
- `az resource list -g thinkschool-azd-rg -o table` — what exists, matching
  what the template declares

---

## 8. Deliverables

- [ ] `Day7/piece2/infra/modules/{monitoring,registry,identity,api,sql,servicebus}.bicep`
- [ ] `Day7/piece2/infra/main.bicep` rewritten as orchestration only
- [ ] `Day7/piece2/infra/main.dev.bicepparam`, `main.prod.bicepparam`
- [ ] `Day7/piece2/infra/bicepconfig.json`
- [ ] `Day7/piece2/infra/resources.bicep` deleted
- [ ] `Day19/infra/servicebus.bicep` moved, with a pointer left behind
- [ ] `Day23/docs/day23-bicep-iac-implementation-plan.md` — written **before**
      the code, kept as written, with a banner at the top listing what came out
      differently (the Day 21 convention)
- [ ] `Day23/docs/day23-bicep-iac-submission.md` — the answer, including the
      dev/prod diff table, the idempotency proof, and the click-ops gaps from §3
      stated plainly rather than omitted
- [ ] `Day23/verification/*` — §7
- [ ] Bicep build/lint job in `.github/workflows/ci.yml`
- [ ] Branch `day23-bicep-iac`, PR into `main`, CI green

---

## 9. Out of scope

Private endpoints and VNet integration beyond what trap 8 requires; a Key Vault
build-out beyond the single JWT secret; Redis (Day 21's cache is off in the
deployed app and turning it on is its own change); migrating the CI solution
path from `Day5/piece2` to `Day7/piece2` (worth doing, separate change);
multi-region. Name each of these in the submission as a deliberate exclusion so
a reader can tell a decision from an oversight.

## 10. The standard this is held to

The Day 19 Service Bus template is the bar: every non-obvious choice carries the
reason it was made, and the comments explain the trap rather than the syntax.
Bicep that reads like generated ARM is not the deliverable. A reader who has
never seen this repo should be able to open `modules/sql.bicep` and understand
why authentication is Entra-only without asking anyone.
