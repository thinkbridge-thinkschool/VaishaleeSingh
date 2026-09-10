# Day 25 — Identity end-to-end

**Task.** No connection-string secrets anywhere. Managed Identity for the
API→SQL and API→Service Bus paths, Entra ID for app auth, Key Vault references
for any remaining config. Prove there are zero secrets in app settings.

**Exercise.** Paste the MI wiring + a Key Vault reference. Show the app
settings have no plaintext secrets.

Deployed to dev: subscription `85567e22-…`, resource group
`thinkschool-dev-rg`, region `uaenorth`.
API `https://quotes-api-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io`,
web `https://quotes-web-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io`.

## Managed Identity wiring

One user-assigned identity, `id-quotes-api-7mo4cimyk4vnk`, is what the API is
to Azure. Every dependency below authenticates as it.

### API → SQL

The connection string is the whole mechanism, and it contains no credential —
`infra/modules/sql.bicep`:

```bicep
output connectionString string = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${database.name};Authentication=Active Directory Default;User Id=${appIdentityClientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
```

`Authentication=Active Directory Default` makes the driver fetch a token
instead of sending a password. `User Id` is the identity's **client** id, not
its object id, and it is required because a container app can carry more than
one identity — without it the driver picks by its own precedence order.

The server refuses passwords outright rather than merely not being given one:

```bicep
properties: {
  administrators: { azureADOnlyAuthentication: true, ... }
}
```

There is one thing ARM cannot do here, and skipping it produces an app that
starts and then never becomes ready: an Entra-only server grants the identity
access to the *server*, not a user inside the *database*. The contained user is
T-SQL, created once by `Day7/piece2/scripts/create-sql-user.ps1`.

### API → Service Bus

`Day7/piece2/QuotesApi/Extensions/MessagingExtensions.cs` — namespace, not
connection string:

```csharp
services.AddAzureClients(clientBuilder =>
{
    clientBuilder.AddServiceBusClientWithNamespace(opts.FullyQualifiedNamespace)
                 .WithCredential(new DefaultAzureCredential());
});
```

and `infra/modules/servicebus.bicep` closes the other door:

```bicep
properties: {
  disableLocalAuth: true
}
```

so a SAS connection string is rejected by the namespace even if one were
supplied. Three narrow role assignments carry the access: Data Sender on the
topic, Data Receiver on each of the two subscriptions.

### Naming the identity, which turns out to be load-bearing

`infra/main.bicep`:

```bicep
{
  name: 'AZURE_CLIENT_ID'
  value: identity.outputs.identityClientId
}
```

The SQL path names the identity inside its connection string. The Service Bus
client, the Key Vault provider and the Azure Monitor exporter all go through
`DefaultAzureCredential`, which had no such hint — it resolved correctly only
because exactly one identity happens to be attached. That is an accident, not
a design, and the wrong pick presents as an authorization failure that reads
exactly like a missing role assignment.

## The Key Vault reference

`infra/modules/api.bicep` — the container app holds an address, not a value:

```bicep
secrets: [
  {
    name: jwtSecretName
    keyVaultUrl: jwtSecretUri
    identity: userAssignedIdentityResourceId
  }
]
```

Live, from `az containerapp show -n quotes-api-dev -g thinkschool-dev-rg`:

```json
"secrets": [
  {
    "identity": ".../userAssignedIdentities/id-quotes-api-7mo4cimyk4vnk",
    "keyVaultUrl": "https://kv-7mo4cimyk4vnk.vault.azure.net/secrets/jwt-secret",
    "name": "jwt-secret"
  }
]
```

**The value never passes through the template.** `infra/modules/keyvault.bicep`
creates the vault *empty* — no `vaults/secrets` resource, no `@secure()`
parameter anywhere in the graph — and `Day25/scripts/01-seed-jwt-secret.ps1`
writes the key straight from the operator to the vault.

This is the part worth arguing for. `@secure()` is routinely read as "the value
is handled safely", but its promise is narrower: it keeps the value out of
deployment *logs*. It says nothing about the places the value must exist in
order to be passed at all — the operator's shell and azd `.env`, the CI
runner's environment, and the body of the request to the ARM deployment API.
Four copies of something that needs to exist in one place. Vaulting the secret
while still passing it through the template would have kept all four; so
`jwtSecret` was deleted from `main.bicep`, both `.bicepparam` files and
`main.parameters.json`, and the template now composes only
`https://<vault>/secrets/jwt-secret`.

The reference resolves with the same managed identity, granted **Key Vault
Secrets User** — read-only over values, deliberately not Secrets Officer: an
app that can overwrite its own signing key is an app that can lock every user
out.

Two behaviours to know before meeting them: a reference resolves when a
**revision is created**, not per request, so rotating in the vault does not
reach a running app; and an unresolvable reference makes the revision **fail to
provision** rather than start degraded.

## Proof: no plaintext secrets in app settings

`Day25/scripts/00-prove-no-secrets.ps1`, run before any change and again after.
Both outputs are committed. It tests three claims, not one:

1. nothing secret in configuration — no inline container app secret, no
   credential-shaped env value;
2. the resources **refuse** secret auth at all, so a pasted credential would
   not work even if someone added one;
3. the identity that replaced the secrets is not so broadly scoped that the
   swap was cosmetic.

It never resolves secret values — vault-backed is told from inline by the
presence of `keyVaultUrl`, which needs no value — because its output is
committed.

**Before** (`Day25/verification/no-secrets-BEFORE.txt`) — 6 passed, 5 failed:

```
FAIL  quotes-api-dev      secret 'jwt-secret' holds an INLINE value
FAIL  quotes-api-dev      env 'ApplicationInsights__ConnectionString' carries a WORKING ingestion key
FAIL  quotes-api-dev      env 'APPLICATIONINSIGHTS_CONNECTION_STRING' carries a WORKING ingestion key
FAIL  Container Registry  cr7mo4cimyk4vnk: admin user disabled
FAIL  App Insights        appi-quotes-api-7mo4cimyk4vnk: local auth disabled
```

**After** (`Day25/verification/no-secrets-AFTER.txt`) — 13 passed, 0 failed:

```
PASS  quotes-api-dev      secret 'jwt-secret' is a Key Vault reference
                          https://kv-7mo4cimyk4vnk.vault.azure.net/secrets/jwt-secret
PASS  quotes-web-dev      holds no secrets at all
PASS  quotes-api-dev      env 'ApplicationInsights__ConnectionString' carries an instrumentation key
                          App Insights local auth is disabled, so this is an identifier and not a credential.
PASS  quotes-api-dev      no credential-shaped env values
PASS  Azure SQL           sql-quotes-7mo4cimyk4vnk: Entra-only authentication
PASS  Service Bus         sb-quotes-7mo4cimyk4vnk: local (SAS) auth disabled
PASS  Container Registry  cr7mo4cimyk4vnk: admin user disabled
PASS  App Insights        appi-quotes-api-7mo4cimyk4vnk: local auth disabled
PASS  Key Vault           kv-7mo4cimyk4vnk: RBAC authorization
PASS  id-quotes-api-…     least-privilege roles only
                          AcrPull, Azure Service Bus Data Receiver, Azure Service Bus Data Sender,
                          Key Vault Secrets User, Monitoring Metrics Publisher
PASS  Repository          no credential literals in infra or appsettings
```

The baseline was run first deliberately. A check that has only ever passed
proves nothing about whether it can fail.

### And the app still works

Zero secrets achieved by breaking the application is not a pass
(`Day25/verification/smoke-test-AFTER.txt`):

```
live  200
{"service":"QuotesApi","status":"Healthy","checks":[{"name":"database","status":"Healthy","durationMs":3.59}]}
ready 200
```

One 200 carries both halves. The app **booting** proves the Key Vault reference
resolved — `JwtOptions` is bound with `ValidateOnStart()` and `[MinLength(32)]`,
so a missing or truncated secret is a startup failure, not a later error. The
**database check** proves EF Core authenticated to an Entra-only SQL server
over the managed identity, where no password path exists to explain the result.

## Eliminate, demote, then vault

The organising rule, and the reason this was not simply "put things in Key
Vault": *absence* of a credential is a fact about today; *refusal* of
credentials is a fact about the deployment. So each value was handled in order:

1. **Eliminate.** Turn off secret-based auth at the resource. The ACR admin
   user was a live username and password that nothing used — both apps pull
   with the managed identity — so it was disabled outright.
2. **Demote.** Where the value must stay, stop it being a credential. An App
   Insights connection string carries `InstrumentationKey=<guid>`; with local
   auth enabled that key lets anyone write telemetry into the component,
   unauthenticated and unattributed, and poisoned telemetry is nasty precisely
   because the graphs stay plausible. `DisableLocalAuth: true` plus
   `options.Credential` on `UseAzureMonitor()` reduces the same string to an
   address.
3. **Vault.** Only the JWT signing key survived both, and it got the reference
   above.

The clearest evidence for the middle step is in the two runs: the App Insights
env vars flipped FAIL → PASS **with their values unchanged**. Nothing was
vaulted and nothing was rewritten; the resource reclassified the string.

## Entra ID for app auth

The API already ran two authentication schemes side by side — `CustomJwt` for
its own tokens and `EntraId`, routed per request by an `AddPolicyScheme` that
inspects the `aud` claim. That much predates this day and is deployed.

Day 25 moved the registration into the tenant that owns the subscription.
`Day25/scripts/02-entra-app-registrations.ps1` created both, in Amity
(`8d46a076-…`):

```
API   18920fc7-79a5-42f0-bf65-c101749dd79b   api://18920fc7-…/access
SPA   e2255607-dc83-4747-9623-b73cc24ff62c   public client, PKCE, redirect to the dev web app
```

**Two registrations, zero client secrets.** A browser cannot keep a secret, so
the SPA is a public client using authorization code with PKCE; the API is a
resource server that validates tokens and never requests them, so it has no
credential either. Nothing in this phase adds anything for the proof script to
find — which is why it is re-run afterwards rather than assumed.

It previously pointed at tenant `f774bb68-…` and app `91566dbd-…`, in the old
subscription's directory. That worked — validating a token is an HTTPS call to
an authority URL and has no relationship to which tenant owns the subscription
— and that is precisely why it survived a subscription migration unnoticed,
leaving a directory nobody pays for as a runtime dependency.

**The move exposed a bug that was always there.** `azureAdAudience` was
`api://quotes-api/access`, which is a *scope*, not an audience. Entra issues
access tokens whose `aud` claim is the resource's Application ID URI, carrying
the scope separately in `scp` — so the `EntraId` scheme would have rejected
**every** genuine Entra token it was handed. Nothing caught it because nothing
had sent one: the SPA signs in against the app's own `CustomJwt` endpoints, so
the second scheme has never been exercised in anger. A dead code path is not a
correct one. The script wrote `api://18920fc7-…` in its place.

The script writes those three values into `main.dev.bicepparam` itself rather
than printing them to copy. Three hand-transcribed GUIDs is three chances to
transpose a character, and every one of those mistakes fails identically — as
an audience or issuer mismatch, which reads like a broken auth scheme rather
than a typo.

**Deliberately deferred:** retiring `CustomJwt` entirely. That is the fix that
would delete the signing key rather than vault it, and it means migrating the
SPA to MSAL and reworking sign-in, the `Users` table and refresh tokens. It is
its own day, and this is a decision rather than an oversight.

## Two things that cost a deployment cycle

**The image-preservation module deadlocks after a partial failure.** The first
deploy left `quotes-api-dev` in a `Failed` provisioning state (the vault existed
but the secret had not been seeded yet, so the reference could not resolve).
`fetchLatestImage` — which reads the running app's current image so an
infra-only update does not revert it to the placeholder — **cannot read a
resource in that state**: *"Failed to obtain the resource body."* The lookup
that exists to protect the running image blocked the deployment that would
repair it. A template that reads its own prior state has a failure mode where
one partial failure makes it unrunnable. Broken from outside with a single
`az containerapp update --image`, after which the stack ran clean.

**Ordering is real, and the first deploy of a fresh environment always fails
once.** The vault is created empty by design, so: deploy → seed → redeploy.
Worth stating rather than discovering.

Day 24's deny-assignment deadlock did **not** recur — the stack deleted the
superseded SQL firewall rule successfully, and three new child scopes (the
vault and two role assignments) did not reintroduce it.
