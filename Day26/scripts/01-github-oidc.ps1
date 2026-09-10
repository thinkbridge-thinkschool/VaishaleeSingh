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

    # THE SUBJECT THIS ORGANISATION ACTUALLY SENDS, which is not the one in
    # Microsoft's or GitHub's documentation. See the block at the credential
    # list below. Read it off a failing run's log rather than assuming: the
    # AADSTS700213 error quotes the presented subject verbatim, which is the
    # only reliable source for it.
    [string] $RepoWithIds     = 'thinkbridge-thinkschool@285446293/VaishaleeSingh@1331675643',
    [string] $DisplayName     = 'github-actions-quotes (dev)',
    [string] $Registry        = 'cr7mo4cimyk4vnk',
    [string[]] $ContainerApps = @('quotes-api-dev', 'quotes-web-dev')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Ok   ([string] $m) { Write-Host "  OK    $m" -ForegroundColor Green }
function Note ([string] $m) { Write-Host "  note  $m" -ForegroundColor Yellow }
function Die  ([string] $m) { Write-Host "  FAIL  $m" -ForegroundColor Red; exit 1 }

# $ErrorActionPreference IS LOWERED AROUND THE NATIVE CALL, AND IT HAS TO BE.
#
# With ErrorActionPreference = 'Stop', Windows PowerShell turns anything a
# NATIVE command writes to stderr into a terminating error -- even when the
# command succeeded, and even with 2>$null, because the redirect happens after
# PowerShell has already decided to throw. `az ad sp show` on an app that has
# no service principal yet writes "Resource ... does not exist" to stderr and
# returns non-zero, which is the ANSWER TO THE QUESTION, not a failure. Left
# alone it kills the script one line before the code that would create it.
#
# Same shape as the $args bug in Day24/scripts/04-finish-dev.ps1: a
# PowerShell default that is right for cmdlets and wrong for az.exe.
function Invoke-AzJson {
    param([Parameter(Mandatory)] [string[]] $AzArgs)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & az @AzArgs 2>$null
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($LASTEXITCODE -ne 0) { return $null }
    $joined = ($raw -join "`n")
    if ([string]::IsNullOrWhiteSpace($joined) -or $joined.Trim() -eq '[]') { return $null }
    try { return $joined | ConvertFrom-Json } catch { return $null }
}

# Entra ID is EVENTUALLY CONSISTENT, and a fixed Start-Sleep is a guess about
# how eventual. A registration created a second ago is routinely not yet
# visible to the next call, so every read that follows a write retries rather
# than assuming. The failure without this is indistinguishable from a
# permissions problem: "Resource does not exist".
function Wait-ForGraph {
    param(
        [Parameter(Mandatory)] [scriptblock] $Read,
        [string] $What = 'object',
        [int] $Attempts = 12,
        [int] $DelaySeconds = 5
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        $result = & $Read
        if ($null -ne $result) { return $result }
        if ($i -eq 1) { Write-Host "        waiting for $What to replicate" -ForegroundColor DarkGray -NoNewline }
        else { Write-Host '.' -ForegroundColor DarkGray -NoNewline }
        Start-Sleep -Seconds $DelaySeconds
    }
    Write-Host ''
    return $null
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
        # Retried: the registration may not have replicated yet, and `sp create`
        # then fails naming the app id, which reads as though the app was never
        # created rather than as a timing problem.
        $sp = Wait-ForGraph -What 'the app registration' -Read {
            Invoke-AzJson @('ad', 'sp', 'create', '--id', $appId, '-o', 'json')
        }
        if ($null -eq $sp) { Die 'Creating the service principal kept failing. Re-run in a minute; the registration already exists, so this is idempotent.' }
        Write-Host ''
        Ok "Service principal: $($sp.id)"
    }
} else {
    Ok "Service principal exists: $($sp.id)"
}

# ---------------------------------------------------------------------------
# 2. Federated credentials -- one per trigger shape
# ---------------------------------------------------------------------------
# The workflows run on pushes to main and on pull requests. Those send
# DIFFERENT subject claims, so one credential does not cover both.
# IMMUTABLE SUBJECT CLAIMS, AND WHY FOUR CREDENTIALS RATHER THAN TWO.
#
# The documented subject is repo:<owner>/<repo>:ref:refs/heads/main. This
# organisation does not send that. It sends:
#
#   repo:thinkbridge-thinkschool@285446293/VaishaleeSingh@1331675643:ref:refs/heads/main
#
# GitHub's immutable subject claims embed the organisation's and repository's
# DATABASE IDs alongside their names, so that deleting a repository and
# recreating one with the same name cannot inherit the trust the old one had.
# That is a real improvement -- names are reusable and ids are not -- and it
# silently invalidates every federated credential written the documented way.
#
# The failure is AADSTS700213, "No matching federated identity record found
# for presented assertion subject", and it quotes the subject it received.
# That quote is the only trustworthy source for what to register: the format
# depends on an organisation setting, not on anything visible from the
# repository.
#
# Both forms are registered because the setting can be changed by an
# administrator at any time, in either direction, and a spare federated
# credential costs nothing while a missing one costs a red pipeline and an
# error that names a directory record rather than a policy.
$subjects = @($Repo)
if (-not [string]::IsNullOrWhiteSpace($RepoWithIds) -and $RepoWithIds -ne $Repo) {
    $subjects += $RepoWithIds
}

$creds = @()
$index = 0
foreach ($subjectRepo in $subjects) {
    # Credential NAMES must be unique within the application and are limited
    # to 120 characters, so they are numbered rather than derived from the
    # subject -- which contains characters the name field will not take.
    $suffix = if ($index -eq 0) { '' } else { "-$index" }
    $creds += @{ name = "main$suffix";         subject = "repo:${subjectRepo}:ref:refs/heads/main" }
    $creds += @{ name = "pull-request$suffix"; subject = "repo:${subjectRepo}:pull_request" }
    $index++
}

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
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $null = & az ad app federated-credential create --id $appId --parameters "@$tmp" 2>$null }
        finally { $ErrorActionPreference = $previous }
        if ($LASTEXITCODE -ne 0) { Die "Adding the federated credential '$($c.name)' failed." }
        Ok "Federated credential added: $($c.subject)"
    } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------------------
# 3. Roles, scoped to the resources the workflows actually touch
# ---------------------------------------------------------------------------
$spRecord = Wait-ForGraph -What 'the service principal' -Read {
    Invoke-AzJson @('ad', 'sp', 'show', '--id', $appId, '-o', 'json')
}
if ($null -eq $spRecord) { Die 'The service principal is still not readable. Re-run; everything so far is idempotent.' }
$principalId = $spRecord.id

function Grant {
    param([string] $Role, [string] $Scope, [string] $What)
    $have = Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $principalId, '--scope', $Scope, '-o', 'json')
    if ($null -ne $have -and @($have | Where-Object { $_.roleDefinitionName -eq $Role }).Count -gt 0) {
        Ok "$Role already granted on $What"
        return
    }
    if (-not $PSCmdlet.ShouldProcess($What, "grant $Role")) { return }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & az role assignment create --role $Role --assignee-object-id $principalId `
                    --assignee-principal-type ServicePrincipal --scope $Scope -o none 2>$null
    } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { Die "Granting $Role on $What failed (needs Owner or User Access Administrator)." }
    Ok "$Role granted on $What"
}

$acrScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ContainerRegistry/registries/$Registry"

# ACRPUSH ALONE IS NOT ENOUGH, AND THE FAILURE IS ACTIVELY MISLEADING.
#
# AcrPush grants DATA-PLANE actions only -- registries/pull/read and
# registries/push/write. It does not grant
# Microsoft.ContainerRegistry/registries/read, the MANAGEMENT-plane read that
# `az acr login` performs first to resolve the registry before authenticating
# to it. Without it the command reports:
#
#   The resource with name 'cr...' and type
#   Microsoft.ContainerRegistry/registries could not be found in subscription
#
# COULD NOT BE FOUND, not "access denied": ARM answers 404 rather than 403 for
# resources you cannot read, deliberately, so that permissions cannot be used
# to probe what exists. The registry is there and the name is right; the
# principal simply cannot see it. Ten minutes go into checking the name and
# the subscription id before suspecting the role.
#
# Reader at the registry scope rather than at the resource group: this
# principal needs to see one resource, and Day 25 spent a day establishing
# that scope is where least privilege actually lives.
Grant -Role 'AcrPush' -Scope $acrScope -What "registry $Registry"
Grant -Role 'Reader'  -Scope $acrScope -What "registry $Registry (ARM read, required by az acr login)"

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
