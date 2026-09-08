<#
.SYNOPSIS
    Day 24 gates G1-G7. Read-only probes against the new subscription, run
    before a single file is edited or a single resource is created.

.DESCRIPTION
    Every check in here has a known failure mode on an Azure for Students
    subscription in a university tenant, and every one of them fails LATE if
    it is not checked first -- after a fifteen-minute deployment, or worse,
    after a green deployment, in production, under load.

    Nothing here creates a billable resource. G1 creates and immediately
    deletes an empty resource group, which is free and is the only way to
    prove a region is actually permitted rather than merely listed.

    The output ends with the exact values to paste into
    infra/main.dev.bicepparam and infra/main.prod.bicepparam.

.EXAMPLE
    ./Day24/scripts/00-preflight.ps1 -Region centralindia
    ./Day24/scripts/00-preflight.ps1 -Region southindia -ProdRegion centralindia
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ExpectedTenantId = '8d46a076-d093-416d-a57b-8692cde13bf8',
    [string] $OldTenantId = 'f774bb68-0575-4cd2-9d4c-3b4e593d1110',
    [string] $ApiAppRegistrationId = '91566dbd-d857-488a-858d-475e60b309b7',

    # The region to probe. Not defaulted to centralindia deliberately -- see G1.
    [Parameter(Mandatory)]
    [string] $Region,

    # Optional second region for prod. Leave unset to skip that probe.
    [string] $ProdRegion
)

$ErrorActionPreference = 'Continue'
$script:findings = [ordered]@{}
$script:blockers = @()

function Write-Gate([string] $Id, [string] $Title) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host "$Id  $Title" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}

function Write-Pass([string] $Message) { Write-Host "  PASS   $Message" -ForegroundColor Green }
function Write-Warn([string] $Message) { Write-Host "  CHECK  $Message" -ForegroundColor Yellow }
function Write-Fail([string] $Message) {
    Write-Host "  BLOCK  $Message" -ForegroundColor Red
    $script:blockers += $Message
}

# ---------------------------------------------------------------------------
# G0  Subscription and tenant
# ---------------------------------------------------------------------------
Write-Gate 'G0' 'Subscription and tenant'

az account set --subscription $SubscriptionId 2>&1 | Out-Null
$account = az account show -o json 2>$null | ConvertFrom-Json

if (-not $account) {
    Write-Fail "Cannot read subscription $SubscriptionId. Run 'az login' first."
    return
}

Write-Host "  subscription : $($account.name)  ($($account.id))"
Write-Host "  tenant       : $($account.tenantId)"
Write-Host "  state        : $($account.state)"

if ($account.tenantId -ne $ExpectedTenantId) {
    Write-Fail "Tenant is $($account.tenantId), expected $ExpectedTenantId. Every Entra value in the plan assumes the latter."
} else {
    Write-Pass 'Tenant matches the plan.'
}
if ($account.state -ne 'Enabled') {
    Write-Fail "Subscription state is '$($account.state)'. A disabled student subscription means the credit is spent."
}

# ---------------------------------------------------------------------------
# G0b  The OLD tenant must still answer -- the API's Entra scheme depends on it
# ---------------------------------------------------------------------------
Write-Gate 'G0b' 'Old tenant still reachable (the API app registration lives there)'

Write-Host "  A directory is free and survives credit exhaustion, so the API's Entra"
Write-Host "  scheme keeps pointing at $OldTenantId."
Write-Host "  This check needs a separate sign-in and is NOT run automatically:"
Write-Host ''
Write-Host "    az login --tenant $OldTenantId --allow-no-subscriptions" -ForegroundColor Gray
Write-Host "    az ad app show --id $ApiAppRegistrationId ``" -ForegroundColor Gray
Write-Host '      --query "{uris:identifierUris, scopes:api.oauth2PermissionScopes[].value}"' -ForegroundColor Gray
Write-Host ''
Write-Warn 'Run the two commands above. They also settle the azureAdAudience disagreement.'
Write-Warn 'Do NOT delete that tenant when decommissioning the old subscription.'

# ---------------------------------------------------------------------------
# G1  Region policy -- is this region actually allowed?
# ---------------------------------------------------------------------------
Write-Gate 'G1' 'Allowed deployment regions'

$assignments = az policy assignment list -o json 2>$null | ConvertFrom-Json
if ($assignments) {
    $regionPolicies = $assignments | Where-Object {
        $_.displayName -match 'region|location|allowed'
    }
    if ($regionPolicies) {
        Write-Warn 'Region-shaped policy assignments found:'
        $regionPolicies | ForEach-Object { Write-Host "    - $($_.displayName)" }
    } else {
        Write-Host '  No region-shaped policy assignment visible at subscription scope.'
        Write-Host '  That does not prove none applies -- inherited assignments may not list here.'
    }
}

# THE RESOURCE-GROUP PROBE THAT USED TO LIVE HERE HAS BEEN REMOVED. It reported
# a FALSE PASS, which is worse than reporting nothing.
#
# It created and deleted an empty resource group in the candidate region and
# called success "permitted". centralindia passed it. centralindia is not in
# this subscription's allowed-locations list. Azure's built-in "Allowed
# locations" policy explicitly exempts
# Microsoft.Resources/subscriptions/resourceGroups -- restricting where resource
# GROUPS may live is a separate policy -- so a resource group can legitimately
# be created in a region whose resources are all refused. A resource group is a
# metadata record; the exemption is the design, not a loophole.
#
# Region fitness now needs two facts intersected, and 01-region-fit.ps1 does it:
# what the policy permits, and what each required resource provider actually
# offers there. Read the allowed list here; decide the region there.
$allowed = az policy assignment list `
    --query "[?displayName=='Allowed resource deployment regions'].parameters.listOfAllowedLocations.value" `
    -o json 2>$null | ConvertFrom-Json
$allowedFlat = @($allowed | ForEach-Object { $_ } | Where-Object { $_ })

if ($allowedFlat.Count -gt 0) {
    Write-Host ''
    Write-Host "  Policy-allowed regions: $($allowedFlat -join ', ')"
    $script:findings['allowed_regions'] = ($allowedFlat -join ', ')

    foreach ($candidate in @($Region, $ProdRegion) | Where-Object { $_ }) {
        if ($allowedFlat -contains $candidate.ToLower()) {
            Write-Pass "'$candidate' is in the allowed list."
        } else {
            Write-Fail "'$candidate' is NOT in the allowed list. Do not put it in a parameter file."
        }
    }
} else {
    Write-Warn 'Could not read the allowed-locations policy. Do not assume there is no restriction.'
}

Write-Warn 'Being in the allowed list is necessary, not sufficient -- a permitted region may not offer Container Apps, or a Static Web App. Run Day24/scripts/01-region-fit.ps1 next.'

# ---------------------------------------------------------------------------
# G2  Compute quota and resource providers
# ---------------------------------------------------------------------------
Write-Gate 'G2' 'Compute quota and provider registration'

$usage = az vm list-usage --location $Region -o json 2>$null | ConvertFrom-Json
if ($usage) {
    $cores = $usage | Where-Object { $_.name.value -match 'cores$' } |
             Select-Object @{n='quota';e={$_.localName}}, currentValue, limit
    $cores | Format-Table -AutoSize | Out-String | Write-Host

    $regional = $usage | Where-Object { $_.name.value -eq 'cores' }
    if ($regional) {
        $script:findings['regional_core_limit'] = $regional.limit
        if ($regional.limit -le 4) {
            Write-Warn "Regional core limit is $($regional.limit). main.prod.bicepparam must not exceed it: 4 replicas x 0.5 vCPU = 2 vCPU ceiling is the Day 24 value."
        } else {
            Write-Pass "Regional core limit is $($regional.limit)."
        }
    }
}

# Microsoft.Compute is here only so `az vm list-usage` above can answer. It is
# NOT needed by the template -- Container Apps Consumption does not create VMs,
# and it does not draw on the VM core quota either. The quota that actually
# binds the API is the Container Apps one, and it cannot be read until an
# environment exists:
#
#   az containerapp env list-usages -n <env> -g <rg> -o table
#
# Run that after the first deployment and before trusting prod's replica ceiling.
foreach ($ns in @(
    'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.ServiceBus',
    'Microsoft.Sql', 'Microsoft.ContainerRegistry', 'Microsoft.ManagedIdentity',
    'Microsoft.Insights', 'Microsoft.Web', 'Microsoft.Compute')) {
    $state = az provider show --namespace $ns --query registrationState -o tsv 2>$null
    if ($state -eq 'Registered') {
        Write-Pass "$ns registered"
    } else {
        Write-Warn "$ns is '$state' -- registering (this can take a few minutes)"
        az provider register --namespace $ns --wait 2>&1 | Out-Null
    }
}

# ---------------------------------------------------------------------------
# G3  Can you create app registrations in this tenant?
# ---------------------------------------------------------------------------
Write-Gate 'G3' 'App registration rights (decides how GitHub OIDC is done)'

$allowed = az rest --method GET `
    --url https://graph.microsoft.com/v1.0/policies/authorizationPolicy `
    --query "value[0].defaultUserRolePermissions.allowedToCreateApplications" -o tsv 2>$null

switch ("$allowed") {
    'true'  {
        Write-Pass 'Users may register applications. OIDC path A (app registration) is available.'
        $script:findings['oidc_path'] = 'A - app registration'
    }
    'false' {
        Write-Warn 'App registration is BLOCKED for non-admins in this tenant.'
        Write-Host '    Use OIDC path B: a user-assigned managed identity with a federated'
        Write-Host '    identity credential. It is an ARM resource in your own subscription,'
        Write-Host '    so it needs no directory rights, and azure/login@v2 accepts it'
        Write-Host '    exactly like an app registration. Do not go asking IT first.'
        $script:findings['oidc_path'] = 'B - user-assigned managed identity'
    }
    default {
        Write-Warn "Microsoft Graph returned nothing for defaultUserRolePermissions (got '$allowed')."
        Write-Host '    That is what a directory looks like when it withholds Graph reads from'
        Write-Host '    ordinary members -- not an error in this script, and not evidence either'
        Write-Host '    way about whether you may register applications. Settle it with one'
        Write-Host '    directory WRITE, which this script deliberately does not perform for you:'
        Write-Host ''
        Write-Host '      az ad app create --display-name probe-delete-me' -ForegroundColor Gray
        Write-Host '      az ad app delete --id <appId from above>' -ForegroundColor Gray
        Write-Host ''
        Write-Host '    Succeeds -> OIDC path A. Refused -> path B (user-assigned managed'
        Write-Host '    identity with a federated credential), which needs no directory rights.'
        Write-Host '    The same answer decides whether prod can have a GROUP as SQL admin.'
        $script:findings['oidc_path'] = 'unknown - probe with az ad app create'
    }
}

# ---------------------------------------------------------------------------
# G4  Are you Owner? The template creates role assignments.
# ---------------------------------------------------------------------------
Write-Gate 'G4' 'Subscription role (the template creates role assignments)'

$me = az ad signed-in-user show -o json 2>$null | ConvertFrom-Json
if ($me) {
    $roles = az role assignment list --assignee $me.id `
        --scope "/subscriptions/$SubscriptionId" --query "[].roleDefinitionName" -o tsv 2>$null
    Write-Host "  roles: $($roles -join ', ')"
    if ($roles -contains 'Owner' -or $roles -contains 'User Access Administrator' -or
        $roles -contains 'Role Based Access Control Administrator') {
        Write-Pass 'You can create role assignments (AcrPull, Service Bus Data Sender/Receiver).'
    } else {
        Write-Fail 'No role-assignment rights. The deployment will get most of the way and then fail on the AcrPull and Service Bus grants.'
    }
}

# ---------------------------------------------------------------------------
# G5  Your Amity identity -- the SQL administrator
# ---------------------------------------------------------------------------
Write-Gate 'G5' 'SQL Entra administrator identity'

if ($me) {
    $script:findings['sqlEntraAdminObjectId'] = $me.id
    $script:findings['sqlEntraAdminLogin'] = $me.userPrincipalName
    Write-Host "  objectId : $($me.id)"
    Write-Host "  upn      : $($me.userPrincipalName)"
    Write-Warn 'With azureADOnlyAuthentication there is no SQL login to fall back on. A wrong value here does not fail the deployment -- it leaves a server nobody can administer.'
} else {
    Write-Fail 'Could not read the signed-in user.'
}

# ---------------------------------------------------------------------------
# G6  Tooling
# ---------------------------------------------------------------------------
Write-Gate 'G6' 'Tooling: az stack, azd, and the stacks alpha feature'

$azVersion = (az version -o json 2>$null | ConvertFrom-Json).'azure-cli'
Write-Host "  az  : $azVersion"
az stack sub list -o none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "'az stack' is available."
} else {
    Write-Fail "'az stack' is unavailable. Run 'az upgrade'."
}

$azdVersion = azd version 2>$null
if ($azdVersion) {
    Write-Host "  azd : $azdVersion"
    $cfg = azd config show 2>$null | Out-String
    if ($cfg -match 'stacks') {
        Write-Pass 'The deployment-stacks alpha feature appears to be enabled.'
    } else {
        Write-Warn "Enable it: azd config set alpha.deployment.stacks on"
        Write-Host '    Without it azd IGNORES the deploymentStacks block in azure.yaml. It does not warn.'
    }
} else {
    Write-Fail 'azd is not on PATH.'
}

# ---------------------------------------------------------------------------
# G7  Budget
# ---------------------------------------------------------------------------
Write-Gate 'G7' 'Cost guard'

$budgets = az consumption budget list -o json 2>$null | ConvertFrom-Json
if ($budgets -and $budgets.Count -gt 0) {
    $budgets | ForEach-Object { Write-Host "  budget: $($_.name)  amount=$($_.amount)" }
    Write-Pass 'A budget exists.'
} else {
    Write-Warn 'No budget. A student subscription disables itself when the credit is spent -- which is what this migration is recovering from.'
    Write-Host '    az consumption budget create --budget-name thinkschool-guard \' -ForegroundColor Gray
    Write-Host '      --amount 25 --time-grain Monthly --category Cost \' -ForegroundColor Gray
    Write-Host "      --time-period-start $((Get-Date -Format 'yyyy-MM-01'))" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkGray
Write-Host 'VALUES TO PASTE INTO THE PARAMETER FILES' -ForegroundColor Cyan
Write-Host ('=' * 74) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'infra/main.dev.bicepparam:'
Write-Host "  param location = '$Region'"
Write-Host "  param sqlEntraAdminObjectId = '$($script:findings['sqlEntraAdminObjectId'])'"
Write-Host "  param sqlEntraAdminLogin = '$($script:findings['sqlEntraAdminLogin'])'"
Write-Host ''
Write-Host 'infra/main.prod.bicepparam:'
if ($ProdRegion) {
    Write-Host "  param location = '$ProdRegion'"
} else {
    Write-Host "  param location = '<a second allowed region, or dev's if only one is permitted>'"
}
Write-Host "  param sqlEntraAdminObjectId = '<object id of the quotes-sql-admins group>'"
Write-Host ''
Write-Host "GitHub OIDC path: $($script:findings['oidc_path'])"
Write-Host ''

if ($script:blockers.Count -gt 0) {
    Write-Host ('-' * 74) -ForegroundColor Red
    Write-Host "$($script:blockers.Count) BLOCKER(S) -- resolve before editing any parameter file:" -ForegroundColor Red
    $script:blockers | ForEach-Object { Write-Host "  * $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'No blockers. Proceed to the parameter-file edits.' -ForegroundColor Green
