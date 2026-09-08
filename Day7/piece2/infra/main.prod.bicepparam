// Day 24 — prod parameter file.
//
// HONESTY NOTE, READ FIRST: this environment has never been deployed, in either
// subscription. Every value below is a considered choice; none of them is a
// verified one.
//
//   az deployment sub what-if -l <region> -f infra/main.bicep -p infra/main.prod.bicepparam
//
// ---------------------------------------------------------------------------
// PROD IS DEPLOYED, VERIFIED, AND THEN TORN DOWN
// ---------------------------------------------------------------------------
// Not left standing. The target subscription is Azure for Students: roughly
// $100 for twelve months, and it disables itself when that is spent — which is
// precisely what this whole migration is recovering from. A standing production
// environment nobody uses costs a Service Bus namespace, a container registry
// and a warm database every month, and would exhaust the credit again.
//
// Day 24 is about teardown being clean and provable, so prod is where that gets
// proven:
//
//   az stack sub create -n quotes-prod ... --action-on-unmanage deleteAll
//   ... verify ...
//   az stack sub delete -n quotes-prod --action-on-unmanage deleteAll --yes
//   az group exists -n thinkschool-prod-rg      # must print false
//
// A full environment provisioned and removed with nothing orphaned and nothing
// left billing is stronger evidence than a prod that merely exists.
//
// ---------------------------------------------------------------------------
// PROD DIFFERS FROM DEV IN SHAPE, NOT IN TIER — AND THAT IS A CONSTRAINT
// ---------------------------------------------------------------------------
// The Day 23 version of this file specified Premium Service Bus and a
// provisioned 2-vCore SQL database. Together those are more per month than the
// entire student credit, so they are not a production design here; they are a
// design for a subscription that does not exist. Both are reduced below, and
// said out loud rather than quietly matched to dev.
//
// What still distinguishes prod, and all of it is real:
//   * its own Container Apps Environment, not a shared one
//   * a replica floor of 2, so a deployment or a node recycle is not downtime
//   * 90-day retention with NO daily telemetry cap
//   * geo-redundant backups rather than local
//   * a GROUP as database administrator rather than a named person
//   * a more patient redelivery count before dead-lettering
//
// A reader who sees GP_S_Gen5 in both files and no explanation will assume this
// file was copied carelessly. It was not; it was costed.

using './main.bicep'

// ---------------------------------------------------------------------------
// Identity of the deployment
// ---------------------------------------------------------------------------
param environmentName = 'thinkschool-prod'
param environmentType = 'prod'
param resourceGroupName = 'thinkschool-prod-rg'
param apiContainerAppName = 'quotes-api-prod'

// FALSE here, unlike dev, and not by oversight: prod has never been deployed,
// so there is no container app whose running image could be read. It must be
// flipped to true immediately after the first successful deployment, or the
// next infrastructure-only stack update reverts the API to the aci-helloworld
// placeholder. See the long note on this parameter in main.dev.bicepparam,
// which is written from having had it happen.
param quotesApiExists = false

// REPLACE BEFORE DEPLOYING. See the corresponding note in main.dev.bicepparam:
// the region probe that briefly justified 'centralindia' here was invalid, and
// centralindia is not permitted on this subscription at all.
//
// The policy allows:
//   indonesiacentral, malaysiawest, indiasouthcentral, uaenorth, koreacentral
//
// Prod should take the SECOND viable region that Day24/scripts/01-region-fit.ps1
// reports, different from dev's. Not a preference: createContainerAppsEnvironment
// is true in both files, so a shared region puts two Container Apps Environments
// in one place. The old subscription enforced one per region; whether this one
// does is unmeasured. If prod fails with
// MaxNumberOfRegionalEnvironmentsInSubExceeded there are two ways forward, and
// guessing between them wastes a deployment:
//
//   1. A second permitted region (preferred — 01-region-fit.ps1 names them).
//   2. Tear the dev stack down first, deploy prod, verify, tear prod down, then
//      recreate dev. Sound only because prod is torn down anyway (see the
//      header) and because the stack makes both teardowns clean.
// koreacentral — a DIFFERENT region from dev's uaenorth, and that is the point.
// createContainerAppsEnvironment is true in both files, so a shared region would
// put two Container Apps Environments in one place and risk the one-per-region
// limit the old subscription enforced. Two regions sidesteps a constraint that
// has not been measured here rather than discovering it mid-deployment.
// Also mature, unlike the two Southeast Asian alternatives.
param location = 'koreacentral'

// Same mechanism as dev, read from JWT_SECRET at compile time. USE A DIFFERENT
// KEY FROM DEV: sharing one means a dev-issued token is valid in production.
//
// A production signing key belongs in a vault, and the follow-up this file
// implies is a Key Vault module with a secretRef — deliberately out of scope,
// still out of scope, and still worth stating.
param jwtSecret = readEnvironmentVariable('JWT_SECRET', '')

// --- Observability -------------------------------------------------------
// 90 days, and NO daily cap. A quota that is hit drops telemetry, which means
// the one incident big enough to blow the cap is the one you cannot
// investigate. -1 is uncapped, on purpose.
param logRetentionInDays = 90
param logDailyQuotaGb = -1

// --- Container Apps Environment ------------------------------------------
// A dedicated environment, unlike dev. See the note on `location` above for the
// quota interaction this creates.
param createContainerAppsEnvironment = true

// --- API ------------------------------------------------------------------
// CHANGED ON DAY 24. Day 23 specified maxReplicas 10 at 1.0 vCPU — a ten-vCPU
// ceiling.
//
// The primary reason for cutting it is COST, and it is worth being exact about
// that rather than hiding behind a quota. minReplicas 2 at 1.0 vCPU is two
// always-on vCPU billed continuously; at 0.5 it is one. On a fixed $100 credit
// that difference is months of runway.
//
// The secondary reason is quota, and it is UNVERIFIED — stated as such because
// the distinction matters. Azure for Students publishes a regional core limit
// around four, but that is a Microsoft.Compute VM quota and Container Apps
// Consumption does not draw on it; it has its own per-region limit.
// 00-preflight.ps1 could not read either (Microsoft.Compute is not registered
// on this subscription, so `az vm list-usage` returned nothing). Measure the
// one that actually applies once the environment exists:
//
//   az containerapp env list-usages -n <env> -g <rg> -o table
//
// If a quota does bind, it does not fail at deploy time: minReplicas 2 fits
// comfortably, the deployment goes green, and the failure waits until
// scale-out — under the only load that would ever have justified running prod.
//
// 4 x 0.5 vCPU keeps the ceiling inside the quota. minReplicas stays at 2 —
// one replica means every deployment and every node recycle is downtime, and it
// gives the platform nowhere to drain to. Scale to zero would be a cold start
// on a customer request.
param apiMinReplicas = 2
param apiMaxReplicas = 4
param apiCpu = '0.5'
param apiMemory = '1Gi'
param apiConcurrentRequests = 50

// --- SQL ------------------------------------------------------------------
// CHANGED ON DAY 24: serverless, where Day 23 specified provisioned.
//
// The Day 23 reasoning was sound — auto-pause resume latency is a user-visible
// stall, and a database that is always warm is the thing being paid for. It is
// preserved here in the only way this subscription permits: serverless with
// autoPauseDelayMinutes = -1, which disables auto-pause entirely. The database
// stays warm; only the billing model changes, from a fixed monthly reservation
// to per-second while running. What is genuinely lost is the predictable
// monthly cost, which on a fixed credit is the cheaper thing to give up.
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
param sqlSkuName = 'GP_S_Gen5'
param sqlSkuTier = 'GeneralPurpose'
param sqlSkuCapacity = 2
param sqlUseServerless = true
param sqlAutoPauseDelayMinutes = -1
param sqlDatabaseName = 'quotes'
param sqlMaxSizeBytes = 34359738368
param sqlBackupStorageRedundancy = 'Geo'
param sqlPublicNetworkAccess = 'Enabled'

// centralindia General Purpose Gen5 does not offer zone redundancy. False here
// is a regional fact, not a cost decision — moving to a region that supports it
// is the change, not flipping this flag. Re-check it if G1 lands prod somewhere
// else.
param sqlZoneRedundant = false

// A GROUP, not a person, unlike dev. A production database whose only
// administrator is one named individual loses its administrator when that
// person changes role.
//
// REPLACE BEFORE DEPLOYING. Day 23 shipped 00000000-0000-0000-0000-000000000000
// here, which is fine for a what-if and rejected by a real deployment. Create
// the group in the Amity tenant first:
//
//   az ad group create --display-name quotes-sql-admins --mail-nickname quotes-sql-admins
//   az ad group member add --group quotes-sql-admins --member-id (az ad signed-in-user show --query id -o tsv)
//   az ad group show --group quotes-sql-admins --query id -o tsv
//
// If group creation is blocked in that tenant — university tenants often
// restrict it — fall back to the G5 user with principalType 'User' and record
// that as a stated deviation. Do not ship zeros.
// A real group, created in the Amity tenant on 2026-09-08 and resolvable —
// unlike Day 23's 00000000-0000-0000-0000-000000000000, which is fine for a
// what-if and rejected by a deployment.
//
// This was not a given. 00-preflight.ps1 could not read the tenant's
// authorization policy (Graph returned nothing for defaultUserRolePermissions),
// so whether directory writes were permitted was genuinely unknown until
// `az ad app create` was tried and succeeded. Had it been refused, the fallback
// was the dev user with principalType 'User' — a real weakening of the
// production design, and one that would have been recorded as a deviation
// rather than quietly adopted.
//
// Membership is the operational half and is not visible in this file:
//   az ad group member list --group quotes-sql-admins --query "[].userPrincipalName" -o tsv
// An empty group administers nothing.
param sqlEntraAdminObjectId = 'aad084c3-ebcf-495f-9c13-01415848fab4'
param sqlEntraAdminLogin = 'quotes-sql-admins'
param sqlEntraAdminPrincipalType = 'Group'

// --- Service Bus ----------------------------------------------------------
// CHANGED ON DAY 24: Standard, where Day 23 specified Premium.
//
// Premium buys dedicated resources, predictable latency, no noisy-neighbour
// throttling, and the private-endpoint and geo-DR options this would grow into.
// It is billed per messaging unit whether or not a message flows, and it is not
// affordable on this offer — it would consume the entire credit well inside a
// month. The topology is identical either way; what is given up is a latency
// guarantee this workload has never measured a need for.
//
// maxDeliveryCount 5 rather than dev's 3 survives unchanged: production
// transients are worth more patience before a message is parked. Still far
// below the service default of 10, which hides a poison message behind ten
// attempts.
param serviceBusSkuName = 'Standard'
param serviceBusMessagingUnits = 1
param serviceBusMessageTimeToLive = 'P7D'
param serviceBusMaxDeliveryCount = 5
param serviceBusLockDuration = 'PT1M'
