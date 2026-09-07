// Day 23 — dev parameter file.
//
// Run it:
//   az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.dev.bicepparam
//
// No signing key is written in this file. The pre-Day-23 template carried a
// literal one in source control; a dev/prod split would have duplicated it into
// two files, which is where that approach stops being defensible. It is read
// from JWT_SECRET at compile time instead — see the jwtSecret line below.
//
//   export JWT_SECRET='<at least 32 characters>'
//
// NOTE: azd does not read this file. azd reads main.parameters.json only.

using './main.bicep'

// A FRESH environment, deliberately. The first what-if of this template was run
// against environmentName 'thinkschool-azd' and exposed a collision worth
// recording: the subscription already carries TWO earlier deployments with
// different environment names, and this template sat between them.
//
//   thinkschool-azd-rg  holds resources from env 'thinkschool-azd-cowork'
//                       (resourceToken zteoe67vlaev6) and a container app
//                       'quotes-api-cowork'
//   thinkschool-rg      holds the live azd deployment for env 'thinkschool-azd'
//                       (resourceToken qn4pdkxclsa6s) and 'quotes-api-azd',
//                       plus a HAND-CREATED SQL server, thinkschoolsql45921
//
// Targeting either one meant modifying a deployment this template did not
// create: a globally-unique ACR name already taken in the other group, a live
// app's identity and registry rewritten, and its running image reverted. None
// of that is a property of the template — it is the cost of adopting somebody
// else's resources. A new environment name yields a new resourceToken, so
// every resource below is created rather than adopted, and the idempotency
// proof measures this template instead of the leftovers of two others.
param environmentName = 'thinkschool-day23'
param location = 'centralindia'
param environmentType = 'dev'
param resourceGroupName = 'thinkschool-day23-rg'

// Unique within the Container Apps ENVIRONMENT, not just the resource group —
// and this environment is shared with the deployments described above, both of
// which already have an app in it.
param apiContainerAppName = 'quotes-api-day23'

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
//   export JWT_SECRET='<at least 32 characters>'
param jwtSecret = readEnvironmentVariable('JWT_SECRET', '')

// --- Entra ID ------------------------------------------------------------
// UNRESOLVED, AND STATED RATHER THAN GUESSED. appsettings.json declares
// AzureAd:Audience as 'api://quotes-api/access'; the app deployed in this
// subscription is running 'api://91566dbd-d857-488a-858d-475e60b309b7', the
// app-ID-URI form. They cannot both be right, and which one is depends on what
// the Entra app registration actually exposes:
//
//   az ad app show --id 91566dbd-d857-488a-858d-475e60b309b7 \
//     --query "{uris:identifierUris, scopes:api.oauth2PermissionScopes[].value}"
//
// The repository's own declared value is used until that is checked. A token
// whose audience does not match is rejected, so getting this wrong disables the
// Entra scheme — it does not weaken it.
param azureAdAudience = 'api://quotes-api/access'

// --- Observability -------------------------------------------------------
// 30 days is the included, no-extra-cost retention. The 1 GB/day cap is a cost
// guard that is only acceptable because losing dev telemetry costs nothing.
param logRetentionInDays = 30
param logDailyQuotaGb = 1

// --- Container Apps Environment ------------------------------------------
// Reuse thinkschool-env. Not a preference: this subscription allows exactly one
// Container Apps Environment per region (MaxNumberOfRegionalEnvironmentsInSub-
// Exceeded) and that one already occupies centralindia.
param createContainerAppsEnvironment = false
param containerAppsEnvironmentName = 'thinkschool-env'
param containerAppsEnvironmentResourceGroup = 'thinkschool-rg'

// --- API ------------------------------------------------------------------
// minReplicas 0: scale to zero between uses. A cold start on the first request
// after idling is the price, and in a training environment it is the right one.
param apiMinReplicas = 0
param apiMaxReplicas = 2
param apiCpu = '0.5'
param apiMemory = '1Gi'
param apiConcurrentRequests = 50

// --- SQL ------------------------------------------------------------------
// Serverless, auto-pausing after an hour: billed per second while awake and
// storage-only while asleep. The first request after a pause pays a resume
// delay of roughly a minute, which is why prod does not use this.
//
// The signed-in user, from `az ad signed-in-user show --query id -o tsv`.
// With azureADOnlyAuthentication there is no SQL login to fall back on, so a
// wrong object ID here means nobody can administer the server at all.
param sqlEntraAdminObjectId = 'ddc82f6d-48cd-4406-adb6-a4b606833b34'

// The same account's userPrincipalName. The #EXT# form is not a typo: this is
// an external (guest) identity in the directory, which is what an account
// federated from a consumer provider looks like once it has been invited. Azure
// SQL records it verbatim, and it is the name the contained database user is
// created against in scripts/create-sql-user.ps1.
//
// principalType is 'User' rather than 'Group' because this names a person. Prod
// uses a group, deliberately — a production database whose only administrator
// is one named individual loses its administrator when that person changes
// role. Here, one person is the whole team.
param sqlEntraAdminLogin = 'vaishalisinghsln5_gmail.com#EXT#@vaishalisinghsln5gmail.onmicrosoft.com'
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
