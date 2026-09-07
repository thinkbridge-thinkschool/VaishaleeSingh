# Day 23 — deployment runbook

The order matters. Two steps in this sequence cannot be reordered without
producing an app that starts and then fails its readiness probe.

Everything below targets a **fresh environment** — `thinkschool-day23` in
`thinkschool-day23-rg`. Nothing already deployed is modified. Why that was
chosen rather than adopting an existing deployment is in the header of
`main.dev.bicepparam`, written against what the first what-if actually showed.

## 0. Once, before anything

```powershell
cd C:\thinkschool\Day7\piece2

az ad signed-in-user show --query userPrincipalName -o tsv
```

Put that UPN into `infra/main.dev.bicepparam` as `sqlEntraAdminLogin`. It ships
as `REPLACE-WITH-YOUR-UPN` on purpose: a placeholder that fails is better than a
plausible wrong value that succeeds and leaves a server nobody can administer.

```powershell
$env:JWT_SECRET = '<at least 32 characters, NOT the one that was committed>'
```

The literal that used to sit in `resources.bicep` is in this repository's git
history. It is fine for a compile and must not be what reaches a deployment.

## 1. Compile

```powershell
az bicep build        --file infra/main.bicep --stdout > $null
az bicep lint         --file infra/main.bicep
az bicep build-params --file infra/main.dev.bicepparam  --stdout > $null
az bicep build-params --file infra/main.prod.bicepparam --stdout > $null
```

Silence is a pass.

## 2. Plan

```powershell
az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

Read three things specifically, not the whole diff:

- **Any `-` Delete lines.** There should be none. This is a fresh environment,
  so everything is `+ Create`.
- **The container app's `image`.** It will be the hello-world placeholder, and
  that is correct here: no image has been pushed to this environment's registry
  yet. On every *later* deployment it must never revert to the placeholder —
  `modules/fetch-container-image.bicep` is what prevents that, and step 6 is
  where it gets proven.
- **Three `Unsupported` diagnostics on the Service Bus role assignments.** Not
  errors. What-if cannot evaluate an extension resource whose ID depends on a
  `reference()` resolved during deployment; the AcrPull assignment appears
  separately under "MAY OR MAY NOT be deployed" for the same reason.

## 3. Deploy the infrastructure

```powershell
az deployment sub create -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

The container app comes up on the placeholder image. **This is deliberate.** The
app is not running yet, so it cannot fail against a database it has no login
for — which is the failure the next step exists to prevent.

## 3b. Let your own machine through the SQL firewall

The server's only other rule is `AllowAzureServices`, which admits the container
app and nobody else. The next step connects as a *person*, so it needs one more:

```powershell
$env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
az deployment sub create -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

`sqlAllowedClientIpAddresses` in `main.dev.bicepparam` reads that variable, and
an unset variable adds no rule at all — which is the right default for anything
that is not a workstation doing administration right now.

The IP is deliberately not written into the parameter file. It is personal data
in a committed file, and a home address changes between sessions.

This step is a small demonstration of the whole exercise: the first attempt at
step 4 failed with *"Client with IP address '...' is not allowed to access the
server"*, and the fix was a parameter and a redeploy rather than
`az sql server firewall-rule create` or a portal blade. A rule added by hand
would be invisible to the template and reported as drift by the idempotency
check in step 6 — or silently reverted by it.

## 4. Create the SQL user — BEFORE the real image

```powershell
./scripts/create-sql-user.ps1 `
    -SqlServerFqdn (az deployment sub show -n main --query properties.outputs.azurE_SQL_SERVER_FQDN.value -o tsv) `
    -DatabaseName  (az deployment sub show -n main --query properties.outputs.azurE_SQL_DATABASE_NAME.value -o tsv) `
    -IdentityName  (az deployment sub show -n main --query properties.outputs.servicE_QUOTES_API_IDENTITY_NAME.value -o tsv)
```

**That casing is not a typo.** ARM camel-cases the first segment of every output
name, so the `AZURE_SQL_SERVER_FQDN` declared in `main.bicep` comes back as
`azurE_SQL_SERVER_FQDN`, and `SERVICE_...` as `servicE_...`. JMESPath is
case-sensitive, so querying the name as written in the template returns null and
the script silently receives an empty parameter. Corrected against the real
deployment output; the first version of this runbook had it wrong.

**This step cannot move.** `sql.bicep` provisions an Entra-only server, which
gets the managed identity to the server but gives it no user inside the
database. Deploy the real image first and the app starts, tries to reach SQL,
gets `Login failed for user '<token-identified principal>'`, and fails
`/health/ready` — an app that is up and permanently unready.

Run it as the account named in `sqlEntraAdminLogin`. Anyone else gets a
permission error, which is the Entra-only design working rather than a fault.

## 5. Build and push the real image

```powershell
azd env new thinkschool-day23
azd env set AZURE_LOCATION centralindia
azd env set JWT_SECRET '<the same key as above>'
azd env set AZURE_PRINCIPAL_ID (az ad signed-in-user show --query id -o tsv)
azd deploy
```

`azd` reads `main.parameters.json`, never the `.bicepparam` files. It resolves
`JWT_SECRET` and `AZURE_PRINCIPAL_ID` from the environment variables set above.

Known gap, carried over and not fixed here: `QuotesApi.csproj` pins
`ContainerRepository: quotes-api` while azd computes a different path, so a
working deployment still needs one corrective
`az containerapp update --image <endpoint>/quotes-api:<tag>` afterwards. It is a
packaging bug, not an infrastructure one — see
`day23-bicep-iac-implementation-plan.md`, item 5.

## 6. Prove idempotency, and prove the image is safe

```powershell
az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
```

Two claims land on this one command:

- **No changes.** A template that still shows drift against resources it just
  created is the condition under which somebody eventually fixes it in the
  portal — the thing this exercise forbids.
- **The image is not reverted.** This run passes no image name, so a naive
  template would show the running image being replaced by the placeholder. It
  must show the image unchanged.

Save the output to `Day23/verification/idempotency-second-what-if.txt`.

## 7. Plan prod

```powershell
az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.prod.bicepparam
```

Plan only, never deployed. It will show a dedicated Container Apps Environment
that this subscription's one-per-region quota does not permit, and a SQL admin
object ID that is still a placeholder. Both are stated in the file's own header
rather than dressed up.

## Tearing it down

```powershell
az group delete -n thinkschool-day23-rg --yes
```

The Container Apps Environment is *referenced*, not created, so it is not
deleted — correct, since this deployment does not own it.
