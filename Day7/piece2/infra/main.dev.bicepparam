// Day 24 — dev parameter file, retargeted at a new subscription.
//
// Run it:
//   az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.dev.bicepparam
//
// NOTE: azd does not read this file. azd reads main.parameters.json only.
//
// ---------------------------------------------------------------------------
// WHY THIS FILE CHANGED WHOLESALE ON DAY 24
// ---------------------------------------------------------------------------
// Day 23's version of this file was written against subscription
// 80d20ef9-8bfa-45d7-a9d8-b6cf1f0c791e in tenant f774bb68-…, and most of its
// header explained a collision with two earlier deployments in that
// subscription. Its credits are exhausted, so everything now targets:
//
//   subscription  85567e22-432e-4648-aa68-ba2714167694  ("Azure for Students")
//   tenant        8d46a076-d093-416d-a57b-8692cde13bf8  ("Amity University")
//
// That old rationale is deleted rather than left in place. A stale explanation
// is worse than none: it reads as current and sends the next person looking for
// resource groups that are in a subscription they cannot reach.
//
// THE ENTRA STORY IS SPLIT ACROSS TWO TENANTS, ON PURPOSE.
// A directory is free and does not expire when a subscription's credits do, so
// the old tenant still exists and still owns the API's app registration.
//
//   The API's Entra ID auth scheme  -> stays in the OLD tenant f774bb68-…
//     Token validation is an HTTPS call to an authority URL. It has no
//     relationship to which tenant owns the subscription the container runs in,
//     so azureAdClientId / azureAdTenantId / azureAdAudience in main.bicep are
//     unchanged. This also avoids needing app-registration rights in a
//     university tenant, which are commonly withheld from non-admins.
//
//   The SQL administrator            -> MUST be Amity 8d46a076-…
//     An Azure SQL server only accepts an Entra administrator from the tenant
//     its subscription trusts. The #EXT# gmail identity Day 23 used does not
//     exist in this directory. See sqlEntraAdminObjectId below.
//
// Do not delete the old tenant or app registration when decommissioning the old
// subscription. Deleting the directory breaks Entra authentication here.

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

// The signing key is read from the environment at compile time, never written
// into this file.
//
// The empty-string fallback is deliberate, and it is not a default value: it
// exists so this file compiles for someone who has merely OPENED it. Two
// stricter spellings were tried first and both fail at compile time rather
// than at deploy time:
//   readEnvironmentVariable('JWT_SECRET')      -> BCP427 when the var is unset
//   ... with @minLength(32) on the parameter   -> BCP333, because Bicep checks
//                                                 length here, not at deploy
//
// Empty is still not deployable. modules/api.bicep declares @minLength(32) on
// the parameter that actually consumes this, and ARM validates that at
// deployment — so a deploy without JWT_SECRET set is rejected before a single
// resource is touched. Fail at deploy, not at open.
//
// It cannot be passed as `-p jwtSecret=...` alongside this file: az refuses to
// mix a .bicepparam with inline parameter overrides. Set the variable instead:
//   $env:JWT_SECRET = '<at least 32 characters>'
//
// USE A NEW KEY. Not the literal that is still in this repository's git
// history, and not the one the old subscription's app was issuing tokens with —
// a subscription cutover is the right moment to invalidate every outstanding
// token rather than carry them across.
param jwtSecret = readEnvironmentVariable('JWT_SECRET', '')

// --- Entra ID ------------------------------------------------------------
// Unchanged, and pointing at the OLD tenant — see the header. Still unresolved
// and still stated rather than guessed: appsettings.json declares
// AzureAd:Audience as 'api://quotes-api/access'; the app that ran in the old
// subscription used 'api://91566dbd-d857-488a-858d-475e60b309b7', the
// app-ID-URI form. They cannot both be right. Ask the directory, which is still
// reachable:
//
//   az login --tenant f774bb68-0575-4cd2-9d4c-3b4e593d1110 --allow-no-subscriptions
//   az ad app show --id 91566dbd-d857-488a-858d-475e60b309b7 \
//     --query "{uris:identifierUris, scopes:api.oauth2PermissionScopes[].value}"
//
// A token whose audience does not match is rejected, so getting this wrong
// disables the Entra scheme — it does not weaken it.
param azureAdAudience = 'api://quotes-api/access'

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
// REPLACE BOTH BEFORE DEPLOYING — gate G5. From, while signed in to Amity:
//   az ad signed-in-user show --query "{id:id, upn:userPrincipalName}" -o json
//
// With azureADOnlyAuthentication there is no SQL login to fall back on, so a
// wrong object ID here does not fail the deployment — it succeeds and leaves a
// server NOBODY CAN ADMINISTER, and the only fix is to redeploy the server.
// Placeholders that fail are better than plausible values that succeed.
// From `az ad signed-in-user show` in the Amity tenant. Note the UPN is an
// ordinary member identity (@s.amity.edu), not the #EXT# guest form Day 23
// used — that one belongs to the old tenant and does not exist here.
param sqlEntraAdminObjectId = 'a59d00a8-a829-49b4-83d1-952727eea166'
param sqlEntraAdminLogin = 'vaishalee.singh@s.amity.edu'
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
param webAppExists = true
param webMinReplicas = 0
param webMaxReplicas = 2
