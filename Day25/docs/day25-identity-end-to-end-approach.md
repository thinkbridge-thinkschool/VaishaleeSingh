# Day 25 — Identity end-to-end

**Task.** No connection-string secrets anywhere. Managed Identity for the
API→SQL and API→Service Bus paths, Entra ID for app auth, Key Vault references
for any remaining config. Prove there are zero secrets in app settings.

## Where this starts, measured rather than assumed

Day 23 and Day 24 already did most of the identity work, so the honest shape of
Day 25 is narrower than the task statement suggests. What follows was read out
of the code and the templates on this branch, not remembered:

| Path | Mechanism today | Verdict |
|---|---|---|
| API → SQL | `Authentication=Active Directory Default;User Id=<MI client id>`; server is `azureADOnlyAuthentication`; contained DB user created by `scripts/create-sql-user.ps1` | already passwordless |
| API → Service Bus | `AddServiceBusClientWithNamespace(...).WithCredential(new DefaultAzureCredential())`; namespace sets `disableLocalAuth: true`; Sender + two Receiver role assignments | already passwordless |
| API/Web → ACR | pull via the user-assigned managed identity on both container apps | already passwordless |
| GitHub Actions → Azure | OIDC federated credentials, no stored service principal secret | already passwordless |
| App auth | `EntraId` JwtBearer scheme already exists beside the legacy `CustomJwt` one, routed by `AddPolicyScheme` on the `aud` claim | half done |
| Key Vault | `builder.Configuration.AddAzureKeyVault(uri, DefaultAzureCredential)` already in `Program.cs`, conditional on `KeyVault:Uri` | code ready, no vault exists |

The two data-plane paths the task names are therefore **not** the work. They are
the thing to *assert*, because an assertion that passes on the first run is
still worth writing — it stops a later change from silently undoing them.

### The four real gaps

1. **`Jwt__Secret` is a live inline Container Apps secret.** It arrives as a
   `@secure()` Bicep parameter, which arrives from `JWT_SECRET` in the
   operator's azd `.env` — in plaintext, on a laptop — and an older literal is
   already in this repository's git history. This is the only true secret in
   app settings.
2. **There is no Key Vault.** `infra/modules/` holds nine files and none of them
   is a vault, so the config provider in `Program.cs` has never had a URI to
   read.
3. **Application Insights accepts ingestion keys.** `modules/monitoring.bicep`
   never sets `DisableLocalAuth`, so the `APPLICATIONINSIGHTS_CONNECTION_STRING`
   sitting in app settings is not an address — it is a working credential.
4. **The container registry has an admin user.** `modules/registry.bicep`
   declares `param adminUserEnabled bool = true` and `main.bicep` never
   overrides it. Nothing uses it; both apps pull with a managed identity. A
   username and password that no component depends on and no one is watching is
   the worst kind of credential to leave enabled.

And one latent defect worth fixing while the file is open: **`AZURE_CLIENT_ID`
is never set on the container app.** The SQL connection string names the
identity explicitly via `User Id=`, but the Key Vault provider and the Service
Bus client do not. `DefaultAzureCredential` resolves correctly today only
because exactly one identity is attached. Add a system-assigned identity later —
or a second user-assigned one — and every credential in the process starts
guessing, which surfaces as an authorization failure that reads like a missing
role assignment.

## The principle this follows

"No secrets in app settings" is a weak claim if the resource still *accepts*
secrets. Absence of a credential is a fact about today; refusal of credentials
is a fact about the deployment. So each remaining value is handled in this
order, and Key Vault is the last resort rather than the goal:

1. **Eliminate.** Turn off the secret-based auth path at the resource
   (`disableLocalAuth`, `azureADOnlyAuthentication`, `adminUserEnabled: false`).
   The secret stops existing, and a credential pasted into configuration
   tomorrow would not work.
2. **Demote.** Where the value has to stay in configuration, disable local auth
   so it degrades from credential to identifier. This is exactly what happens to
   the App Insights connection string: same string, no longer a key.
3. **Vault.** Only what is genuinely left. A vaulted secret is still a secret
   with a blast radius — it has moved, not gone.

## Decisions taken

- **Entra app registration moves to the Amity tenant.** It currently lives in
  the old tenant (`91566dbd-…`) while the subscription and every managed
  identity live in Amity. Token validation is an HTTPS call to an authority URL
  and works cross-tenant, so this is not broken — but it makes a decommissioned
  directory a permanent dependency, and "identity end-to-end" spanning two
  tenants for no reason is hard to defend. A public-client SPA plus a resource
  API is pure PKCE, so no client secret is introduced by doing this.
- **The custom JWT scheme is vaulted now and retired later.** Retiring it is the
  correct fix and would delete the signing key outright, but it means migrating
  the SPA to MSAL and rewriting sign-in, the `Users` table relationship and
  refresh tokens. That is its own day. Deferring it is recorded here as a
  decision, not left to look like an oversight.
- **App Insights disables local auth rather than vaulting its connection
  string.** Vaulting it would store a working ingestion credential more
  carefully; disabling local auth stops it being a credential.

## Phases

### Phase 0 — record the baseline (do this first)

Run `Day25/scripts/00-prove-no-secrets.ps1 -Baseline` against the environment as
Day 24 left it. It is **expected to fail**, on the four gaps above. The output
lands in `Day25/verification/no-secrets-BEFORE.txt`.

This ordering is the point. A check that has only ever passed proves nothing
about whether it can fail, and the submission asks for proof. Two files showing
named findings going from red to green is evidence; one green screenshot is an
assertion.

### Phase 1 — eliminate (cheap, highest value)

- `adminUserEnabled: false` in `registry.bicep`, passed explicitly from
  `main.bicep` so the default can never drift back.
- `DisableLocalAuth: true` on the App Insights component; add
  `Credential = new DefaultAzureCredential()` to the `UseAzureMonitor()` call;
  grant the managed identity **Monitoring Metrics Publisher** on the component.
- Set `AZURE_CLIENT_ID` on the API container app so every credential in the
  process resolves the same identity.
- Assert — do not assume — that SQL is still Entra-only and Service Bus still
  has local auth off. Phase 0's script already does this.

### Phase 2 — vault what is left

- New `modules/keyvault.bicep`: `enableRbacAuthorization: true`, no access
  policies, soft-delete on, **purge protection off in dev** (see traps).
- Grant the app's user-assigned identity **Key Vault Secrets User**, scoped to
  the vault.
- **The secret value never passes through the template.** Create it once with
  `az keyvault secret set` as the operator; Bicep references only the URI. Then
  delete the `jwtSecret` `@secure()` parameter, the `JWT_SECRET` entry in
  `main.parameters.json`, and the value from the azd `.env`. A `@secure()`
  parameter is not logged, but it still travels through a shell, a CI runner and
  the deployment API; a vault reference never leaves the vault.
- The Container Apps secret becomes a reference —
  `{ name: 'jwt-secret', keyVaultUrl: '<vaultUri>secrets/jwt-secret', identity: <MI resource id> }` —
  and `Jwt__Secret` keeps its existing `secretRef`, so no application code
  changes.
- **Rotate the value in the same change.** The current one is compromised by its
  own git history, and a cutover is the moment to invalidate outstanding tokens
  rather than carry them across.

### Phase 3 — Entra registration in the tenant that owns the subscription

Register the API and a public-client SPA in the Amity tenant, expose an API
scope, and update `AzureAd__Authority`, `AzureAd__ClientId`, `AzureAd__TenantId`
and `AzureAd__Audience`. The `CustomJwt` scheme keeps working throughout — the
SPA has no MSAL today and this phase does not add it.

### Phase 4 — the proof

Re-run `00-prove-no-secrets.ps1` with no `-Baseline`. Exit code is the proof;
`no-secrets-AFTER.txt` is the artefact. Then smoke-test the API, because zero
secrets achieved by breaking the application is not a pass.

## Traps, stated before they are hit

**Purge protection collides with Day 24's teardown.** `actionOnUnmanage` is
`deleteAll`. A purge-protected vault reserves its name for up to 90 days after
deletion, so the next `az stack sub create` fails on a name it cannot reuse.
Dev: soft-delete only, and add `az keyvault purge` to the teardown path. Prod:
protection on.

**Ordering, and Bicep will not infer it.** A revision that references a Key
Vault secret fails to provision if the role assignment is not already in place,
and the dependency does not flow through a role assignment implicitly. Explicit
`dependsOn`, plus tolerance for roughly 30 seconds of RBAC propagation — expect
the first deployment after Phase 2 to need one retry, and do not read that retry
as a broken template.

**`denySettings` will object again.** Day 24's `denyDelete` with
`applyToChildScopes: true` already deadlocked once, on the stack's own cleanup
of a superseded SQL firewall rule. A vault and two more role assignments are two
more child scopes under the same deny assignment. Assume the same class of
failure on the first teardown rather than being surprised by it.

**The instrumentation key is a two-state value.** Before Phase 1 it is a
credential; after Phase 1 the identical string is an address. The proof script
judges it against the component's `DisableLocalAuth` rather than against the
string, which is why the same env var can legitimately be a FAIL on Monday and a
PASS on Tuesday with no change to app settings.
