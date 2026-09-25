<#
.SYNOPSIS
    Repoints the GitHub Actions workflows at the new subscription, tenant and
    OIDC application.

.DESCRIPTION
    NOTHING IN .github/workflows NEEDED EDITING, AND THAT IS THE POINT.
    Every workflow already reads its identity from repository secrets and its
    resource names from repository variables:

        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    so a subscription move is a settings change, not a code change. If those
    values had been written into the YAML, this migration would have touched
    five workflow files instead of zero.

    THE OIDC APPLICATION DOES NOT SURVIVE THE TENANT MOVE. A federated
    credential is an object in a directory; the old one names a repository from
    a tenant that no longer owns anything here. Day26/scripts/01-github-oidc.ps1
    creates the replacement and its role assignments -- run that FIRST and pass
    its appId here.

    Nothing set by this script is a secret in the cryptographic sense. A tenant
    id, a subscription id and a public client id identify things; none of them
    authenticates anything. They are stored as secrets only because the earlier
    workflows chose to, and changing that is a separate decision.

.EXAMPLE
    ./migration/20-set-github-secrets.ps1 -ClientId <appId from Day26 script> -WhatIf
    ./migration/20-set-github-secrets.ps1 -ClientId <appId from Day26 script>
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ClientId,
    [string] $Repo            = 'thinkbridge-thinkschool/VaishaleeSingh',
    [string] $SubscriptionId  = '33c82ead-36a8-4d8f-b969-d8476690c224',
    [string] $TenantId        = '803dced7-0a24-4857-8be8-280047561e95',
    [string] $ResourceGroup   = 'thinkschool-dev-rg',
    [string] $ProdResourceGroup = 'thinkschool-prod-rg'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# WHY NATIVE az CALLS GO THROUGH A HELPER.
#
# Windows PowerShell 5.1 turns anything a native command writes to STDERR into
# an ErrorRecord. With $ErrorActionPreference = 'Stop' that record is
# TERMINATING -- so `az` printing a harmless notice ("WARNING: The behavior of
# this command has been altered by the following extension: containerapp")
# kills the script, reported as NativeCommandError against the PowerShell line
# rather than as anything about az. `2>$null` does not help: the redirection
# still creates the record first.
#
# So: stderr is merged, ErrorRecords are filtered out, --only-show-errors keeps
# az quiet, and $LASTEXITCODE is what decides whether a call worked.
#
# The argument list is passed as an ARRAY, not as loose arguments: otherwise
# PowerShell tries to bind `-o` as a parameter name and fails with "the
# parameter name 'o' is ambiguous", because -OutVariable and -OutBuffer exist.
# ---------------------------------------------------------------------------
function Invoke-Az {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @AzArgs --only-show-errors 2>&1 |
               Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        return (($out | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $raw = Invoke-Az $AzArgs
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw.Trim() -eq '[]' -or $raw.Trim() -eq 'null') { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Die 'The GitHub CLI (gh) is not on PATH. Install it, or set these by hand in Settings > Secrets and variables > Actions.'
}

Invoke-Az @('account','set','--subscription',$SubscriptionId) | Out-Null

# Names Azure assigned, read rather than assumed -- they changed with the
# subscription (see migration/10-refresh-derived-names.ps1).
$acr = Invoke-AzJson @('acr','list','-g',$ResourceGroup,'--query','[0].{name:name,server:loginServer}','-o','json')
if ($null -eq $acr) { Die "No container registry in $ResourceGroup. Deploy dev first." }

$prodAcrServer = ''
if ((Invoke-Az @('group','exists','--name',$ProdResourceGroup)).Trim() -eq 'true') {
    $prodAcrServer = (Invoke-Az @('acr','list','-g',$ProdResourceGroup,'--query','[0].loginServer','-o','tsv')).Trim()
}

$secrets = [ordered]@{
    AZURE_CLIENT_ID       = $ClientId
    AZURE_TENANT_ID       = $TenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
}
$variables = [ordered]@{
    AZURE_RESOURCE_GROUP                = $ResourceGroup
    AZURE_PROD_RESOURCE_GROUP           = $ProdResourceGroup
    AZURE_CONTAINER_REGISTRY_ENDPOINT   = $acr.server
    AZURE_CONTAINER_APP                 = 'quotes-api-dev'
    AZURE_WEB_CONTAINER_APP             = 'quotes-web-dev'
}
if (-not [string]::IsNullOrWhiteSpace($prodAcrServer)) {
    $variables['AZURE_PROD_CONTAINER_REGISTRY_ENDPOINT'] = $prodAcrServer
} else {
    Note "Prod resource group not found; AZURE_PROD_CONTAINER_REGISTRY_ENDPOINT left alone."
    Note 'Re-run this after prod is standing, or prod-deploy.yml will import from nowhere.'
}

Write-Host "Repository: $Repo" -ForegroundColor Cyan
Write-Host ''

foreach ($k in $secrets.Keys) {
    if ($PSCmdlet.ShouldProcess("$Repo secret $k", 'set')) {
        $secrets[$k] | gh secret set $k --repo $Repo | Out-Null
    }
    Ok "secret   $k"
}
foreach ($k in $variables.Keys) {
    if ($PSCmdlet.ShouldProcess("$Repo variable $k", 'set')) {
        gh variable set $k --repo $Repo --body $variables[$k] | Out-Null
    }
    Ok "variable $k = $($variables[$k])"
}

Write-Host ''
Write-Host 'Verify the way the workflows themselves do -- by failing loudly if wrong:' -ForegroundColor Cyan
Write-Host "  gh workflow run day17-api-deploy.yml --repo $Repo"
Write-Host ''
Note 'A wrong subscription and a missing role look IDENTICAL from a workflow:'
Note 'ARM returns 404 for what you cannot read. The workflows already say this'
Note 'in their error text; it is worth believing the first time.'
Write-Host ''
