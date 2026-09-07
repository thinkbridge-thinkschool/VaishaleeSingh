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
