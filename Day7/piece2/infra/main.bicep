// Day 23 — the whole infrastructure of QuotesApi, as one orchestration file.
//
// This file used to be a two-step: create a resource group, call one 13 KB
// module called `resources.bicep` that held every resource in the application.
// It is now the graph and nothing else — every resource lives in a module under
// ./modules, every module is parameterized, and the two .bicepparam files
// beside this one are the only place an environment-specific value appears.
//
// TWO PARAMETER MECHANISMS, ON PURPOSE — READ THIS BEFORE EDITING
//   main.dev.bicepparam / main.prod.bicepparam  — typed, checked at compile
//     time against this file, and what `az deployment sub what-if` runs
//     against. These are the exercise deliverable.
//   main.parameters.json                        — azd's ONLY entrypoint. azd
//     does not read .bicepparam files. It stays as it was so `azd up` keeps
//     working, resolving values from AZURE_ENV_NAME and friends.
// Assuming azd picks up the .bicepparam files is the mistake this note exists
// to prevent. It does not.

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Identity of the deployment
// ---------------------------------------------------------------------------

@minLength(1)
@maxLength(64)
@description('Name of the environment, used to generate a short unique hash for all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Which shape of environment this is. Drives tags and, through the parameter files, every sizing decision.')
@allowed([
  'dev'
  'prod'
])
param environmentType string = 'dev'

@description('Resource group this deployment owns. thinkschool-rg, from the earlier manual-CLI exercise, is deliberately left untouched.')
param resourceGroupName string = 'thinkschool-azd-rg'

// ---------------------------------------------------------------------------
// The application image (threaded through by azd)
// ---------------------------------------------------------------------------

// The pre-Day-23 template declared this and never used it. It has a real job
// now: it decides whether to look up the image the app is already running,
// instead of overwriting it with a placeholder. See modules/fetch-container-image.bicep.
@description('Whether the container app already exists. Set by azd from SERVICE_QUOTES_API_RESOURCE_EXISTS.')
param quotesApiExists bool = false

@description('Fully qualified image reference, set by azd after a build. Empty on the very first deployment.')
param quotesApiImageName string = ''

// ---------------------------------------------------------------------------
// Secrets — supplied at deploy time, never from a parameter file
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Key Vault — Day 25
// ---------------------------------------------------------------------------
// THE jwtSecret PARAMETER USED TO BE HERE. It is gone, and its absence is the
// deliverable.
//
// It was @secure(), which is often read as "handled safely". The narrower
// truth is that @secure() keeps the value out of deployment LOGS while doing
// nothing about the places it has to exist in order to be passed at all: the
// operator's shell and azd .env, the CI runner's environment, and the body of
// the request to the ARM deployment API. Four copies of a value that needs to
// exist in one place.
//
// Now the vault holds it, Day25/scripts/01-seed-jwt-secret.ps1 puts it there
// directly, and this template only ever handles the URI. The long comment that
// used to live here — about @minLength(32) on a pass-through parameter failing
// to compile with BCP333 — went with the parameter. That whole problem was an
// artefact of passing the value through the template, and it stopped existing
// when the value did.
// EMPTY DEFAULT, RESOLVED BELOW, and not a stylistic choice: a parameter
// default cannot reference a variable in Bicep, and the resource token is one.
// Writing the obvious `= '${abbreviations.keyVault}-${resourceToken}'` here
// does not compile.
@description('Name of the key vault. Leave empty to derive it from the resource token, which is what keeps it globally unique. Vault names are 3-24 characters, alphanumerics and hyphens.')
param keyVaultName string = ''

@description('Block early purge of a soft-deleted vault. FALSE in dev, because the deployment stack tears vaults down and a reserved name blocks the next create for up to 90 days. TRUE in prod. See modules/keyvault.bicep.')
param keyVaultPurgeProtection bool = false

@description('Days a soft-deleted vault stays recoverable. 7 in dev, 90 in prod.')
param keyVaultSoftDeleteRetentionInDays int = 7

@description('Name of the secret holding the JWT signing key, inside the vault.')
param jwtSecretName string = 'jwt-secret'

// ---------------------------------------------------------------------------
// Alerting — Day 26
// ---------------------------------------------------------------------------
@description('Where the error-rate alert sends mail. Personal data rather than a secret, so it is set in the parameter file and never defaulted here.')
param alertEmailAddress string = ''

@description('Error-rate percentage that fires the alert. The query refuses to report a rate at all below a minimum request count, so this threshold is measured against real traffic.')
param errorRateThresholdPct int = 5

@description('Deploy the alert and its action group. False leaves both out — useful for an environment nobody is watching, and required when no address is set.')
param deployAlerts bool = true

@description('JWT issuer.')
param jwtIssuer string = 'https://yourapp.com'

@description('JWT audience.')
param jwtAudience string = 'quotes-api'

// ---------------------------------------------------------------------------
// Entra ID — the app's SECOND authentication scheme
// ---------------------------------------------------------------------------
// The pre-Day-23 template set none of these, so the first what-if of the new
// template showed AzureAd__Audience being REMOVED from the running app. That
// would have silently broken one of the two schemes the app selects between per
// request — a regression produced by an infrastructure refactor, which is
// exactly the class of thing what-if is for.
//
// NO DEFAULTS, DELIBERATELY, AND THIS USED TO BE THREE DEFAULTS.
//
// These three carried values copied from appsettings.json: tenant
// f774bb68-…, a client id from a registration in that tenant, and the audience
// 'api://quotes-api/access'. All three were wrong by the time Day 25 finished.
// The registration moved to the tenant that owns the subscription, and the
// audience was a SCOPE rather than an audience — Entra issues tokens whose aud
// is the resource's Application ID URI, with the scope carried in scp.
//
// main.dev.bicepparam was corrected. main.prod.bicepparam overrode none of
// them, so prod would have deployed CLEANLY and authenticated nothing: the
// Entra scheme would fail audience validation on every genuine token, and
// because nothing has sent one yet, no error would appear anywhere. A default
// that is silently wrong is worse than a missing value, because a missing
// value stops the deployment and asks.
//
// So they are required now. Every environment states its own registration, and
// a new environment that forgets fails at deployment time instead of running
// with dev's identity or a dead one. Day25/scripts/02-entra-app-registrations.ps1
// writes these three lines into the parameter file it targets, so nobody
// retypes a GUID.
//
// Still not secrets: a tenant id and a public client id identify an app
// registration, they do not authenticate anything.

@description('Entra ID application (client) ID of the API registration. Required: no default, because a stale default deploys a silently broken auth scheme.')
param azureAdClientId string

@description('Entra ID tenant ID. Required: see azureAdClientId.')
param azureAdTenantId string

@description('Expected audience for Entra-issued tokens — the registration\'s Application ID URI (api://<appId>), NOT a scope. Required: see azureAdClientId.')
param azureAdAudience string

// Derived, not typed out. appsettings.json carries the authority as a literal
// 'https://login.microsoftonline.com/<tenant>/v2.0', and copying that into a
// template trips no-hardcoded-env-urls — a rule this repository sets to error,
// and rightly: that host is the public cloud's, and the same template deployed
// into a sovereign cloud (US Government, China) would authenticate against an
// endpoint that does not serve its tenants. environment() returns the login
// endpoint of whichever cloud the deployment is running in, so the authority is
// correct in all of them without a second parameter file.
//
// loginEndpoint already carries a trailing slash, hence no separator here.
var azureAdAuthority = '${environment().authentication.loginEndpoint}${azureAdTenantId}/v2.0'

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

@description('Days of Log Analytics retention.')
param logRetentionInDays int = 30

@description('Daily Log Analytics ingestion cap in GB. -1 is uncapped. A cap drops data once hit.')
param logDailyQuotaGb int = -1

// ---------------------------------------------------------------------------
// Container Apps Environment
// ---------------------------------------------------------------------------

@description('Create a dedicated environment, or reuse an existing one. Dev reuses thinkschool-env because this subscription permits exactly one environment per region.')
param createContainerAppsEnvironment bool = false

@description('Name of the environment to create or reference.')
param containerAppsEnvironmentName string = 'thinkschool-env'

@description('Resource group of the existing environment. Ignored when creating one.')
param containerAppsEnvironmentResourceGroup string = 'thinkschool-rg'

// ---------------------------------------------------------------------------
// API sizing
// ---------------------------------------------------------------------------

@description('Name of the container app. Must be unique within the Container Apps ENVIRONMENT, which is why this carries a distinguishing suffix on a shared environment.')
param apiContainerAppName string = 'quotes-api-cowork'

@description('Replica floor. 0 is scale-to-zero.')
@minValue(0)
param apiMinReplicas int = 1

@description('Replica ceiling.')
@minValue(1)
param apiMaxReplicas int = 5

@description('vCPU per replica, as a string. Must pair with apiMemory.')
param apiCpu string = '0.5'

@description('Memory per replica.')
param apiMemory string = '1Gi'

@description('Concurrent requests per replica before the scale rule adds one.')
@minValue(1)
param apiConcurrentRequests int = 50

// ---------------------------------------------------------------------------
// Front end
// ---------------------------------------------------------------------------
// Day 24. A SECOND container app, deployed from its own image and its own
// workflow. On the previous subscription this was an Azure Static Web App with
// a linked backend; staticSites is not available in any region this
// subscription permits, so nginx in a container app takes its place. The
// separation is the point, not the hosting technology: a front-end change must
// not rebuild the API, and a broken bundle must not be able to take the API
// down with it.

@description('Name of the front-end container app. Unique within the Container Apps ENVIRONMENT.')
param webContainerAppName string = 'quotes-web-dev'

@description('Whether the front-end container app already exists, so its running image is read rather than overwritten. Same mechanism, and the same trap, as quotesApiExists.')
param webAppExists bool = false

@description('Fully qualified front-end image reference, supplied by its deployment. Empty on the very first deployment.')
param webImageName string = ''

@description('Replica floor for the front end. Scale-to-zero costs far less here than on the API: nginx serving static files starts in well under a second.')
@minValue(0)
param webMinReplicas int = 0

@description('Replica ceiling for the front end.')
@minValue(1)
param webMaxReplicas int = 2

// ---------------------------------------------------------------------------
// SQL
// ---------------------------------------------------------------------------

@description('Object ID of the Entra principal that becomes the SQL administrator. There is no SQL login — see modules/sql.bicep.')
param sqlEntraAdminObjectId string

@description('Display name of that Entra administrator.')
param sqlEntraAdminLogin string

@description('Entra principal type of the SQL administrator.')
@allowed([
  'User'
  'Group'
  'Application'
])
param sqlEntraAdminPrincipalType string = 'User'

@description('Database name.')
param sqlDatabaseName string = 'quotes'

@description('SKU name, e.g. GP_S_Gen5 for serverless or GP_Gen5 for provisioned.')
param sqlSkuName string = 'GP_S_Gen5'

@description('SKU tier.')
param sqlSkuTier string = 'GeneralPurpose'

@description('vCores.')
@minValue(1)
param sqlSkuCapacity int = 1

@description('Whether the chosen SKU is serverless. Auto-pause properties are illegal on a provisioned SKU.')
param sqlUseServerless bool = true

@description('Minutes of inactivity before a serverless database pauses. -1 disables auto-pause.')
param sqlAutoPauseDelayMinutes int = 60

@description('Maximum database size in bytes.')
param sqlMaxSizeBytes int = 2147483648

@description('Backup storage redundancy.')
@allowed([
  'Local'
  'Zone'
  'Geo'
  'GeoZone'
])
param sqlBackupStorageRedundancy string = 'Local'

@description('Whether the server answers on its public endpoint.')
@allowed([
  'Enabled'
  'Disabled'
])
param sqlPublicNetworkAccess string = 'Enabled'

@description('Zone redundancy. centralindia General Purpose does not offer it, so both parameter files pass false.')
param sqlZoneRedundant bool = false

@description('Client IPs allowed through the SQL firewall — administrator machines, not the app. Supplied from the environment rather than a parameter file: an IP address is personal data and a home address changes.')
param sqlAllowedClientIpAddresses array = []

// ---------------------------------------------------------------------------
// Service Bus
// ---------------------------------------------------------------------------

@description('SKU. Basic is not representable — it has queues only, and this topology is topic-based.')
@allowed([
  'Standard'
  'Premium'
])
param serviceBusSkuName string = 'Standard'

@description('Messaging units. Premium only.')
param serviceBusMessagingUnits int = 1

@description('Message TTL, ISO 8601.')
param serviceBusMessageTimeToLive string = 'P7D'

@description('Deliveries before dead-lettering.')
@minValue(1)
param serviceBusMaxDeliveryCount int = 3

@description('Lock duration, ISO 8601, max PT5M.')
param serviceBusLockDuration string = 'PT1M'

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

var abbreviations = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))

// Day 25. 'kv-' plus a 13-character token is 16 characters, inside Key Vault's
// 24-character ceiling with room to spare.
var resolvedKeyVaultName = empty(keyVaultName) ? '${abbreviations.keyVault}-${resourceToken}' : keyVaultName

var tags = {
  'azd-env-name': environmentName
  'environment-type': environmentType
}

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Modules, in dependency order
// ---------------------------------------------------------------------------

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    logAnalyticsWorkspaceName: '${abbreviations.logAnalyticsWorkspace}${resourceToken}'
    applicationInsightsName: '${abbreviations.applicationInsights}-quotes-api-${resourceToken}'
    location: location
    tags: tags
    retentionInDays: logRetentionInDays
    dailyQuotaGb: logDailyQuotaGb

    // Day 25. Creates the Monitoring Metrics Publisher grant, which App
    // Insights now requires because the module disables local auth. Passing an
    // output from `identity` also makes Bicep order the two modules correctly,
    // regardless of the fact that monitoring is declared first in this file.
    telemetryPublisherPrincipalId: identity.outputs.identityPrincipalId
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: {
    managedIdentityName: '${abbreviations.managedIdentity}-quotes-api-${resourceToken}'
    location: location
    tags: tags
  }
}

// The vault is created EMPTY. Nothing here writes a secret into it, because a
// template that can write the value is a template that has to be given the
// value. Day25/scripts/01-seed-jwt-secret.ps1 fills it.
//
// Consequence worth stating: on a brand-new environment the API's revision
// cannot provision until that script has run, because its Key Vault reference
// resolves at revision creation. Deploy, seed, redeploy — in that order, once,
// per environment.
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyVault'
  scope: rg
  params: {
    keyVaultName: resolvedKeyVaultName
    location: location
    tags: tags
    appPrincipalId: identity.outputs.identityPrincipalId
    enablePurgeProtection: keyVaultPurgeProtection
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionInDays
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  scope: rg
  params: {
    containerRegistryName: '${abbreviations.containerRegistry}${resourceToken}'
    location: location
    tags: tags
    pullIdentityResourceId: identity.outputs.identityResourceId
    pullIdentityPrincipalId: identity.outputs.identityPrincipalId

    // Day 25. False is also the module's default now; it is repeated here
    // because a security property that depends on a default being left alone
    // is one refactor away from being on again, and nothing would report it.
    adminUserEnabled: false
  }
}

// Symbol deliberately NOT called `environment`: that is the name of a Bicep
// built-in function, and shadowing it is a compile error waiting to happen.
module containerAppsEnvironment 'modules/environment.bicep' = {
  name: 'containerAppsEnvironment'
  scope: rg
  params: {
    createEnvironment: createContainerAppsEnvironment
    environmentResourceName: createContainerAppsEnvironment
      ? '${abbreviations.containerAppsEnvironment}-${resourceToken}'
      : containerAppsEnvironmentName
    existingEnvironmentResourceGroup: containerAppsEnvironmentResourceGroup
    location: location
    tags: tags
    logAnalyticsWorkspaceName: monitoring.outputs.logAnalyticsWorkspaceName
  }
}

module sql 'modules/sql.bicep' = {
  name: 'sql'
  scope: rg
  params: {
    sqlServerName: '${abbreviations.sqlServer}-quotes-${resourceToken}'
    databaseName: sqlDatabaseName
    location: location
    tags: tags
    entraAdminObjectId: sqlEntraAdminObjectId
    entraAdminLogin: sqlEntraAdminLogin
    entraAdminPrincipalType: sqlEntraAdminPrincipalType
    appIdentityClientId: identity.outputs.identityClientId
    skuName: sqlSkuName
    skuTier: sqlSkuTier
    skuCapacity: sqlSkuCapacity
    useServerless: sqlUseServerless
    autoPauseDelayMinutes: sqlAutoPauseDelayMinutes
    maxSizeBytes: sqlMaxSizeBytes
    zoneRedundant: sqlZoneRedundant
    backupStorageRedundancy: sqlBackupStorageRedundancy
    publicNetworkAccess: sqlPublicNetworkAccess
    allowAzureServices: true
    allowedClientIpAddresses: sqlAllowedClientIpAddresses
  }
}

module serviceBus 'modules/servicebus.bicep' = {
  name: 'serviceBus'
  scope: rg
  params: {
    namespaceName: '${abbreviations.serviceBusNamespace}-quotes-${resourceToken}'
    location: location
    tags: tags
    skuName: serviceBusSkuName
    messagingUnits: serviceBusMessagingUnits
    defaultMessageTimeToLive: serviceBusMessageTimeToLive
    maxDeliveryCount: serviceBusMaxDeliveryCount
    lockDuration: serviceBusLockDuration
    appPrincipalId: identity.outputs.identityPrincipalId
  }
}

// The application's whole configuration surface, in one readable block. Every
// name on the left is a key in QuotesApi/appsettings.json with ':' spelled as
// '__' — that is the environment-variable spelling of the separator, not a
// convention this template invented.
var apiEnvironmentVariables = [
  {
    name: 'ASPNETCORE_ENVIRONMENT'
    value: 'Production'
  }

  // Day 25. NAMES WHICH IDENTITY DefaultAzureCredential SHOULD PRESENT, and it
  // is load-bearing rather than tidy.
  //
  // A container app can carry several identities. DefaultAzureCredential is
  // handed no hint about which one is meant, so with more than one attached it
  // picks by its own precedence order and the wrong choice presents as an
  // authorization failure that reads exactly like a missing role assignment.
  // It resolved correctly until now only because exactly one identity happens
  // to be attached — an accident, not a design.
  //
  // The SQL path never had this problem: the connection string names the
  // identity itself, via User Id=<client id>. The Service Bus client, the
  // Key Vault configuration provider and (as of Day 25) the Azure Monitor
  // exporter all go through DefaultAzureCredential and had no such hint.
  {
    name: 'AZURE_CLIENT_ID'
    value: identity.outputs.identityClientId
  }
  {
    name: 'Jwt__Issuer'
    value: jwtIssuer
  }
  {
    name: 'Jwt__Audience'
    value: jwtAudience
  }
  {
    name: 'ConnectionStrings__DefaultConnection'
    value: sql.outputs.connectionString
  }
  {
    name: 'AzureAd__Authority'
    value: azureAdAuthority
  }
  {
    name: 'AzureAd__ClientId'
    value: azureAdClientId
  }
  {
    name: 'AzureAd__TenantId'
    value: azureAdTenantId
  }
  {
    name: 'AzureAd__Audience'
    value: azureAdAudience
  }
  {
    name: 'Outbox__RelayEnabled'
    value: 'true'
  }
  {
    name: 'ServiceBus__Enabled'
    value: 'true'
  }
  {
    name: 'ServiceBus__FullyQualifiedNamespace'
    value: serviceBus.outputs.namespaceFqdn
  }
  {
    name: 'ServiceBus__TopicName'
    value: serviceBus.outputs.topicName
  }
  {
    name: 'ServiceBus__AuditSubscription'
    value: serviceBus.outputs.auditSubscriptionName
  }
  {
    name: 'ServiceBus__SearchIndexSubscription'
    value: serviceBus.outputs.searchIndexSubscriptionName
  }
  // ApplicationInsights__ConnectionString is what actually turns telemetry on
  // here — ObservabilityExtensions reads that exact key and passes it to
  // UseAzureMonitor() explicitly. APPLICATIONINSIGHTS_CONNECTION_STRING is the
  // Azure Monitor distro's own auto-discovery variable, which this app never
  // reads; it is set anyway so the Container App looks the way Azure tooling
  // and the standard docs expect. Not a secretRef: the string carries an
  // ingestion key, which grants write-only access to this component.
  {
    name: 'ApplicationInsights__ConnectionString'
    value: monitoring.outputs.applicationInsightsConnectionString
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: monitoring.outputs.applicationInsightsConnectionString
  }
]

// Reads what the app is running now, so an infrastructure-only deployment
// cannot revert it to the placeholder. See the module header.
module fetchLatestImage 'modules/fetch-container-image.bicep' = {
  name: 'fetchLatestImage'
  scope: rg
  params: {
    exists: quotesApiExists
    containerAppName: apiContainerAppName
  }
}

// Three choices, in order: an explicitly supplied image, the one already
// running, and only then the placeholder. The safe-dereference operators matter
// — `containers` is an empty array when the app does not exist yet, and
// indexing an empty array is an error rather than a fallback.
var placeholderImage = 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'
var resolvedApiImage = !empty(quotesApiImageName)
  ? quotesApiImageName
  : (fetchLatestImage.outputs.?containers[?0].image ?? placeholderImage)

module api 'modules/api.bicep' = {
  name: 'api'
  scope: rg
  params: {
    containerAppName: apiContainerAppName
    location: location
    // azd finds the service to deploy by this tag, not by the app's name.
    tags: union(tags, { 'azd-service-name': 'quotes-api' })
    containerAppsEnvironmentId: containerAppsEnvironment.outputs.environmentId
    userAssignedIdentityResourceId: identity.outputs.identityResourceId
    containerRegistryLoginServer: registry.outputs.containerRegistryLoginServer
    imageName: resolvedApiImage
    minReplicas: apiMinReplicas
    maxReplicas: apiMaxReplicas
    cpu: apiCpu
    memory: apiMemory
    concurrentRequests: apiConcurrentRequests
    env: apiEnvironmentVariables

    // Depending on this module OUTPUT is what orders the deployment: the
    // container app is not created until the vault and its role assignment
    // are. Ordering is not the same as effectiveness, though — RBAC needs a
    // little time to propagate, so a first deployment may still need one
    // retry. See the note on the secrets block in modules/api.bicep.
    jwtSecretUri: '${keyVault.outputs.keyVaultUri}secrets/${jwtSecretName}'
  }
}

// ---------------------------------------------------------------------------
// Alerting — Day 26
// ---------------------------------------------------------------------------
// GUARDED ON THE ADDRESS, NOT JUST THE FLAG. An action group with no receiver
// deploys happily and notifies nobody, which is the failure mode alerting
// exists to prevent — so an empty alertEmailAddress skips the whole module
// rather than producing a rule that looks configured and is not.
module alerts 'modules/alerts.bicep' = if (deployAlerts && !empty(alertEmailAddress)) {
  name: 'alerts'
  scope: rg
  params: {
    alertRuleName: 'quotes-error-rate-${environmentType}'
    actionGroupName: 'quotes-oncall-${environmentType}'
    actionGroupShortName: 'quotes${environmentType}'
    alertEmailAddress: alertEmailAddress
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    location: location
    tags: tags
    errorRateThresholdPct: errorRateThresholdPct

    // The SAME file the operator runs by hand, so the alert and the
    // investigation cannot disagree about what an error rate is.
    alertQuery: loadTextContent('../../../Day26/kql/03-error-rate.kql')
  }
}

// ---------------------------------------------------------------------------
// The front end
// ---------------------------------------------------------------------------
// Same image-preservation dance as the API, for the same reason: an
// infrastructure-only stack update must not revert a deployed bundle to the
// placeholder. See modules/fetch-container-image.bicep and the note on
// quotesApiExists in main.dev.bicepparam.
module fetchLatestWebImage 'modules/fetch-container-image.bicep' = {
  name: 'fetchLatestWebImage'
  scope: rg
  params: {
    exists: webAppExists
    containerAppName: webContainerAppName
  }
}

var resolvedWebImage = !empty(webImageName)
  ? webImageName
  : (fetchLatestWebImage.outputs.?containers[?0].image ?? placeholderImage)

module web 'modules/web.bicep' = {
  name: 'web'
  scope: rg
  params: {
    containerAppName: webContainerAppName
    location: location
    // azd-service-name is deliberately ABSENT. azure.yaml declares one service,
    // quotes-api, and azd finds it by that tag. Tagging this app too would make
    // azd try to deploy the .NET project into it. The front end is deployed by
    // its own workflow, not by azd -- which is what separate deployments means.
    tags: tags
    containerAppsEnvironmentId: containerAppsEnvironment.outputs.environmentId
    userAssignedIdentityResourceId: identity.outputs.identityResourceId
    containerRegistryLoginServer: registry.outputs.containerRegistryLoginServer
    imageName: resolvedWebImage
    // The API's own URL, read from the module that just created it rather than
    // written down anywhere. nginx proxies /api and /health here, so the browser
    // stays same-origin and environment.production.ts keeps apiBaseUrl = ''.
    apiBaseUrl: api.outputs.containerAppUri
    minReplicas: webMinReplicas
    maxReplicas: webMaxReplicas
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
// NAMES, NOT SECRETS. azd writes template outputs into .azure/<env>/.env, and
// .azure is not in this repository's .gitignore — so a connection string
// emitted here would land in source control. The SQL connection string is not
// output for the same reason, even though it carries no credential: it is not
// needed outside the deployment, and the rule is easier to keep than to
// qualify.

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = subscription().tenantId
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.containerRegistryLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.containerRegistryName
output SERVICE_QUOTES_API_IDENTITY_PRINCIPAL_ID string = identity.outputs.identityPrincipalId
output SERVICE_QUOTES_API_IDENTITY_NAME string = identity.outputs.identityName
output SERVICE_QUOTES_API_NAME string = api.outputs.containerAppName
output SERVICE_QUOTES_API_URI string = api.outputs.containerAppUri
output APPLICATIONINSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output AZURE_LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.logAnalyticsWorkspaceName
// Emitted so a promotion script can find the vault it must seed. The vault is
// created empty by design, so the FIRST deploy of any new environment leaves
// the API unable to resolve its jwt-secret reference until something seeds it
// -- and that something needs the name. Without this output the operator reads
// it out of the portal, which is how a secret gets written into the wrong
// environment's vault.
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.keyVaultName

output AZURE_SQL_SERVER_FQDN string = sql.outputs.sqlServerFqdn
output AZURE_SQL_DATABASE_NAME string = sql.outputs.databaseName
output AZURE_SERVICE_BUS_FQDN string = serviceBus.outputs.namespaceFqdn
output SERVICE_QUOTES_WEB_NAME string = web.outputs.containerAppName
output SERVICE_QUOTES_WEB_URI string = web.outputs.containerAppUri
