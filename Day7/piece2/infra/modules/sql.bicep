// Azure SQL — logical server + one database. NEW ON DAY 23.
//
// There was no SQL infrastructure anywhere in this repository before this file:
// `Microsoft.Sql` appeared in zero templates. The deployed container app ran on
// the SQLite file baked into its image, because nothing ever set
// ConnectionStrings__DefaultConnection. This module is what makes the deployed
// application use a real database.
//
// ENTRA-ONLY AUTHENTICATION, AND WHY IT IS THE POINT
// `azureADOnlyAuthentication: true`, and no administratorLogin /
// administratorLoginPassword anywhere. This is not hardening for its own sake —
// it removes the single hardest problem the "separate dev/prod parameter files"
// exercise creates. A SQL admin password would have to exist, differently, in
// two parameter files that live in source control. With Entra-only auth there
// is no password to place, the connection string below carries no credential,
// and the app authenticates with the managed identity it already uses for
// Service Bus and the container registry.
//
// THE GAP THIS MODULE CANNOT CLOSE
// A managed identity being able to *reach* the server is not the same as it
// having a login. The contained database user is T-SQL:
//
//   CREATE USER [<identity-name>] FROM EXTERNAL PROVIDER;
//   ALTER ROLE db_datareader ADD MEMBER [<identity-name>];
//   ALTER ROLE db_datawriter ADD MEMBER [<identity-name>];
//
// ARM cannot express that. It runs from ../../scripts/create-sql-user.ps1 after
// the deployment, and it is stated in the Day 23 submission as a known
// post-deploy step rather than quietly omitted — a deployment that needs an
// imperative follow-up is exactly the thing "no portal click-ops" is about, so
// it gets named instead of hidden.

targetScope = 'resourceGroup'

@description('Name of the SQL logical server. Globally unique, lowercase.')
@minLength(1)
@maxLength(63)
param sqlServerName string

@description('Name of the database.')
param databaseName string

@description('Location for the server and database.')
param location string

@description('Tags applied to both resources.')
param tags object

@description('Object ID of the Entra user or group that becomes the SQL admin. This is the ONLY administrator — there is no SQL login.')
param entraAdminObjectId string

@description('Display name of that Entra admin, shown in the portal and in sys.server_principals.')
param entraAdminLogin string

@description('Entra principal type of the admin.')
@allowed([
  'User'
  'Group'
  'Application'
])
param entraAdminPrincipalType string = 'User'

@description('Client ID of the app managed identity. Goes into the connection string so SqlClient picks the right identity on a host that may have several.')
param appIdentityClientId string

@description('SKU name, e.g. GP_S_Gen5 (serverless) or GP_Gen5 (provisioned).')
param skuName string

@description('SKU tier, e.g. GeneralPurpose.')
param skuTier string

@description('SKU hardware family, e.g. Gen5.')
param skuFamily string = 'Gen5'

@description('vCores.')
@minValue(1)
param skuCapacity int

@description('Serverless SKUs auto-pause and bill per second; provisioned ones do not. This selects which extra properties are legal below.')
param useServerless bool

@description('Minutes of inactivity before a serverless database pauses. -1 disables auto-pause. Ignored when useServerless is false.')
param autoPauseDelayMinutes int = -1

@description('Minimum vCores a serverless database scales down to, as a string for json(). Ignored when useServerless is false.')
param minCapacity string = '0.5'

@description('Maximum database size in bytes.')
param maxSizeBytes int

@description('Zone redundancy. Not available on every SKU in every region — centralindia General Purpose does not support it, which is why prod also passes false.')
param zoneRedundant bool = false

@description('Backup storage redundancy.')
@allowed([
  'Local'
  'Zone'
  'Geo'
  'GeoZone'
])
param backupStorageRedundancy string = 'Local'

@description('Whether the server answers on its public endpoint at all.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Add the 0.0.0.0 firewall rule that permits Azure services — how the Container App reaches the server without a private endpoint.')
param allowAzureServices bool = true

@description('Individual client IP addresses allowed through the firewall — the machines that ADMINISTER the server, not the app. Empty adds none.')
param allowedClientIpAddresses array = []

@description('Minimum TLS version the server accepts.')
@allowed([
  '1.0'
  '1.1'
  '1.2'
])
param minimalTlsVersion string = '1.2'

// Serverless-only properties are illegal on a provisioned SKU, so they are
// merged in conditionally rather than passed as -1/ignored values.
var serverlessProperties = useServerless
  ? {
      autoPauseDelay: autoPauseDelayMinutes
      minCapacity: json(minCapacity)
    }
  : {}

var baseDatabaseProperties = {
  collation: 'SQL_Latin1_General_CP1_CI_AS'
  maxSizeBytes: maxSizeBytes
  zoneRedundant: zoneRedundant
  requestedBackupStorageRedundancy: backupStorageRedundancy
}

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    version: '12.0'
    minimalTlsVersion: minimalTlsVersion
    publicNetworkAccess: publicNetworkAccess
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: entraAdminPrincipalType
      login: entraAdminLogin
      sid: entraAdminObjectId
      tenantId: subscription().tenantId
      // The line that means there is no password anywhere in this repository.
      azureADOnlyAuthentication: true
    }
  }
}

resource database 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  name: databaseName
  parent: sqlServer
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
    family: skuFamily
    capacity: skuCapacity
  }
  properties: union(baseDatabaseProperties, serverlessProperties)
}

// The 0.0.0.0-0.0.0.0 rule is a special case, not a literal address range: it
// means "any Azure service in any subscription". It is broad, and it is what
// makes a Container App with no VNet integration able to connect at all. The
// authentication boundary is Entra, not the network, which is what makes this
// an acceptable trade here rather than an open door.
resource allowAzureServicesRule 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = if (allowAzureServices) {
  name: 'AllowAllWindowsAzureIps'
  parent: sqlServer
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// The app reaches the server through the AllowAzureServices rule above. A
// person does not: the first attempt to create the contained database user
// failed with "Client with IP address '...' is not allowed to access the
// server", because nothing had granted the administrator's own machine access.
//
// The fix belongs here rather than in `az sql server firewall-rule create` or a
// portal blade. A rule added by hand is invisible to the template, survives
// nothing, and is exactly the click-ops this exercise is about — and it would
// have been reported as drift by the next what-if, or silently reverted.
//
// Named after the address rather than the loop index, so adding or removing an
// entry does not rename every rule after it — an index-named rule is a delete
// and a create wearing the same name.
resource clientFirewallRules 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = [
  for ip in allowedClientIpAddresses: {
    name: 'client-${replace(ip, '.', '-')}'
    parent: sqlServer
    properties: {
      startIpAddress: ip
      endIpAddress: ip
    }
  }
]

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name

// Carries no credential, which is the whole point of the Entra-only decision
// above — so unlike the App Insights connection string this one is safe to
// hand around.
//
// `User Id` is the managed identity's CLIENT id, not its object id, and it is
// required rather than optional: DefaultAzureCredential on a host with more
// than one assigned identity cannot guess which one to present.
//
// InfrastructureExtensions.cs selects the provider by inspecting this string —
// it looks for "Server=" or "Initial Catalog=" — so both are present and the
// app lands on UseSqlServer with no Database:Provider override needed.
output connectionString string = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${database.name};Authentication=Active Directory Default;User Id=${appIdentityClientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
