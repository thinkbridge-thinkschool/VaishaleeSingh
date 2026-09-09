// Log Analytics workspace + workspace-based Application Insights.
//
// Extracted from the flat resources.bicep on Day 23. The reasoning below is
// carried over from where it was originally written, because it is still the
// reason these two resources exist and are shaped this way.
//
// A workspace-based Application Insights component does not hold its own data:
// `requests`, `dependencies`, `traces` and the rest are tables in THIS
// workspace, which is what the KQL in docs/day5-appinsights-submission.md
// actually queries. Classic (non-workspace) components were retired, so there
// is no version of this that skips the workspace.
//
// PARAMETERIZED ON DAY 23: retention and the daily ingestion cap. Both are cost
// controls, and both want opposite answers in dev and prod — a 1 GB/day cap is
// a sensible guard on a training subscription and a telemetry-losing bug in
// production, which is exactly why it is a parameter and not a default.

targetScope = 'resourceGroup'

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component.')
param applicationInsightsName string

@description('Location for both resources.')
param location string

@description('Tags applied to both resources.')
param tags object

@description('Days of log retention. 30 is the included, no-extra-cost default; anything above it is billed.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily ingestion cap in GB. -1 means uncapped. A cap DROPS data once hit — never set one in production.')
param dailyQuotaGb int = -1

@description('Principal (object) ID of the identity that publishes telemetry. Empty skips the grant — which, with disableLocalAuth below, means nothing can send telemetry at all, so it is empty only for a deployment that has no app yet.')
param telemetryPublisherPrincipalId string = ''

// Monitoring Metrics Publisher. A fixed, well-known role definition GUID — the
// same in every tenant — and the role Application Insights requires for
// ingestion once local auth is off. It covers traces and logs as well as the
// name suggests metrics alone.
var metricsPublisherRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb'

var grantPublish = !empty(telemetryPublisherPrincipalId)

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      // PerGB2018 is the only generally-available SKU for new workspaces.
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
  }
}

// The ingestion endpoint QuotesApi's OpenTelemetry setup exports to.
//
// ObservabilityExtensions.cs wires UseAzureMonitor() ONLY when a connection
// string is present, and registers the ASP.NET Core and HttpClient
// instrumentation itself only when it is absent (the Azure Monitor distro
// brings its own; registering both would double-count every request). So the
// connection string is not just configuration — it is the switch that selects
// which of the two telemetry pipelines the app runs.
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'

    // Day 25. THIS IS WHAT TURNS THE CONNECTION STRING FROM A CREDENTIAL INTO
    // AN ADDRESS, and it is the whole reason the connection string may keep
    // sitting in the container app's environment in plain sight.
    //
    // An Application Insights connection string carries
    // InstrumentationKey=<guid>. With local auth enabled that key is a bearer
    // credential: anyone holding it can write telemetry into this component
    // from anywhere on the internet, with no identity and no audit trail, and
    // poisoned telemetry is a genuinely nasty thing to debug because the
    // graphs stay plausible. Off, ingestion requires an Entra token and the
    // key is reduced to naming which component to talk to.
    //
    // Prefer this to putting the connection string in Key Vault. Vaulting it
    // would store a working credential more carefully; this stops it being a
    // credential.
    //
    // THE COST, STATED: an app that does not present a token stops being able
    // to send telemetry the moment this flips, and it does not fail loudly —
    // it fails as an absence of data. The app-side half is the Credential on
    // UseAzureMonitor() in ObservabilityExtensions.cs, and that half depends
    // in turn on AZURE_CLIENT_ID being set on the container app, because
    // DefaultAzureCredential cannot otherwise tell which user-assigned
    // identity to present. Those three changes are one change.
    DisableLocalAuth: true
  }
}

// Without this the app authenticates and is then refused, which surfaces as
// silence in the telemetry rather than as an error anywhere useful.
resource metricsPublisherRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantPublish) {
  name: guid(applicationInsights.id, telemetryPublisherPrincipalId, 'MonitoringMetricsPublisher')
  scope: applicationInsights
  properties: {
    principalId: telemetryPublisherPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', metricsPublisherRoleDefinitionId)
  }
}

output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output applicationInsightsName string = applicationInsights.name

// The connection string is returned so main.bicep can put it in the container
// app's environment. It is deliberately NOT re-emitted as a main.bicep output:
// azd writes template outputs into .azure/<env>/.env, and .azure is not in this
// repository's .gitignore.
#disable-next-line outputs-should-not-contain-secrets
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
