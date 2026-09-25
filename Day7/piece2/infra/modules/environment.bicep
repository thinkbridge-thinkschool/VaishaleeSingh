// The Container Apps Environment — created, or referenced.
//
// THIS MODULE EXISTS BECAUSE OF A SUBSCRIPTION QUOTA, NOT A PREFERENCE.
// The pre-Day-23 template hardcoded an `existing` reference to
// `thinkschool-env` in `thinkschool-rg`, with a comment explaining why: this
// subscription allows exactly one Container Apps Environment per region
// (MaxNumberOfRegionalEnvironmentsInSubExceeded), and that one already occupies
// centralindia. The reasoning was right; welding it into the template was not.
//
// Day 23 turns it into a switch. `createEnvironment: false` reuses the shared
// environment (what dev does today, because it is the only thing the
// subscription allows). `createEnvironment: true` creates a dedicated one
// (what the prod parameter file describes, and what would happen the moment the
// quota permitted it). The constraint now lives in a parameter file, where a
// constraint belongs.
//
// NOTE ON `azd down`: when the environment is referenced rather than created,
// nothing here is deleted with the resource group — which is correct, since
// this deployment does not own it.

targetScope = 'resourceGroup'

@description('Create a dedicated environment (true) or reference an existing one (false).')
param createEnvironment bool

@description('Name of the environment to create, or of the existing one to reference.')
param environmentResourceName string

@description('Resource group holding the existing environment. Ignored when createEnvironment is true.')
param existingEnvironmentResourceGroup string = resourceGroup().name

@description('Location for a newly created environment.')
param location string

@description('Tags applied to a newly created environment.')
param tags object

@description('Name of the Log Analytics workspace a new environment sends container console logs to. Must be in this resource group.')
param logAnalyticsWorkspaceName string

// Referenced, not created — monitoring.bicep owns it. The shared key is read
// here rather than passed in as a parameter so that it never becomes a module
// output, a template output, or a value in a parameter file.
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource newEnvironment 'Microsoft.App/managedEnvironments@2026-07-01' = if (createEnvironment) {
  name: environmentResourceName
  location: location
  tags: tags
  properties: {
    // An environment declared with NO workloadProfiles is provisioned by Azure
    // as an "express" environment, which rejects secrets[].keyVaultUrl with
    // ExpressEnvironmentFeatureNotSupported. Day 23/25 keep the JWT signing
    // secret in Key Vault and reach it by managed-identity reference, so this
    // deployment REQUIRES a workload-profiles environment. One Consumption
    // profile is the documented way to ask for one; billing is unchanged.
    // An existing express environment cannot be converted in place -- delete it.
    // environmentMode IS THE PROPERTY THAT DECIDES THE ENVIRONMENT CLASS.
    // Azure now defaults a newly created environment to 'Express', which rejects
    // secrets[].keyVaultUrl. 2023-05-01 does not know this property at all, so a
    // template pinned there silently accepts whatever default ARM applies -- which
    // is why this broke only on the new subscription. Stating the mode makes the
    // environment class an explicit decision instead of an inherited default.
    environmentMode: 'WorkloadProfiles'
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource existingEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' existing = if (!createEnvironment) {
  name: environmentResourceName
  scope: resourceGroup(existingEnvironmentResourceGroup)
}

// .id is a computed resource identifier, not a runtime reference(), so this
// ternary is safe for the branch that was not deployed.
output environmentId string = createEnvironment ? newEnvironment.id : existingEnvironment.id
