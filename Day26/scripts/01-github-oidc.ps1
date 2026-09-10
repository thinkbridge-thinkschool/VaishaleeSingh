<#
.SYNOPSIS
    Creates the GitHub Actions OIDC app registration in the Amity tenant, its
    federated credentials, and the two narrow role assignments the deploy
    workflows need. Prints the three values to store as repository secrets.

.DESCRIPTION
    WHY THIS EXISTS. The deploy workflows authenticate with azure/login@v2
    using OIDC and fail with:

      Login failed with Error: Using auth-type: SERVICE_PRINCIPAL. Not all
      values are present. Ensure 'client-id' and 'tenant-id' are supplied.

    which means the repository secrets are empty. They are empty because the
    app registration they name never existed in this tenant: Day 24 moved the
    subscription and listed the OIDC principal as outstanding work, and it
    stayed outstanding.

    NO CLIENT SECRET IS CREATED, AND THAT IS THE ENTIRE POINT. A federated
    credential is a trust relationship, not a password: GitHub mints a
    short-lived token for a specific repository and ref, and Entra accepts it
    because this registration says it should. There is nothing to leak, expire
    or rotate. The alternative -- `az ad sp create-for-rbac` and an
    AZURE_CREDENTIALS blob -- puts a real secret in repository settings, where
    it lives until someone remembers to rotate it, which is never.

    THE SUBJECT STRING IS EXACT AND UNFORGIVING. Entra matches
    "repo:<owner>/<repo>:ref:refs/heads/main" character for character against
    the claim GitHub sends. A subject for `main` does not authorise a run on a
    branch, and a pull_request run sends a different subject again -- so each
    trigger the workflows use needs its own credential. A mismatch fails as
    "no matching federated identity record found", which reads like the
    registration is missing rather than like one string is wrong.

    ROLES ARE SCOPED TO RESOURCES, NOT THE RESOURCE GROUP. Day 25 spent the
    day proving the app's identity holds only what it needs; granting its
    pipeline Contributor over the whole group would undo that quietly. The
    workflows push an image and roll two container apps, so that is exactly
    what is granted: AcrPush on the registry, Contributor on each container
    app. Deleting anything is still refused by the deployment stack's deny
    assignment.

.PARAMETER Repo
    owner/repo as GitHub spells it. Case matters in the subject claim.

.EXAMPLE
    ./Day26/scripts/01-github-oidc.ps1 -WhatIf
    ./Day26/scripts/01-github-oidc.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId  = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ExpectedTenant  = '8d46a076-d093-416d-a57b-8692cde13bf8',
    [string] $ResourceGroup   = 'thinkschool-dev-rg',
    [string] $Repo            = 'thinkbridge-thinkschool/VaishaleeSingh',
    [string] $DisplayName     = 'github-actions-quotes (dev)',
    [string] $Registry        = 'cr7mo4cimyk4vnk',
    [string[]] $ContainerApps = @('quotes-api-dev', 'quotes-web-dev')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)
    $raw = & az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $joined = ($raw -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined) -or $joined.Trim() -eq '[]') { return $null }
    try { return $joined | ConvertFrom-Json } catch { return $null }
}
function Has { param($o, [string] $n) if ($null -eq $o) { return $false } return ($o.PSObject.Properties.Name -contains $n) }

Write-Host ''
Write-Host 'Day 26 -- GitHub Actions OIDC, no stored credential' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die 'az is not on PATH.' }
az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Could not select the subscription. Run az login.' }

$tenantId = az account show --query tenantId -o tsv
if ($tenantId -ne $ExpectedTenant) { Die "Signed in to tenant $tenantId, expected $ExpectedTenant (Amity)." }
Ok "Tenant $tenantId"

# ---------------------------------------------------------------------------
# 1. The app registration
# ---------------------------------------------------------------------------
$app = $null
$existing = Invoke-AzJson @('ad', 'app', 'list', '--display-name', $DisplayName, '-o', 'json')
if ($null -ne $existing -and @($existing).Count -gt 0) {
    $app = @($existing)[0]
    Ok "Found existing registration: $($app.appId)"
} else {
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'create the OIDC app registration')) {
        Note 'WhatIf: would create the registration; stopping.'
        exit 0
    }
    $app = Invoke-AzJson @('ad', 'app', 'create', '--display-name', $DisplayName,
                           '--sign-in-audience', 'AzureADMyOrg', '-o', 'json')
    if ($null -eq $app) { Die 'Creating the registration failed (Authorization_RequestDenied means you need the Application Developer role).' }
    Ok "Created: $($app.appId)"
    Start-Sleep -Seconds 5
}
$appId = $app.appId

# The SERVICE PRINCIPAL is a separate object from the registration, and this
# is the step most often missed. The registration defines the application; the
# service principal is its identity IN THIS TENANT, and a role can only be
# assigned to the latter. Without it, `az role assignment create` fails with
# "cannot find user or service principal in graph database" -- which sounds
# like the app does not exist, when in fact it does.
$sp = Invoke-AzJson @('ad', 'sp', 'show', '--id', $appId, '-o', 'json')
if ($null -eq $sp) {
    if ($PSCmdlet.ShouldProcess($appId, 'create the service principal')) {
        $sp = Invoke-AzJson @('ad', 'sp', 'create', '--id', $appId, '-o', 'json')
        if ($null -eq $sp) { Die 'Creating the service principal failed.' }
        Ok "Service principal: $($sp.id)"
        Start-Sleep -Seconds 10
    }
} else {
    Ok "Service principal exists: $($sp.id)"
}

# ---------------------------------------------------------------------------
# 2. Federated credentials -- one per trigger shape
# ---------------------------------------------------------------------------
# The workflows run on pushes to main and on pull requests. Those send
# DIFFERENT subject claims, so one credential does not cover both.
$creds = @(
    @{ name = 'main';         subject = "repo:${Repo}:ref:refs/heads/main" }
    @{ name = 'pull-request'; subject = "repo:${Repo}:pull_request" }
)

$existingCreds = Invoke-AzJson @('ad', 'app', 'federated-credential', 'list', '--id', $appId, '-o', 'json')
$existingSubjects = @()
if ($null -ne $existingCreds) { $existingSubjects = @($existingCreds | ForEach-Object { $_.subject }) }

foreach ($c in $creds) {
    if ($existingSubjects -contains $c.subject) {
        Ok "Federated credential already present: $($c.subject)"
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($c.subject, 'add federated credential')) { continue }

    $body = @{
        name      = $c.name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $c.subject
        # api://AzureADTokenExchange is the fixed audience for this flow. It is
        # not a URL anyone calls and not a value to invent.
        audiences = @('api://AzureADTokenExchange')
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fc-" + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        ($body | ConvertTo-Json -Depth 5) | Out-File $tmp -Encoding utf8
        $null = & az ad app federated-credential create --id $appId --parameters "@$tmp" 2>$null
        if ($LASTEXITCODE -ne 0) { Die "Adding the federated credential '$($c.name)' failed." }
        Ok "Federated credential added: $($c.subject)"
    } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------------------
# 3. Roles, scoped to the resources the workflows actually touch
# ---------------------------------------------------------------------------
$principalId = (Invoke-AzJson @('ad', 'sp', 'show', '--id', $appId, '-o', 'json')).id

function Grant {
    param([string] $Role, [string] $Scope, [string] $What)
    $have = Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $principalId, '--scope', $Scope, '-o', 'json')
    if ($null -ne $have -and @($have | Where-Object { $_.roleDefinitionName -eq $Role }).Count -gt 0) {
        Ok "$Role already granted on $What"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($What, "grant $Role")) { return }
    $null = & az role assignment create --role $Role --assignee-object-id $principalId `
                --assignee-principal-type ServicePrincipal --scope $Scope -o none 2>$null
    if ($LASTEXITCODE -ne 0) { Die "Granting $Role on $What failed (needs Owner or User Access Administrator)." }
    Ok "$Role granted on $What"
}

$acrScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$Registry"
Grant -Role 'AcrPush' -Scope $acrScope -What "registry $Registry"

foreach ($appName in $ContainerApps) {
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$appName"
    Grant -Role 'Contributor' -Scope $scope -What "container app $appName"
}

# ---------------------------------------------------------------------------
# 4. What to put in the repository
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Set these three as repository SECRETS:' -ForegroundColor Cyan
Write-Host "  https://github.com/$Repo/settings/secrets/actions"
Write-Host ''
Write-Host "  AZURE_CLIENT_ID        $appId"
Write-Host "  AZURE_TENANT_ID        $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID  $SubscriptionId"
Write-Host ''
Note 'None of these three is actually secret -- they are directory and'
Note 'subscription identifiers, and the workflow comments say so. They are'
Note 'stored as secrets because azure/login expects them there, not because'
Note 'knowing them grants anything. The trust lives in the federated'
Note 'credential, which names one repository and one ref.'
Write-Host ''
Note 'A run on any OTHER branch will still fail: its subject is not one of the'
Note 'two above. Add a credential for that ref if you need it, rather than'
Note 'widening these.'
Write-Host ''
