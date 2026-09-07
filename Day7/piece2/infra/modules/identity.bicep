// The user-assigned managed identity the API runs as.
//
// One identity, used for three things: pulling from the container registry
// (granted in registry.bicep), sending to and receiving from Service Bus
// (granted in servicebus.bicep), and authenticating to Azure SQL as a
// contained database user (created by scripts/create-sql-user.ps1 — see
// sql.bicep for why Bicep cannot do that part).
//
// User-assigned rather than system-assigned deliberately: a system-assigned
// identity is created and destroyed with the container app, so every recreation
// of the app would invalidate every grant and every SQL user pointing at it.

targetScope = 'resourceGroup'

@description('Name of the user-assigned managed identity.')
param managedIdentityName string

@description('Location for the identity.')
param location string

@description('Tags applied to the identity.')
param tags object

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: tags
}

output identityResourceId string = managedIdentity.id
output identityPrincipalId string = managedIdentity.properties.principalId
output identityClientId string = managedIdentity.properties.clientId
output identityName string = managedIdentity.name
