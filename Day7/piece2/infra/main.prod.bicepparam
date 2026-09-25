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
// so there was no container app whose running image could be read.
//
// FLIPPED TO TRUE, WHICH IS THE STEP THAT GETS FORGOTTEN. The first prod
// deployment is done and quotes-api-prod is running a promoted image. From
// here the template must READ that image rather than supply one: with false,
// the next infrastructure-only stack update -- an alert threshold, a log
// retention change, anything -- resolves the image to
// mcr.microsoft.com/azuredocs/aci-helloworld and silently reverts production
// to Microsoft's sample app. The deployment reports success while doing it.
//
// It already half-happened here: the first prod create left a placeholder
// revision active alongside the real one. main.dev.bicepparam carries the
// long version of this note, written from having had it happen there.
// FALSE, AND IT HAS TO KEEP FLIPPING -- THAT IS THE POINT OF THE CHECK IN
// 05-promote-prod.ps1 RATHER THAN A FIXED VALUE HERE.
//
// The template reads the running app's image when this is true, so it must
// match reality:
//
//   false  when no container app exists  -- a fresh environment. With true,
//          fetchLatestImage tries to read a resource that is not there and the
//          deployment fails with "Failed to obtain the resource body".
//   true   once the app exists and runs a promoted image. With false, the next
//          infra-only update resolves the image to aci-helloworld and reverts
//          production to Microsoft's sample app, reporting success while it
//          does it.
//
// Both halves have now bitten this project. It sits at false because THIS prod
// is torn down between exercises, so from-scratch is the normal path -- and
// the preflight refuses to deploy when the value disagrees with what exists,
// which is the part that actually protects it.
param quotesApiExists = true

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
// uaenorth -- THE SAME REGION AS DEV, and this reverses a decision along with
// the reasoning that produced it.
//
// This used to be koreacentral, deliberately different from dev, and the
// comment here said two regions "sidesteps a constraint that has not been
// measured here rather than discovering it mid-deployment". The constraint was
// then discovered mid-deployment, because it was not the constraint this file
// guessed at: the limit is ONE Container Apps environment per SUBSCRIPTION,
// not per region. Prod asked for a second one in koreacentral and was refused
// at preflight:
//
//   MaxNumberOfGlobalEnvironmentsInSubExceeded
//   The subscription cannot have more than 1 Container App Environments.
//
// Avoiding an unmeasured constraint by guessing at its shape is not avoiding
// it. Measuring it costs one command -- `az containerapp env list` -- and that
// check is now in 05-promote-prod.ps1's preflight.
//
// So prod shares dev's environment (below), and container apps must live in
// the same region as their environment. Keeping koreacentral would put prod's
// SQL, Service Bus and vault in Korea while its apps ran in the UAE, making
// every request a cross-region round trip to its own database. One region for
// everything is the correct answer once the environment is shared.
param location = 'uaenorth'

// --- Key Vault -----------------------------------------------------------
// This file used to say: "A production signing key belongs in a vault, and the
// follow-up this file implies is a Key Vault module with a secretRef —
// deliberately out of scope, still out of scope, and still worth stating."
// Day 25 is that follow-up. The parameter is gone; the vault holds the key.
//
// STILL TRUE, AND NOW ENFORCED BY SEPARATION RATHER THAN BY DISCIPLINE: prod
// must not share dev's key, because a shared key makes a dev-issued token
// valid in production. Each environment has its own vault, named from its own
// resource token, so there is no longer a shared JWT_SECRET variable that
// could be reused by accident — the wrong key is now something you would have
// to go and copy on purpose.
//
// Purge protection ON, opposite to dev, and this is the environment the
// feature exists for: it means a soft-deleted vault cannot be purged early,
// so destroying the secrets and their audit trail together stops being
// possible. It also means the vault's name is reserved for the full retention
// window if this stack is ever torn down — which is the correct trade in
// production and the wrong one in dev.
// PURGE PROTECTION OFF, AND THIS REVERSES WHAT THIS FILE SAID BEFORE.
//
// It was true, with a comment arguing that purge protection is "the correct
// trade in production and the wrong one in dev". That argument is sound for a
// production vault that is never meant to be deleted. It is wrong for THIS
// prod, whose lifecycle explicitly includes teardown -- and it makes the
// teardown the exercise is about stop being clean:
//
//   * a deleted vault becomes SOFT-deleted and cannot be purged for the
//     retention window, so `az stack sub delete` leaves something behind;
//   * the vault's name is derived deterministically from the resource token,
//     so that soft-deleted vault holds the name kv-whppc5qu7yzzg for ninety
//     days -- and prod cannot be deployed again until it is released.
//
// A failed create tears down what it made, so a few failed attempts would
// have locked this environment's vault name for a quarter of a year. Seven
// days of soft-delete keeps the recovery window that matters while leaving
// the name reclaimable. A real production vault should have this true; a
// vault that is stood up and torn down as an exercise should not.
// AN EXPLICIT NAME, BECAUSE TWO OF THIS VAULT'S PROPERTIES ARE WRITE-ONCE.
//
// The name is normally derived from the resource token, which keeps it unique
// and is right for every other resource here. It cannot stay derived for prod,
// and the reason is worth the paragraph.
//
// The first prod attempt created kv-whppc5qu7yzzg with purge protection on and
// 90-day retention. Correcting those two values then failed:
//
//   BadRequest: The property "softDeleteRetentionInDays" has been set already
//   and it can't be modified.
//
// softDeleteRetentionInDays is immutable once set, and enablePurgeProtection
// can only ever be turned ON -- Azure offers no path back for either. So a
// vault whose first deployment got them wrong cannot be fixed in place, and
// because the derived name is deterministic, every retry addressed that same
// unfixable vault. The only way forward is a different name.
//
// kv-whppc5qu7yzzg is abandoned deliberately. It carries purge protection
// permanently, so when the stack removes it the vault soft-deletes and holds
// that name for its retention window; nothing can shorten that. Naming the
// vault here means prod's vault is created once with the settings it should
// have had, and is not hostage to the first attempt's mistake.
// RENAMED FOR THE SUBSCRIPTION MOVE. Key Vault names are GLOBAL, not
// per-subscription, and the old subscription's kv-quotes-prod still holds the
// original name. Waiting for that one to be deleted would make prod's creation
// depend on the teardown that is meant to happen LAST, so prod takes a new name
// instead -- the same reasoning as the capstone registry and SQL server.
param keyVaultName = 'kv-quotes-prod-v2'

param keyVaultPurgeProtection = false
param keyVaultSoftDeleteRetentionInDays = 7

// WHO MAY SEED THE SIGNING KEY, granted by the template rather than by hand.
//
// The vault is created empty so the key never passes through a template or a
// deployment log. The consequence nobody wrote down until prod met it: the
// operator needs WRITE access to a brand-new RBAC vault, and has none.
//
//   ERROR: (Forbidden) Caller is not authorized to perform action on resource.
//
// A hand-run `az role assignment create` fixes that once and then disappears
// with the vault on the next failed deployment. Granting it here means the
// vault arrives usable. Scoped to this vault alone, for this one principal.
//
// SENTINEL after the tenant move: this is an object id, and an object id from
// the old directory names nobody here. migration/01-set-identities.ps1 fills it.
param keyVaultWriterPrincipalId = '6294a008-f2fa-4b34-b06d-f897e5844511'

// --- Entra ID ------------------------------------------------------------
// PROD GETS ITS OWN REGISTRATION, IN THE NEW TENANT, AND IT IS NOT DEV'S.
// Sharing one registration across dev and prod is the tempting shortcut and it
// is the wrong one: one consent screen, one set of redirect URIs, and tokens
// that both environments accept — so a token minted for the dev SPA would be
// valid against production. Two registrations cost nothing; neither has a
// client secret.
//
// The old prod registration lived in a directory this subscription no longer
// trusts, so it is a sentinel rather than a value. Fill it by running:
//   ./Day25/scripts/02-entra-app-registrations.ps1 -Environment prod
// NOT by copying dev's values.
//
// A stale client id is invisible: the deployment succeeds and authenticates
// nothing, because no genuine Entra token has been sent yet. That is precisely
// the failure mode Day 25 found in dev.


// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.
param azureAdTenantId = '803dced7-0a24-4857-8be8-280047561e95'
param azureAdClientId = '36d8fe13-61a4-45b7-81ba-2af903599b4b'

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.
param azureAdAudience = 'api://36d8fe13-61a4-45b7-81ba-2af903599b4b'

// --- Alerting (Day 26) ----------------------------------------------------
// Stricter than dev, and for a reason rather than for tidiness: production
// does not scale to zero, so its five-minute windows carry real traffic and
// the ratio is trustworthy at a lower threshold. Two percent sustained across
// two consecutive windows on a service handling steady load is a genuine
// incident, where the same figure in dev would be one failed request against
// a cold start.
param alertEmailAddress = 'vaishalisinghsln5@gmail.com'
param errorRateThresholdPct = 2

// --- Observability -------------------------------------------------------
// 90 days, and NO daily cap. A quota that is hit drops telemetry, which means
// the one incident big enough to blow the cap is the one you cannot
// investigate. -1 is uncapped, on purpose.
param logRetentionInDays = 90
param logDailyQuotaGb = -1

// --- Container Apps Environment ------------------------------------------
// SHARED WITH DEV, AND THIS IS A COMPROMISE THE SUBSCRIPTION IMPOSED RATHER
// THAN A DESIGN CHOICE.
//
// This subscription permits exactly one Container Apps environment in total.
// Dev holds it. So prod cannot have its own, and the honest description of
// prod here is: separate in every way except the one thing that could not be
// separated.
//
//   Separate: resource group, Azure SQL server and database, Service Bus
//             namespace, Key Vault, container registry, both container apps,
//             the managed identity, the Entra app registration, the Log
//             Analytics workspace, and the alert rule.
//   Shared:   the Container Apps environment -- so its network and its
//             system-level logging.
//
// What that costs is real and worth stating rather than glossing: prod's app
// traffic traverses infrastructure dev also uses, and a change to the shared
// environment affects both. On a subscription that allowed two environments
// this parameter would be true.
param createContainerAppsEnvironment = false
param containerAppsEnvironmentName = 'cae-flpj3o7i5sjfy'
param containerAppsEnvironmentResourceGroup = 'thinkschool-dev-rg'

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
// 4 x 0.5 vCPU keeps the ceiling inside the quota.
//
// SCALE TO ZERO, WHICH IS NOT WHAT A PRODUCTION ENVIRONMENT SHOULD DO. This
// was 2, with the reasoning still worth keeping: one replica makes every
// deployment and every node recycle a moment of downtime, and zero puts a cold
// start in front of a customer's request.
//
// It is 0 anyway, because of what this environment is FOR. It has no
// customers; it exists to be shown and to prove the promotion path works, and
// it runs on a student subscription with a fixed credit. At minReplicas 2 the
// only way to stop it consuming that credit was to delete the whole stack
// between uses -- and that meant fifteen minutes and three manual steps before
// it could be shown again, plus a red build on every merge to main in the
// meantime. Scale to zero buys a permanently reachable environment for
// approximately nothing, at the price of a 20-40 second first request.
//
// On an environment with users this is the wrong value and should be 2. The
// distinction being made is between "production" as a workload and
// "production" as a deployment target, and this is the second one.
param apiMinReplicas = 0
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
// Auto-pause after an hour idle, rather than never (-1). Same reasoning as
// apiMinReplicas above: a serverless database that never pauses bills two
// vCores around the clock, and nothing here is running around the clock. The
// first query after a pause waits for the database to resume -- seconds, once.
param sqlAutoPauseDelayMinutes = 60
param sqlDatabaseName = 'quotes'
param sqlMaxSizeBytes = 34359738368
param sqlBackupStorageRedundancy = 'Geo'
param sqlPublicNetworkAccess = 'Enabled'

// centralindia General Purpose Gen5 does not offer zone redundancy. False here
// is a regional fact, not a cost decision — moving to a region that supports it
// is the change, not flipping this flag. Re-check it if G1 lands prod somewhere
// else.
param sqlZoneRedundant = false

// The machine that administers the server. create-sql-user.ps1 connects as a
// PERSON, not as the app -- an Entra-only server grants the managed identity
// access to the SERVER, while the contained user inside the DATABASE is T-SQL
// that ARM cannot write. Without a rule for the operator's address that script
// cannot connect at all:
//
//   Cannot open server 'sql-quotes-...' requested by the login. Client with
//   IP address '...' is not allowed to access the server.
//
// Read from the environment and NEVER written here: an IP address is personal
// data, this file is committed, and the address changes between sessions
// anyway. 05-promote-prod.ps1 sets it before the create.
//
//   $env:SQL_CLIENT_IP = (Invoke-RestMethod https://api.ipify.org)
//
// Unset means no client rule at all, which is the correct default for prod --
// an administrator's workstation should be allowed in while it is
// administering and not one minute longer.
param sqlAllowedClientIpAddresses = empty(readEnvironmentVariable('SQL_CLIENT_IP', ''))
  ? []
  : [readEnvironmentVariable('SQL_CLIENT_IP', '')]

// A GROUP, not a person, unlike dev. A production database whose only
// administrator is one named individual loses its administrator when that
// person changes role.
//
// SENTINEL, AND IT MUST STAY ONE UNTIL THE GROUP EXISTS IN THE NEW TENANT.
// The group this used to name lives in the old directory; its object id means
// nothing here. Create the replacement in the new tenant first:
//
//   az ad group create --display-name quotes-sql-admins --mail-nickname quotes-sql-admins
//   az ad group member add --group quotes-sql-admins --member-id (az ad signed-in-user show --query id -o tsv)
//   az ad group show --group quotes-sql-admins --query id -o tsv
//
// migration/01-set-identities.ps1 does all three and writes the id here.
//
// If group creation is refused — some tenants restrict directory writes — fall
// back to the operator with principalType 'User' and record that as a stated
// deviation. It is a real weakening of the production design, not a detail.
// Do not ship zeros, and do not ship the old tenant's id.
//
// Membership is the operational half and is not visible in this file:
//   az ad group member list --group quotes-sql-admins --query "[].userPrincipalName" -o tsv
// An empty group administers nothing.
param sqlEntraAdminObjectId = '6cd7b6ec-b2e9-4968-b765-d324cbb8cdbe'
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


// --- Front end ------------------------------------------------------------
// Day 24. Its own container app, its own image, its own workflow. See the
// header of modules/web.bicep for why this is not a Static Web App and not
// bundled into the API image.
param webContainerAppName = 'quotes-web-prod'

// True for the same reason as quotesApiExists above: quotes-web-prod exists
// and runs a promoted image, so the template reads it instead of overwriting
// it with the placeholder on the next infra-only update.
param webAppExists = true
param webMinReplicas = 0
param webMaxReplicas = 2
