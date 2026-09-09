// Azure Container Registry, and the AcrPull grant that lets the API's managed
// identity pull from it.
//
// WHY THE ROLE ASSIGNMENT LIVES HERE AND NOT IN identity.bicep:
// A roleAssignment's `scope:` needs a symbolic reference to the resource being
// granted on, and that reference only exists in the file that declares it. The
// registry is the scope, so the assignment belongs to the registry module and
// takes the principal as a parameter. The reverse — putting it in the identity
// module — would need an `existing` registry reference and a second source of
// truth for the registry's name.
//
// IDEMPOTENCY: the guid() seeds below are byte-identical to the ones the
// pre-Day-23 resources.bicep used. Changing what you feed guid() does not
// update the existing assignment, it creates a second one — so the refactor
// deliberately preserves them.

targetScope = 'resourceGroup'

@description('Name of the container registry. Alphanumeric only, 5-50 characters, globally unique.')
@minLength(5)
@maxLength(50)
param containerRegistryName string

@description('Location for the registry.')
param location string

@description('Tags applied to the registry.')
param tags object

@description('Registry SKU. Basic is enough for a single small image; Premium buys geo-replication and private endpoints.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param skuName string = 'Basic'

@description('Enable the admin user. Day 25 flipped the default to false: the app pulls with its managed identity, so the admin username/password was a live credential pair that nothing depended on and nobody was watching. main.bicep passes it explicitly as well, so this default cannot quietly drift back.')
param adminUserEnabled bool = false

@description('Resource ID of the user-assigned identity that needs AcrPull. Empty skips the grant.')
param pullIdentityResourceId string = ''

@description('Principal (object) ID of that identity. Empty skips the grant.')
param pullIdentityPrincipalId string = ''

// AcrPull. This is a fixed, well-known role definition GUID — the same in every
// tenant and subscription — not the registry's own resource ID.
var acrPullRoleDefinitionId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

var grantPull = !empty(pullIdentityResourceId) && !empty(pullIdentityPrincipalId)

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    adminUserEnabled: adminUserEnabled
  }
}

// Lets the container app pull without embedding the admin username/password as
// a container secret.
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantPull) {
  name: guid(containerRegistry.id, pullIdentityResourceId, 'AcrPull')
  scope: containerRegistry
  properties: {
    principalId: pullIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleDefinitionId)
  }
}

output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
