// ============================================================================
// Key Vault — Day 25
// ============================================================================
// Holds the one secret that could not be eliminated.
//
// WHAT THIS MODULE DELIBERATELY DOES NOT DO: create the secret. There is no
// Microsoft.KeyVault/vaults/secrets resource here and no @secure() parameter
// carrying a value, and that absence is the point of the whole exercise.
//
// A @secure() parameter is not logged, which is often mistaken for "the value
// is safe". It is not the same claim. The value still has to exist as plain
// text wherever the deployment is launched from: in the operator's shell
// history or azd .env, in the CI runner's memory and process environment, and
// in the request body that goes to the ARM deployment API. Every one of those
// is a place the secret can be read from, and none of them is the vault. Day
// 24's parameter files read JWT_SECRET from the environment for exactly this
// reason and it is exactly this chain that Day 25 is cutting.
//
// So: this template creates an EMPTY vault and the grant that lets the app read
// from it. The value is written once, directly to the vault, by
// Day25/scripts/01-seed-jwt-secret.ps1 — from the operator to the vault, with
// no template, no deployment history and no pipeline in between. The template
// then references the secret by URI, which is not sensitive.
//
// The consequence, stated rather than discovered: a deployment into a fresh
// subscription creates a vault with no secret in it, and the container app's
// revision fails to provision until the seed script has run. That ordering is
// documented in the Day 25 approach doc and enforced by the script's own
// checks. It is a better failure than the alternative, which is a template
// that silently re-plants a secret from whatever the operator happened to have
// exported.

@description('Name of the key vault. Globally unique, 3-24 characters, alphanumerics and hyphens.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Location for the vault.')
param location string

@description('Tags applied to the vault.')
param tags object

// NAMED appPrincipalId rather than anything containing the word secret,
// and the choice is not cosmetic. The Bicep linter's
// secure-secrets-in-params rule matches on a parameter's NAME, so any name
// with 'secret' in it is reported as a value that must be @secure(). A
// principal (object) ID is not one -- it is a public directory identifier,
// and marking it @secure() would hide it from what-if output in exchange for
// nothing. This answers the linter honestly instead of suppressing the rule,
// and matches modules/servicebus.bicep, which already calls the same value by
// this name.
@description('Principal (object) ID of the identity that reads secrets — the app. Empty skips the grant, which leaves a vault the app cannot read.')
param appPrincipalId string = ''

// PURGE PROTECTION IS A PARAMETER, AND IT IS OFF BY DEFAULT, WHICH LOOKS LIKE
// THE WRONG DEFAULT UNTIL YOU HOLD IT NEXT TO DAY 24.
//
// Purge protection makes a soft-deleted vault impossible to remove early: the
// name stays reserved for the full retention window, up to 90 days, and no
// amount of permission shortens it. In production that is the entire value —
// it is what stops an attacker, or a bad script, destroying the secrets and
// the audit trail together.
//
// In THIS dev environment it collides with the deployment stack. Day 24 sets
// actionOnUnmanage to deleteAll, so tearing the stack down deletes the vault;
// with purge protection on, the next `az stack sub create` then fails trying
// to create a vault whose name is reserved by the corpse of the last one. The
// deployment does not report it as a name collision either — it reports a
// conflict, and the reflex is to assume the template is wrong.
//
// Off in dev, on in prod, stated in both parameter files rather than left to
// this default.
@description('Block early purge of a soft-deleted vault. TRUE in production. FALSE in any environment whose stack is torn down and recreated, because a reserved name blocks the next deployment for up to 90 days.')
param enablePurgeProtection bool = false

@description('Days a soft-deleted vault is recoverable. 7 is the minimum and is right for a dev environment that is recreated often; production wants the 90 day default.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 7

// Key Vault Secrets User. A fixed, well-known role definition GUID, the same in
// every tenant. Read-only over secret VALUES — it cannot list, set, or delete
// the vault's contents, only read the ones it is pointed at. That is the whole
// permission the app needs, and it is worth resisting the urge to use Key Vault
// Secrets Officer here because it is easier to remember: an app that can
// overwrite its own signing key is an app that can lock every user out.
var secretsUserRoleDefinitionId = '4633458b-17de-408a-b874-0445c86b69e6'

var grantRead = !empty(appPrincipalId)

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId

    // RBAC, NOT ACCESS POLICIES, and this is not a stylistic preference.
    //
    // Access policies are a second, parallel permission model that lives only
    // on the vault. They do not appear in `az role assignment list`, they are
    // invisible to a subscription-wide access review, and Day 25's own proof
    // script — which enumerates role assignments to check the app is not
    // over-privileged — would report a clean result while an access policy
    // granted something else entirely. One permission model, auditable in the
    // same place as every other permission in this subscription.
    enableRbacAuthorization: true

    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection ? true : null

    // Deployments do not need to read secrets out of this vault, and saying so
    // explicitly closes a door that is open by default. `enabledForDeployment`
    // and friends let ARM and VMs pull secrets during a deployment, which is a
    // capability this project has no use for and which would quietly undo the
    // "the value never travels through a deployment" property above.
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false

    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// The app reads its signing key through this. Without it the container app's
// Key Vault reference cannot resolve, and the failure mode is worth knowing
// before you meet it: the revision does not start with a warning and fall back
// to something — it fails to provision at all, and the error names the secret
// rather than the missing permission.
resource secretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantRead) {
  name: guid(keyVault.id, appPrincipalId, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    principalId: appPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleDefinitionId)
  }
}

output keyVaultName string = keyVault.name

// The URI, not a secret value. https://<name>.vault.azure.net/ is public
// information — it identifies the vault, and reaching it still requires a token
// this template never issues.
output keyVaultUri string = keyVault.properties.vaultUri

output keyVaultResourceId string = keyVault.id
