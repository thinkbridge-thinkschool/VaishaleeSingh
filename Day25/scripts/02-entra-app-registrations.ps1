<#
.SYNOPSIS
    Day 25, Phase 3. Creates the API and SPA app registrations in the tenant
    that owns this subscription, and prints the parameter lines to paste.

.DESCRIPTION
    WHY THE REGISTRATION HAD TO MOVE.

    The API's Entra scheme points at app registration 91566dbd-… in tenant
    f774bb68-… -- the OLD subscription's directory. That works: validating a
    token is an HTTPS call to an authority URL and has no relationship to
    which tenant owns the subscription. It is nonetheless wrong to leave,
    because it makes a directory nobody is paying for a permanent runtime
    dependency of this app, in a project whose whole point this week is that
    identity is coherent end to end. The managed identities, the SQL
    administrator and the GitHub OIDC principal all live in Amity; the app's
    user-facing identity provider should too.

    AND IT FIXES A BUG THAT WAS ALWAYS THERE. main.bicep sets
    azureAdAudience to 'api://quotes-api/access'. That is a SCOPE string, not
    an audience. Entra issues access tokens whose `aud` claim is the resource
    app's Application ID URI -- api://<appId> -- with the scope carried
    separately in `scp`. So the EntraId scheme as configured would reject
    every genuine Entra token it was ever handed, with ValidateAudience
    failing. Nothing caught it because nothing has yet sent one: the SPA signs
    in against the app's own CustomJwt endpoints. This script emits the
    correct value.

    NO CLIENT SECRET IS CREATED, AND NONE IS NEEDED. The SPA is registered as
    a public client using authorization code with PKCE, which is the correct
    shape for a browser app -- a browser cannot keep a secret, and a "confidential"
    SPA is a contradiction that ends with a credential in a bundle. The API is
    a resource server: it validates tokens and never requests them, so it has
    no credential either. Day 25 adds two app registrations and zero secrets.

    IDEMPOTENT. Looks registrations up by display name and updates in place,
    so a re-run does not create duplicates -- and duplicate registrations with
    the same name are genuinely nasty to diagnose later, because the wrong
    client id fails as an audience mismatch rather than as anything naming the
    duplicate.

.PARAMETER WhatIf
    Report what would be created or changed, without touching the directory.

.EXAMPLE
    ./Day25/scripts/02-entra-app-registrations.ps1 -WhatIf
    ./Day25/scripts/02-entra-app-registrations.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ExpectedTenantId = '8d46a076-d093-416d-a57b-8692cde13bf8',
    [string] $ApiDisplayName = 'QuotesApi (dev)',
    [string] $SpaDisplayName = 'quotes-web (dev)',
    [string] $WebUrl = 'https://quotes-web-dev.greenhill-88fb93d9.uaenorth.azurecontainerapps.io'
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

function Invoke-Graph {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Url,
        [object] $Body
    )
    if ($null -eq $Body) {
        return Invoke-AzJson @('rest', '--method', $Method, '--url', $Url)
    }

    # Through a FILE rather than inline. A JSON body on the command line has to
    # survive PowerShell quoting and then az's own parsing, and the failure is
    # silent -- az reports a Graph validation error about a property you did
    # send, mangled. A file has neither problem.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("graph-" + [Guid]::NewGuid().ToString("N") + ".json")
    try {
        ($Body | ConvertTo-Json -Depth 20) | Out-File $tmp -Encoding utf8
        return Invoke-AzJson @('rest', '--method', $Method, '--url', $Url,
                               '--headers', 'Content-Type=application/json',
                               '--body', "@$tmp")
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Has { param($o, [string] $n) if ($null -eq $o) { return $false } return ($o.PSObject.Properties.Name -contains $n) }

Write-Host ''
Write-Host 'Day 25 Phase 3 -- Entra app registrations in the subscription''s own tenant' -ForegroundColor Cyan
Write-Host ''

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Die 'az is not on PATH.' }
az account set --subscription $SubscriptionId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Could not select the subscription. Run az login.' }

$tenantId = az account show --query tenantId -o tsv
if ($tenantId -ne $ExpectedTenantId) {
    Die "Signed in to tenant $tenantId, expected $ExpectedTenantId (Amity). Registrations created in the wrong directory look correct and fail at token validation."
}
Ok "Tenant $tenantId"

# ---------------------------------------------------------------------------
# 0. Can this account create app registrations at all?
# ---------------------------------------------------------------------------
# Worth checking BEFORE creating anything, because the failure otherwise
# arrives halfway through -- API app created, SPA refused -- and a half-built
# pair is worse than none. Many tenants, student ones especially, set
# allowedToCreateApps false so that only Application Developers can register.
$policy = Invoke-Graph -Method GET -Url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy'
$canCreate = $true
if ($null -ne $policy -and (Has $policy 'defaultUserRolePermissions')) {
    $perm = $policy.defaultUserRolePermissions
    if (Has $perm 'allowedToCreateApps') { $canCreate = [bool] $perm.allowedToCreateApps }
}
if ($canCreate) {
    Ok 'The tenant allows regular users to register applications.'
} else {
    Note 'This tenant does NOT let regular users register applications.'
    Note 'You need the Application Developer role (or Cloud Application Administrator).'
    Note 'If the create below fails with Authorization_RequestDenied, that is why --'
    Note 'ask a directory admin to grant Application Developer, or to run this script.'
}

# ---------------------------------------------------------------------------
# 1. The API app registration (the resource server)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'API registration' -ForegroundColor Cyan

$apiApp = $null
$existing = Invoke-Graph -Method GET -Url ("https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$ApiDisplayName'")
if ($null -ne $existing -and (Has $existing 'value') -and @($existing.value).Count -gt 0) {
    $apiApp = @($existing.value)[0]
    Ok "Found existing: $($apiApp.appId)"
} else {
    if (-not $PSCmdlet.ShouldProcess($ApiDisplayName, 'create API app registration')) {
        Note 'WhatIf: would create the API registration; stopping here.'
        exit 0
    }
    # signInAudience AzureADMyOrg: single tenant. This API has no reason to
    # accept identities from other directories, and the multi-tenant options
    # are one dropdown away from doing exactly that.
    $apiApp = Invoke-Graph -Method POST -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
        displayName    = $ApiDisplayName
        signInAudience = 'AzureADMyOrg'
    }
    if ($null -eq $apiApp) { Die 'Creating the API registration failed. If this was Authorization_RequestDenied, see the note above.' }
    Ok "Created: $($apiApp.appId)"
    Start-Sleep -Seconds 5   # Graph is eventually consistent; the PATCH below can 404 otherwise.
}

$apiAppId     = $apiApp.appId
$apiObjectId  = $apiApp.id
$identifierUri = "api://$apiAppId"

# Reuse the scope's GUID if it already exists. Regenerating it would orphan
# every consent already granted against the old id, and consents do not
# announce themselves as the reason a client suddenly cannot get a token.
$scopeId = [Guid]::NewGuid().ToString()
if ((Has $apiApp 'api') -and $null -ne $apiApp.api -and (Has $apiApp.api 'oauth2PermissionScopes')) {
    $existingScope = @($apiApp.api.oauth2PermissionScopes | Where-Object { $_.value -eq 'access' })
    if ($existingScope.Count -gt 0) {
        $scopeId = $existingScope[0].id
        Ok "Reusing existing 'access' scope id $scopeId"
    }
}

if ($PSCmdlet.ShouldProcess($ApiDisplayName, 'set identifier URI and expose the access scope')) {
    $null = Invoke-Graph -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$apiObjectId" -Body @{
        identifierUris = @($identifierUri)
        api = @{
            oauth2PermissionScopes = @(
                @{
                    id                      = $scopeId
                    value                   = 'access'
                    type                    = 'User'
                    isEnabled               = $true
                    adminConsentDisplayName = 'Access QuotesApi'
                    adminConsentDescription = 'Allows the application to call QuotesApi as the signed-in user.'
                    userConsentDisplayName  = 'Access QuotesApi'
                    userConsentDescription  = 'Allows the app to call QuotesApi on your behalf.'
                }
            )
        }
    }
    Ok "Identifier URI: $identifierUri"
    Ok "Scope: $identifierUri/access"
}

# ---------------------------------------------------------------------------
# 2. The SPA app registration (public client, PKCE, no secret)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'SPA registration' -ForegroundColor Cyan

$spaApp = $null
$existing = Invoke-Graph -Method GET -Url ("https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$SpaDisplayName'")
if ($null -ne $existing -and (Has $existing 'value') -and @($existing.value).Count -gt 0) {
    $spaApp = @($existing.value)[0]
    Ok "Found existing: $($spaApp.appId)"
} elseif ($PSCmdlet.ShouldProcess($SpaDisplayName, 'create SPA app registration')) {
    $spaApp = Invoke-Graph -Method POST -Url 'https://graph.microsoft.com/v1.0/applications' -Body @{
        displayName    = $SpaDisplayName
        signInAudience = 'AzureADMyOrg'
    }
    if ($null -eq $spaApp) { Die 'Creating the SPA registration failed.' }
    Ok "Created: $($spaApp.appId)"
    Start-Sleep -Seconds 5
}

if ($null -ne $spaApp -and $PSCmdlet.ShouldProcess($SpaDisplayName, 'set SPA redirect URIs and API permission')) {
    # The `spa` redirect type, NOT `web`. It is what enables PKCE and the CORS
    # headers on the token endpoint that a browser needs; registering a browser
    # app under `web` produces a token request the browser cannot make, and the
    # error names CORS rather than the registration.
    $null = Invoke-Graph -Method PATCH -Url "https://graph.microsoft.com/v1.0/applications/$($spaApp.id)" -Body @{
        spa = @{
            redirectUris = @('http://localhost:4200', $WebUrl)
        }
        requiredResourceAccess = @(
            @{
                resourceAppId  = $apiAppId
                resourceAccess = @(
                    @{ id = $scopeId; type = 'Scope' }
                )
            }
        )
    }
    Ok 'Redirect URIs: http://localhost:4200 and the dev web app'
    Ok "Delegated permission on $identifierUri/access"
}

# ---------------------------------------------------------------------------
# 3. The lines to paste
# ---------------------------------------------------------------------------
# WRITTEN INTO THE PARAMETER FILE RATHER THAN PRINTED TO COPY. Three GUIDs
# transcribed by hand is three chances to transpose a character, and every one
# of those mistakes fails the same way -- as an audience or issuer mismatch at
# token validation, which reads like a broken auth scheme rather than a typo.
$paramFile = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Day7\piece2\infra\main.dev.bicepparam'

if (-not (Test-Path $paramFile)) {
    Note "Could not find $paramFile. Set these by hand instead:"
    Write-Host "param azureAdTenantId = '$tenantId'"
    Write-Host "param azureAdClientId = '$apiAppId'"
    Write-Host "param azureAdAudience = '$identifierUri'"
} elseif ($PSCmdlet.ShouldProcess($paramFile, 'write the Entra parameters')) {
    $content = Get-Content $paramFile -Raw
    if ([string]::IsNullOrWhiteSpace($content)) { Die "$paramFile is empty." }

    # The audience line is the anchor: it is the only one of the three this file
    # currently sets, the other two falling through to main.bicep's defaults.
    # Replacing it with all three moves every Entra value into one visible place
    # rather than leaving two of them inherited and invisible here.
    $replacement = @"
param azureAdTenantId = '$tenantId'
param azureAdClientId = '$apiAppId'

// api://<appId>, the Application ID URI -- NOT the scope. Entra puts the
// resource's app ID URI in the token's aud claim and carries the scope
// separately in scp, so the previous value ('api://quotes-api/access') would
// have failed audience validation on every genuine token.
param azureAdAudience = '$identifierUri'
"@

    $pattern = "(?m)^param azureAdAudience = '[^']*'"
    if ($content -notmatch $pattern) {
        Note 'Could not find the azureAdAudience line to replace. Set these by hand:'
        Write-Host "param azureAdTenantId = '$tenantId'"
        Write-Host "param azureAdClientId = '$apiAppId'"
        Write-Host "param azureAdAudience = '$identifierUri'"
    } else {
        # Idempotent: a re-run rewrites the same three lines rather than stacking
        # duplicates, because the tenant and client lines are removed first.
        $content = $content -replace "(?m)^param azureAdTenantId = '[^']*'\r?\n", ''
        $content = $content -replace "(?m)^param azureAdClientId = '[^']*'\r?\n", ''
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement.TrimEnd() }, 1)
        Set-Content -Path $paramFile -Value $content -NoNewline
        Ok "Wrote the three Entra parameters into main.dev.bicepparam"
    }
}

Write-Host ''
Write-Host 'Values written:' -ForegroundColor Cyan
Write-Host "  tenant   $tenantId"
Write-Host "  clientId $apiAppId"
Write-Host "  audience $identifierUri"
Write-Host ''
Note "The audience is api://<appId> and NOT the scope. A token's aud claim is the"
Note 'resource Application ID URI; the scope travels separately in scp.'
Write-Host ''
if ($null -ne $spaApp) {
    Write-Host 'For the SPA, when it moves to MSAL (not this session):' -ForegroundColor Cyan
    Write-Host "  clientId  $($spaApp.appId)"
    Write-Host "  authority https://login.microsoftonline.com/$tenantId"
    Write-Host "  scope     $identifierUri/access"
    Write-Host ''
}
Note 'Neither registration has a client secret, and neither needs one: the SPA is a'
Note 'public client using PKCE, and the API only validates tokens.'
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  1. Review the change:  git diff Day7/piece2/infra/main.dev.bicepparam'
Write-Host '  2. Redeploy the stack so the container app picks up the new AzureAd__* values.'
Write-Host '  3. Re-run Day25/scripts/00-prove-no-secrets.ps1 -- it should still be 13/0,'
Write-Host '     because none of this adds a secret. That is the point of checking.'
Write-Host ''
