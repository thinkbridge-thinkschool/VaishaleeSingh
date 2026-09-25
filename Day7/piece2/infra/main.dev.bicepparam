// Dev parameter file, retargeted at a new subscription AND a new tenant.
//
// Run it:
//   az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam
//
// NOTE: azd does not read this file. azd reads main.parameters.json only.
//
// ---------------------------------------------------------------------------
// WHY THIS FILE CHANGED WHOLESALE — THE 2026-09 MIGRATION
// ---------------------------------------------------------------------------
// Everything now targets:
//
//   subscription  33c82ead-36a8-4d8f-b969-d8476690c224
//   tenant        803dced7-0a24-4857-8be8-280047561e95
//
// The previous rationale — two earlier subscriptions, a directory split across
// tenants — is deleted rather than left in place. A stale explanation is worse
// than none: it reads as current and sends the next person looking for resource
// groups in a subscription they cannot reach.
//
// WHAT IS DIFFERENT ABOUT THIS MOVE: THE TENANT CHANGED TOO.
// The two earlier migrations kept the directory and swapped only the
// subscription, so object ids and app registrations survived. This one does
// not. A tenant move invalidates every directory-scoped identifier:
//
//   * the operator's object id and UPN          (SQL administrator)
//   * the SQL administrator group's object id   (prod)
//   * both API app registrations and the SPA    (azureAdClientId / Audience)
//   * the GitHub OIDC application               (federated credential)
//
// None of them can be carried across, and none of them is left at its old
// value, because a stale client id does not fail — it deploys and silently
// authenticates nothing. Every one is a SETME sentinel below, and the scripts
// under migration/ fill them:
//
//   SETME01…  migration/01-set-identities.ps1     (who administers SQL)
//   SETME02…  Day25/scripts/02-entra-app-registrations.ps1 (app registrations)
//   SETME10…  migration/10-refresh-derived-names.ps1 (names, after dev deploys)
//
// AND THE RESOURCE NAMES CHANGE. main.bicep derives them from
// uniqueString(subscription().id, environmentName, location), so a new
// subscription yields a new token for the registry, the SQL server, the Service
// Bus namespace, the Log Analytics workspace and the Container Apps
// environment. Anything that hardcoded the old token now reads SETME10.
//
// migration/README.md is the order these must run in. migration/90-verify-no-old-ids.ps1
// refuses to pass while any old identifier or any SETME sentinel remains.

using './main.bicep'

// ---------------------------------------------------------------------------
// Identity of the deployment
// ---------------------------------------------------------------------------
// Renamed away from 'thinkschool-day23'. resourceToken is
// uniqueString(subscription().id, environmentName, location), so the new
// subscription already yields new names for everything — the rename costs
// nothing now and stops a live environment being named after an exercise.
param environmentName = 'thinkschool-dev'
param environmentType = 'dev'
param resourceGroupName = 'thinkschool-dev-rg'
param apiContainerAppName = 'quotes-api-dev'

// TRUE, AND THE DEFAULT OF FALSE COST A DEPLOYED IMAGE.
//
// main.bicep threads this into modules/fetch-container-image.bicep, which
// decides whether to LOOK UP the image the container app is currently running
// instead of overwriting it. With it false, resolvedApiImage falls through to
// the aci-helloworld placeholder, so an infrastructure-only stack update
// silently reverts a working deployment to a hello-world page. That is exactly
// what happened on the stack update that refreshed the SQL firewall rule: the
// intent was one firewall rule, and the effect included rolling the API back to
// the placeholder.
//
// The template already had the guard. It just was not switched on from this
// file: azd sets it from SERVICE_QUOTES_API_RESOURCE_EXISTS via
// main.parameters.json, and NEITHER .bicepparam file set it at all, so every
// `az stack sub create` / `az deployment sub create` ran with it false. Day 23
// never noticed because the deploy it tested was followed immediately by an
// image push; the revert only shows when infrastructure is updated on its own,
// which is precisely what a stack is for.
//
// MUST BE FALSE FOR THE VERY FIRST DEPLOYMENT into a brand-new environment,
// where there is no container app to read an image from. Set it back to true
// straight after. This is stated rather than automated because a wrong value in
// either direction is recoverable in one redeploy, and a clever expression here
// would be one more thing to be wrong.
//
// 2026-09-25, THE MIGRATION: THIS *IS* "THE VERY FIRST DEPLOYMENT" AGAIN.
// The new subscription has no quotes-api-dev and no quotes-web-dev, so both
// flags are false. They were left at true because the last thing that happened
// in the OLD subscription was a live app -- which is exactly how a correct
// value becomes a wrong one without anybody editing it.
// migration/10-refresh-derived-names.ps1 sets them back to true once it has
// read both apps out of Azure.
param quotesApiExists = true

// REPLACE BEFORE DEPLOYING — and note that this line was briefly set to
// 'centralindia' on the strength of a probe that was WRONG. Recording that,
// because the wrong answer is more instructive than the right one.
//
// The probe created and deleted an empty resource group in centralindia and
// read success as "region permitted". It succeeded. centralindia is not in this
// subscription's allowed-locations policy at all. Azure's built-in "Allowed
// locations" policy exempts Microsoft.Resources/subscriptions/resourceGroups —
// where resource GROUPS may live is a separate policy — so a resource group
// places fine in a region where every resource inside it would be refused. A
// resource group is a metadata record; the exemption is deliberate.
//
// This subscription permits exactly these:
//   indonesiacentral, malaysiawest, indiasouthcentral, uaenorth, koreacentral
//
// Being on that list is necessary and not sufficient — three of those are new
// regions and may not offer Container Apps. Day24/scripts/01-region-fit.ps1
// intersects the policy list with what each required provider actually offers
// and prints the line that belongs here.
// uaenorth. Chosen from the four that 01-region-fit.ps1 found viable
// (indonesiacentral, malaysiawest, uaenorth, koreacentral) on two grounds:
// it is the lowest-latency of them to India, and it is a mature region.
// Indonesia Central and Malaysia West are recent enough that a specific SKU can
// be missing even where the provider lists the region — the fit check reads
// provider/resourceType availability, which is coarser than SKU availability.
// indiasouthcentral is permitted by policy but offers no Container Apps at all.
param location = 'uaenorth'

// --- Key Vault -----------------------------------------------------------
// THE SIGNING KEY IS NO LONGER HERE, AND NOTHING REPLACED IT.
//
// This file used to carry `param jwtSecret = readEnvironmentVariable(...)`,
// with a long comment about why the empty-string fallback had to exist for the
// file to compile at all. All of that was scaffolding around one decision:
// that the value would travel through the template. Day 25 reversed that
// decision, so the scaffolding went with it.
//
// The value now goes operator -> vault, once, via
// Day25/scripts/01-seed-jwt-secret.ps1. Nothing in this repository ever holds
// it, JWT_SECRET no longer needs to be exported to deploy, and it should be
// removed from the azd environment (.azure/thinkschool-dev/.env), where it is
// currently sitting in plain text.
//
// Purge protection OFF here. Not an oversight and not laziness: this stack is
// torn down and recreated, actionOnUnmanage is deleteAll, and a purge-protected
// vault reserves its name for up to 90 days after deletion — so leaving it on
// would make the NEXT deployment fail on a name it cannot reuse, reported as a
// conflict rather than as anything mentioning purge protection.
param keyVaultPurgeProtection = false
param keyVaultSoftDeleteRetentionInDays = 7

// --- Entra ID ------------------------------------------------------------
// THE REGISTRATION DOES NOT SURVIVE THE TENANT MOVE, SO IT IS NOT REUSED.
// The old app registration lives in a directory this subscription no longer
// trusts. A client id from another tenant is not an error the platform
// reports: the deployment succeeds, the container app starts, and every
// genuine Entra token is rejected on issuer or audience — which reads as a
// broken auth scheme rather than as a stale identifier. So the client id and
// the audience below are sentinels, not values.
//
// Fill them by running, in the NEW tenant:
//   ./Day25/scripts/02-entra-app-registrations.ps1 -Environment dev
// It creates the API and SPA registrations, is idempotent, and writes the
// three lines below itself rather than asking anyone to transcribe a GUID.
//
// THE AUDIENCE IS api://<appId>, NOT A SCOPE — a bug Day 25 found and the
// reason that script exists. Entra issues an access token whose `aud` claim is
// the RESOURCE'S Application ID URI and carries the scope separately in `scp`.
// The value 'api://quotes-api/access' that appsettings.json once declared is a
// scope, so the EntraId scheme would have rejected every genuine token handed
// to it. Nothing caught it because nothing had sent one: the SPA signs in
// against the app's own CustomJwt endpoints. A dead code path is not a
// correct one.
//
// These are directory identifiers, not secrets. A tenant id and a client id
// identify an application publicly; neither registration has a client secret,
// and neither needs one — the SPA is a public client using PKCE and the API
// only ever validates tokens.

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.
param azureAdTenantId = '803dced7-0a24-4857-8be8-280047561e95'
param azureAdClientId = '23ac957e-d95a-4026-befd-18b375eb3986'

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.
param azureAdAudience = 'api://23ac957e-d95a-4026-befd-18b375eb3986'

// --- Alerting (Day 26) ----------------------------------------------------
// A real address, because an alert nobody receives is not an alert. It is
// personal data rather than a credential, so it belongs here in the parameter
// file rather than defaulted into main.bicep where it would follow every
// environment.
//
// Five percent, in an environment that scales to zero and is redeployed
// several times a day. That sounds slack for production and is deliberately
// so here: the query already refuses to report a rate below twenty requests
// in five minutes, and the rule requires the condition to hold twice in a row,
// so the threshold is the third guard rather than the only one.
param alertEmailAddress = 'vaishalisinghsln5@gmail.com'
param errorRateThresholdPct = 5

// --- Observability -------------------------------------------------------
// 30 days is the included, no-extra-cost retention. The 1 GB/day cap is a cost
// guard that is only acceptable because losing dev telemetry costs nothing —
// and on a $100 twelve-month credit it is no longer merely prudent.
param logRetentionInDays = 30
param logDailyQuotaGb = 1

// --- Container Apps Environment ------------------------------------------
// CHANGED ON DAY 24, AND THIS IS THE SINGLE MOST LIKELY THING TO BREAK IN THE
// MOVE IF IT IS MISSED.
//
// Day 23 set this to false and reused 'thinkschool-env' in 'thinkschool-rg',
// because the old subscription permitted exactly one Container Apps Environment
// per region and that one already occupied the region. Neither the environment
// nor the resource group exists in this subscription — they are in a
// subscription this deployment cannot reach. Left at false, the deployment
// fails on a reference to a resource group that is not there.
param createContainerAppsEnvironment = true

// --- API ------------------------------------------------------------------
// minReplicas 0: scale to zero between uses. A cold start on the first request
// after idling is the price, and in a training environment on a fixed credit it
// is emphatically the right one.
param apiMinReplicas = 0
param apiMaxReplicas = 2
param apiCpu = '0.5'
param apiMemory = '1Gi'
param apiConcurrentRequests = 50

// --- SQL ------------------------------------------------------------------
// Serverless, auto-pausing after an hour: billed per second while awake and
// storage-only while asleep. The first request after a pause pays a resume
// delay of roughly a minute.
//
// BOTH ARE SENTINELS AND THE DEPLOYMENT MUST NOT RUN UNTIL THEY ARE FILLED.
// A tenant move invalidates an object id completely — the account that
// administered this server in the old directory does not exist in the new one.
//
// Fill them by running, signed in to the new tenant:
//   ./migration/01-set-identities.ps1
// which reads `az ad signed-in-user show` and writes both lines here, rather
// than asking anyone to copy a GUID between a terminal and an editor.
//
// WHY A SENTINEL AND NOT THE OLD VALUE. With azureADOnlyAuthentication there is
// no SQL login to fall back on, so a wrong-but-well-formed object id does not
// fail the deployment — it succeeds and leaves a server NOBODY CAN ADMINISTER,
// and the only fix is to redeploy the server. A value that is not a GUID at all
// is rejected at deployment time, by name. Placeholders that fail are better
// than plausible values that succeed.
// The human who seeds the JWT signing key into the vault. keyvault.bicep grants
// this principal Key Vault Secrets Officer ON THIS VAULT ONLY, because the vault
// is recreated by every failed deployment and a hand-granted assignment dies with
// it. Prod has always set this; dev never did, so dev's vault arrived unusable on
// a fresh subscription and Day25/scripts/01-seed-jwt-secret.ps1 got a flat 403.
param keyVaultWriterPrincipalId = '6294a008-f2fa-4b34-b06d-f897e5844511'

param sqlEntraAdminObjectId = '6294a008-f2fa-4b34-b06d-f897e5844511'
param sqlEntraAdminLogin = 'Vaishalee Singh'
param sqlEntraAdminPrincipalType = 'User'

param sqlDatabaseName = 'quotes'
param sqlSkuName = 'GP_S_Gen5'
param sqlSkuTier = 'GeneralPurpose'
param sqlSkuCapacity = 1
param sqlUseServerless = true
param sqlAutoPauseDelayMinutes = 60
param sqlMaxSizeBytes = 2147483648
param sqlBackupStorageRedundancy = 'Local'
param sqlPublicNetworkAccess = 'Enabled'
// Re-check this once 01-region-fit.ps1 names the region. The Day 23 value was
// reasoned about centralindia specifically ("centralindia General Purpose Gen5
// does not offer zone redundancy"), and centralindia is not where this is going
// any more. False is still the safe answer — a region that does not support it
// rejects true — but the REASON no longer applies, and an unexamined value
// carried across a region change is how a stale justification survives.
param sqlZoneRedundant = false

// The machine that administers the server — needed by scripts/create-sql-user.ps1,
// which connects as a person rather than as the app. Read from the environment,
// never written here: an IP address is personal data, this file is committed,
// and a home address changes between sessions anyway.
//
//   $env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
//
// Unset means no client rule at all, which is the correct default for anything
// that is not a workstation being used for administration right now.
param sqlAllowedClientIpAddresses = empty(readEnvironmentVariable('SQL_CLIENT_IP', ''))
  ? []
  : [readEnvironmentVariable('SQL_CLIENT_IP', '')]

// --- Service Bus ----------------------------------------------------------
// Standard is the floor, not a saving: Basic has queues only and this topology
// is topic-based. A 1-day TTL bounds what an unread subscription can accumulate
// while nobody is looking at a training environment.
param serviceBusSkuName = 'Standard'
param serviceBusMessagingUnits = 1
param serviceBusMessageTimeToLive = 'P1D'
param serviceBusMaxDeliveryCount = 3
param serviceBusLockDuration = 'PT1M'


// --- Front end ------------------------------------------------------------
// Day 24. Its own container app, its own image, its own workflow. See the
// header of modules/web.bicep for why this is not a Static Web App and not
// bundled into the API image.
param webContainerAppName = 'quotes-web-dev'
// FALSE UNTIL THE APP EXISTS, then true. This shipped as `true` on the first
// attempt and failed the whole stack deployment:
//
//   ResourceDeploymentFailure ... target: .../deployments/fetchLatestWebImage
//
// modules/fetch-container-image.bicep references an EXISTING container app to
// read the image it is currently running. With exists = true and no such app,
// that reference cannot resolve and the deployment fails -- taking every other
// resource in the stack update down with it, since the modules deploy as one.
//
// The irony is that the note on quotesApiExists, six lines up, says exactly
// this: "MUST BE FALSE FOR THE VERY FIRST DEPLOYMENT into a brand-new
// environment, where there is no container app to read an image from." I wrote
// that after the API hit it, then set the front end's copy to true anyway.
//
// NOW TRUE: quotes-web-dev exists and runs a real image, so
// modules/fetch-container-image.bicep reads the running image rather than
// overwriting it. Left at false, every infrastructure-only stack update would
// revert the front end to the aci-helloworld placeholder -- the other half of
// the same trap, and the half the API actually fell into.
//
// 2026-09-25, THE MIGRATION: THIS *IS* "THE VERY FIRST DEPLOYMENT" AGAIN.
// The new subscription has no quotes-api-dev and no quotes-web-dev, so both
// flags are false. They were left at true because the last thing that happened
// in the OLD subscription was a live app -- which is exactly how a correct
// value becomes a wrong one without anybody editing it.
// migration/10-refresh-derived-names.ps1 sets them back to true once it has
// read both apps out of Azure.
param webAppExists = true
param webMinReplicas = 0
param webMaxReplicas = 2
