<#
.SYNOPSIS
    Day 24, gate G1 done properly. Finds which of the policy-allowed regions can
    actually host every resource type this template needs.

.DESCRIPTION
    THIS SCRIPT EXISTS BECAUSE THE FIRST VERSION OF G1 WAS WRONG.

    00-preflight.ps1 originally probed a region by creating and deleting an empty
    resource group. That passed for centralindia -- and centralindia is NOT in
    this subscription's allowed-locations policy. The probe was measuring
    nothing, because Azure's built-in "Allowed locations" policy explicitly
    exempts Microsoft.Resources/subscriptions/resourceGroups; restricting where
    resource GROUPS may live is a separate policy. A resource group is a
    metadata record, so a policy that let you place one anywhere while refusing
    the resources inside it is not a quirk, it is the design.

    A false pass is worse than a failure. This script replaces the guess with an
    intersection of two facts, both read-only:

      1. The regions the subscription's policy permits.
      2. The regions each required resource provider actually offers.

    A region has to appear in both for every resource type, or the deployment
    fails partway -- which is the expensive way to find out, because the
    resource group and half the resources are already created.

.EXAMPLE
    ./Day24/scripts/01-region-fit.ps1
#>

[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',

    # Override if the policy is reassigned. Empty means "read it from the
    # policy assignment", which is the point.
    [string[]] $CandidateRegions = @()
)

$ErrorActionPreference = 'Continue'
az account set --subscription $SubscriptionId 2>&1 | Out-Null

# Every resource type main.bicep creates, as provider/type pairs. Kept explicit
# rather than derived: if a module gains a resource type, this list must gain a
# line, and a missing line is a region check that silently does not happen.
$required = @(
    @{ Label = 'Container Apps environment'; Namespace = 'Microsoft.App';               Type = 'managedEnvironments' },
    @{ Label = 'Container App';              Namespace = 'Microsoft.App';               Type = 'containerApps' },
    @{ Label = 'Container Registry';         Namespace = 'Microsoft.ContainerRegistry'; Type = 'registries' },
    @{ Label = 'Managed identity';           Namespace = 'Microsoft.ManagedIdentity';   Type = 'userAssignedIdentities' },
    @{ Label = 'Log Analytics workspace';    Namespace = 'Microsoft.OperationalInsights'; Type = 'workspaces' },
    @{ Label = 'Application Insights';       Namespace = 'Microsoft.Insights';          Type = 'components' },
    @{ Label = 'SQL server';                 Namespace = 'Microsoft.Sql';               Type = 'servers' },
    @{ Label = 'Service Bus namespace';      Namespace = 'Microsoft.ServiceBus';        Type = 'namespaces' }
)

# NOT part of main.bicep, and checked separately for exactly that reason. The
# Static Web App is created by hand (Phase D) and Microsoft.Web/staticSites is
# offered in only a handful of regions worldwide, so it is the resource most
# likely to have no overlap with the policy at all. If it does not fit, the
# front end needs a different home -- see the note this script prints.
$frontEnd = @{ Label = 'Static Web App'; Namespace = 'Microsoft.Web'; Type = 'staticSites' }

# ---------------------------------------------------------------------------
# 1. What does the policy permit?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'POLICY-ALLOWED REGIONS' -ForegroundColor Cyan
Write-Host ('-' * 74)

if ($CandidateRegions.Count -eq 0) {
    $raw = az policy assignment list `
        --query "[?displayName=='Allowed resource deployment regions'].parameters.listOfAllowedLocations.value" `
        -o json 2>$null | ConvertFrom-Json
    $CandidateRegions = @($raw | ForEach-Object { $_ } | Where-Object { $_ })
}

if ($CandidateRegions.Count -eq 0) {
    Write-Host '  Could not read the policy. Pass -CandidateRegions explicitly.' -ForegroundColor Red
    exit 1
}

$CandidateRegions | ForEach-Object { Write-Host "  $_" }

# ---------------------------------------------------------------------------
# 2. What does each provider actually offer there?
# ---------------------------------------------------------------------------
function Get-ProviderLocations([string] $Namespace, [string] $Type) {
    $locs = az provider show --namespace $Namespace `
        --query "resourceTypes[?resourceType=='$Type'].locations | [0]" -o json 2>$null | ConvertFrom-Json
    if (-not $locs) { return @() }
    # Providers report display names ("Korea Central"); policies use the short
    # form ("koreacentral"). Normalise before comparing -- this is the mistake
    # that makes a fit check silently report nothing fits.
    return @($locs | ForEach-Object { ($_ -replace '\s', '').ToLower() })
}

Write-Host ''
Write-Host 'FIT MATRIX' -ForegroundColor Cyan
Write-Host ('-' * 74)

$rows = @()
foreach ($r in ($required + $frontEnd)) {
    $offered = Get-ProviderLocations $r.Namespace $r.Type
    $row = [ordered]@{ Resource = $r.Label }
    foreach ($region in $CandidateRegions) {
        $row[$region] = if ($offered -contains $region.ToLower()) { 'yes' }
                        elseif ($offered.Count -eq 0)             { '?' }
                        else                                       { '--' }
    }
    $rows += [pscustomobject]$row
}
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

# ---------------------------------------------------------------------------
# 3. The verdict
# ---------------------------------------------------------------------------
$viable = @()
foreach ($region in $CandidateRegions) {
    $missing = @()
    foreach ($r in $required) {
        $offered = Get-ProviderLocations $r.Namespace $r.Type
        if ($offered.Count -gt 0 -and -not ($offered -contains $region.ToLower())) {
            $missing += $r.Label
        }
    }
    if ($missing.Count -eq 0) { $viable += $region }
    else {
        Write-Host "  $region  cannot host: $($missing -join ', ')" -ForegroundColor DarkYellow
    }
}

Write-Host ''
Write-Host 'VERDICT' -ForegroundColor Cyan
Write-Host ('-' * 74)

if ($viable.Count -eq 0) {
    Write-Host '  No allowed region can host the full template.' -ForegroundColor Red
    Write-Host '  Read the fit matrix above and decide what to drop, region by region.'
    exit 1
}

Write-Host "  Viable for main.bicep: $($viable -join ', ')" -ForegroundColor Green
Write-Host ''
Write-Host "  dev  -> param location = '$($viable[0])'"
if ($viable.Count -gt 1) {
    Write-Host "  prod -> param location = '$($viable[1])'   (a second region, so two"
    Write-Host "          Container Apps Environments never contend for one region's quota)"
} else {
    Write-Host "  prod -> only one viable region, so prod must share it. If creating a"
    Write-Host "          second Container Apps Environment there is refused, tear the dev"
    Write-Host "          stack down first -- sound only because prod is torn down anyway."
}

# ---------------------------------------------------------------------------
# 4. The front end, separately
# ---------------------------------------------------------------------------
$swaOffered = Get-ProviderLocations $frontEnd.Namespace $frontEnd.Type
$swaFit = @($CandidateRegions | Where-Object { $swaOffered -contains $_.ToLower() })

Write-Host ''
Write-Host 'FRONT END' -ForegroundColor Cyan
Write-Host ('-' * 74)

if ($swaFit.Count -gt 0) {
    Write-Host "  Static Web App can be created in: $($swaFit -join ', ')" -ForegroundColor Green
    Write-Host '  Phase D proceeds as written.'
} else {
    Write-Host '  NO allowed region can host a Static Web App.' -ForegroundColor Yellow
    Write-Host '  Microsoft.Web/staticSites is offered in only a few regions worldwide and'
    Write-Host '  none of them are permitted here. This is a real change of plan, not a'
    Write-Host '  workaround to squeeze past: Phase D as written cannot happen.'
    Write-Host ''
    Write-Host '  The repository already contains the answer, which is the useful part.'
    Write-Host '  Day13/quotes-web/src/environments/environment.production.ts sets'
    Write-Host "  apiBaseUrl to '' and its comment says that is correct 'when the SPA is"
    Write-Host "  served from the same host as the API -- behind the same reverse proxy,"
    Write-Host "  ingress, or Azure Container Apps ingress rule.' So serve the built"
    Write-Host '  Angular bundle from the Container App itself. Every request is'
    Write-Host '  same-origin, which is what the front end already assumes.'
    Write-Host ''
    Write-Host '  What that costs, stated rather than glossed:'
    Write-Host '    * The SWA linked backend and its Easy Auth boundary disappear. The'
    Write-Host '      Container App becomes publicly reachable by design, so the API'
    Write-Host '      protects itself with its own auth rather than sitting behind a front'
    Write-Host '      door. Phase F check 4 (expecting a 401 on the direct FQDN) no longer'
    Write-Host '      applies and must be rewritten, not quietly dropped.'
    Write-Host '    * day17-swa-deploy.yml no longer deploys anything. The Angular build'
    Write-Host '      becomes an input to the API image instead.'
    Write-Host '    * No PR preview environments.'
    Write-Host ''
    Write-Host '  Alternative if the SWA boundary must be kept: Azure Storage static'
    Write-Host '  website (Storage exists in every region) plus explicit CORS on the API.'
    Write-Host '  That trades same-origin for a CORS surface the repo currently avoids.'
}
Write-Host ''
