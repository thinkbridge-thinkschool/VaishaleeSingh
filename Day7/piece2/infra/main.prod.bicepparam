// Day 23 — prod parameter file.
//
// HONESTY NOTE, READ FIRST: this environment has never been deployed. It is
// what-if'd against the same subscription to prove that one template produces
// both shapes, and nothing here has been observed running. Every value below is
// a considered choice; none of them is a verified one.
//
//   az deployment sub what-if -l centralindia -f infra/main.bicep -p infra/main.prod.bicepparam
//
// No signing key is written here either — same mechanism as dev, read from
// JWT_SECRET at compile time. A production signing key belongs in a vault, and
// the follow-up this file implies is a Key Vault module with a secretRef, which
// Day 23 deliberately left out of scope.

using './main.bicep'

param environmentName = 'thinkschool-prod'
param location = 'centralindia'
param environmentType = 'prod'
param apiContainerAppName = 'quotes-api-prod'
param resourceGroupName = 'thinkschool-prod-rg'

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

// --- Observability -------------------------------------------------------
// 90 days, and NO daily cap. A quota that is hit drops telemetry, which means
// the one incident big enough to blow the cap is the one you cannot
// investigate. -1 is uncapped, on purpose.
param logRetentionInDays = 90
param logDailyQuotaGb = -1

// --- Container Apps Environment ------------------------------------------
// A dedicated environment, unlike dev. The subscription's one-per-region quota
// means this cannot actually be created today — which is precisely why it is a
// parameter: the constraint lives here, in a file, instead of being welded into
// the template as it was before Day 23.
param createContainerAppsEnvironment = true

// --- API ------------------------------------------------------------------
// minReplicas 2, not 1: one replica means every deployment and every node
// recycle is downtime, and it gives the platform nowhere to drain to. Scale to
// zero would be a cold start on a customer request.
param apiMinReplicas = 2
param apiMaxReplicas = 10
param apiCpu = '1.0'
param apiMemory = '2Gi'
param apiConcurrentRequests = 50

// --- SQL ------------------------------------------------------------------
// Provisioned, not serverless: auto-pause resume latency is a user-visible
// stall, and a database that is always warm is the thing being paid for.
// autoPauseDelayMinutes is not set — sqlUseServerless = false makes the
// property illegal, and the module omits it rather than passing -1.
//
// Geo-redundant backups: the difference between losing a region and losing the
// data. Local redundancy is a dev economy, not a production one.
//
// publicNetworkAccess stays Enabled with the AllowAllWindowsAzureIps rule
// rather than Disabled with a private endpoint. Stated plainly: Disabled needs
// a VNet-integrated Container Apps environment, which this subscription's quota
// does not permit, so writing Disabled here would describe an infrastructure
// that cannot exist and has never been tested. The authentication boundary is
// Entra-only auth, which holds regardless of the network path.
// A GROUP, not a person, unlike dev. A production database whose only
// administrator is one named individual loses its administrator when that
// person changes role. This object ID is a placeholder: prod has never been
// deployed, and inventing a group ID that resolves to nothing would look more
// finished than it is.
param sqlEntraAdminObjectId = '00000000-0000-0000-0000-000000000000'
param sqlEntraAdminLogin = 'quotes-sql-admins'
param sqlEntraAdminPrincipalType = 'Group'
param sqlDatabaseName = 'quotes'
param sqlSkuName = 'GP_Gen5'
param sqlSkuTier = 'GeneralPurpose'
param sqlSkuCapacity = 2
param sqlUseServerless = false
param sqlMaxSizeBytes = 34359738368
param sqlBackupStorageRedundancy = 'Geo'
param sqlPublicNetworkAccess = 'Enabled'
// centralindia General Purpose Gen5 does not offer zone redundancy. False here
// is a regional fact, not a cost decision — moving to a region that supports it
// is the change, not flipping this flag.
param sqlZoneRedundant = false

// --- Service Bus ----------------------------------------------------------
// Premium: dedicated resources, predictable latency, and no noisy-neighbour
// throttling. Also the tier that supports private endpoints and geo-DR, which
// is where this would go next.
//
// maxDeliveryCount 5 rather than dev's 3: production transients are worth more
// patience before a message is parked. Still far below the service default of
// 10, which hides a poison message behind ten attempts.
param serviceBusSkuName = 'Premium'
param serviceBusMessagingUnits = 1
param serviceBusMessageTimeToLive = 'P7D'
param serviceBusMaxDeliveryCount = 5
param serviceBusLockDuration = 'PT1M'
