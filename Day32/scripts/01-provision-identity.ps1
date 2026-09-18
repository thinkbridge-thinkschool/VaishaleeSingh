<#
.SYNOPSIS
    Creates the Entra app registrations the deployed capstone authenticates
    with: one API, and two client identities for the demo.

.DESCRIPTION
    WHY TWO CLIENTS AND NOT ONE. happy-path.ps1 walks submit -> moderate ->
    approve -> publish. With a single identity the owner of the collection is
    also the reviewer who approves it, so every ownership guard in the flow is
    satisfied trivially and the demo proves nothing about them. Two client
    credentials give two distinct `oid` values, which is what makes
    Collection.RequireOwner and the Review audit trail mean something on the
    live system.

    THE PERMISSION THIS NEEDS, AND WHY IT MIGHT BE REFUSED. Creating app
    registrations only needs "Users can register applications" (this tenant:
    Yes). ASSIGNING an app role to a service principal is a different
    permission -- normally Application Administrator or Cloud Application
    Administrator -- and university tenants often keep it. If step 5 fails with
    Authorization_RequestDenied, that is what happened; the message says so and
    names the fallback rather than printing a raw AADSTS code.

    SECRETS NEVER REACH THE REPOSITORY OR A TRANSCRIPT. They are written to
    $env:USERPROFILE\.capstone-demo-secrets.json -- outside C:\thinkschool
    entirely, so no .gitignore mistake can commit them -- and this script
    prints only that path.

    IDEMPOTENT. Creating an app registration twice yields two apps with the
    same display name and different ids, which is genuinely unpleasant to
    unpick later. Everything below looks before it creates.

.EXAMPLE
    ./Day32/scripts/01-provision-identity.ps1 -DryRun
    ./Day32/scripts/01-provision-identity.ps1
#>
[CmdletBinding()]
param(
    [string] $ApiAppName      = 'quotes-capstone-api',
    [string] $CuratorAppName  = 'quotes-capstone-curator',
    [string] $ReviewerAppName = 'quotes-capstone-reviewer',

    # Any application requesting a token for the API must hold this role. It is
    # a single coarse role on purpose: the domain, not the token, decides who
    # may do what -- Collection.RequireOwner is the authorization model, and
    # splitting this into Curator/Reviewer roles would move a rule out of the
    # aggregate and into Entra, where the tests cannot see it.
    [string] $AppRoleName     = 'Capstone.Access',

    [string] $SecretsPath     = (Join-Path $env:USERPROFILE '.capstone-demo-secrets.json'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az CLI is not on PATH.'
}

function Invoke-Az {
    param([string[]] $Arguments, [switch] $AllowFailure, [switch] $Quiet)

    if ($DryRun -and -not $Quiet) {
        Write-Host "  DRYRUN az $($Arguments -join ' ')"
        return $null
    }

    # az writes warnings to stderr on success; with $ErrorActionPreference =
    # 'Stop' that becomes a terminating NativeCommandError before the exit code
    # is read. Same fix as 00-provision-azure.ps1 and Day 29's script.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & az @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ') failed:`n$output"
    }

    # 2>&1 merges stderr into the output stream as ErrorRecord objects, so on a
    # command that SUCCEEDS while printing a warning, $output is a mixed array
    # of ErrorRecords and strings. Callers here expect a string -- the first
    # version of this script called .Trim() on that array and died with
    # "does not contain a method named 'Trim'", which names the symptom and
    # nothing else.
    #
    # Drop the ErrorRecords (the exit code already said this succeeded) and
    # hand back plain text.
    $text = $output |
        Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { "$_" }

    return ($text -join [Environment]::NewLine)
}

function Get-AppId {
    # Runs even under -DryRun: a read tells us whether the create would be a
    # create or a no-op, and a dry run that cannot tell you that is decoration.
    param([string] $DisplayName)

    $id = Invoke-Az -Quiet -AllowFailure -Arguments @(
        'ad', 'app', 'list', '--display-name', $DisplayName,
        '--query', '[0].appId', '-o', 'tsv'
    )

    # `return if (...) {...}` is valid PowerShell 7 and a parse error on 5.1,
    # which is what this machine runs.
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    return "$id".Trim()
}

$tenantId = (Invoke-Az -Quiet @('account', 'show', '--query', 'tenantId', '-o', 'tsv')).Trim()
Write-Host "Tenant: $tenantId"
Write-Host ''

# ---------------------------------------------------------------------------
# 1. The API application.
# ---------------------------------------------------------------------------
Write-Host "API application '$ApiAppName'..."
$apiAppId = Get-AppId $ApiAppName

if ([string]::IsNullOrWhiteSpace($apiAppId)) {
    # AzureADMyOrg: single tenant. This is a capstone in a university
    # directory, not a multi-tenant SaaS, and a single-tenant app cannot be
    # used to sign in from any other organisation.
    Invoke-Az @(
        'ad', 'app', 'create', '--display-name', $ApiAppName,
        '--sign-in-audience', 'AzureADMyOrg'
    ) | Out-Null

    if (-not $DryRun) { $apiAppId = (Get-AppId $ApiAppName) }
    Write-Host "  created: $apiAppId"
}
else {
    Write-Host "  exists: $apiAppId"
}

$audience = "api://$apiAppId"

# ---------------------------------------------------------------------------
# 2. Identifier URI + the app role clients must hold.
# ---------------------------------------------------------------------------
if (-not $DryRun) {
    Write-Host "  identifier URI: $audience"
    Invoke-Az @('ad', 'app', 'update', '--id', $apiAppId, '--identifier-uris', $audience) | Out-Null

    # A deterministic role id derived from the role name, so re-running does
    # not mint a new GUID and orphan every existing assignment.
    $roleId = [guid]::new(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($AppRoleName))).Guid

    $appRoles = @(@{
        id                  = $roleId
        displayName         = $AppRoleName
        value               = $AppRoleName
        description         = 'Allows an application to call the Quotes Platform API.'
        # "Application" -- NOT "User". These are client-credential identities
        # with no signed-in user, so a role that only users can hold would be
        # unassignable to exactly the principals that need it.
        allowedMemberTypes  = @('Application')
        isEnabled           = $true
    })

    # -AsArray is PowerShell 7 only. On 5.1 a single-element array serialises
    # as a bare object, and `az ad app update --app-roles` then rejects it for
    # not being a list -- with a message about the payload, not about the
    # PowerShell version, which is a slow thing to work out.
    $rolesFile = Join-Path ([IO.Path]::GetTempPath()) 'capstone-approles.json'
    $rolesJson = ConvertTo-Json -InputObject $appRoles -Depth 5
    if (-not $rolesJson.TrimStart().StartsWith('[')) { $rolesJson = "[$rolesJson]" }
    Set-Content -Path $rolesFile -Value $rolesJson -Encoding utf8
    Write-Host "  app role: $AppRoleName"
    Invoke-Az @('ad', 'app', 'update', '--id', $apiAppId, '--app-roles', "@$rolesFile") | Out-Null
    Remove-Item $rolesFile -ErrorAction SilentlyContinue

    # ISSUE v2 TOKENS. Without this the app defaults to v1, and Entra returns
    # tokens whose issuer is https://sts.windows.net/{tenant}/ while the Host
    # is configured with the v2.0 authority, which expects
    # https://login.microsoftonline.com/{tenant}/v2.0.
    #
    # The failure is maximally confusing: the token is correctly signed, the
    # audience is right, the app role is present -- and every call returns 401.
    # Nothing in the 401 says "issuer", and the token looks fine until you
    # decode it and notice "ver": "1.0".
    #
    # Graph's PATCH needs the application's OBJECT id, not its appId; they are
    # different GUIDs for the same application and mixing them up gives a
    # not-found on an object that plainly exists.
    $apiObjectId = (Invoke-Az -Quiet @('ad', 'app', 'show', '--id', $apiAppId, '--query', 'id', '-o', 'tsv')).Trim()

    # ascii, not utf8: PowerShell 5.1 writes a BOM for utf8 and a JSON file
    # beginning with one is rejected in a way that blames the JSON.
    $versionFile = Join-Path ([IO.Path]::GetTempPath()) 'capstone-tokenversion.json'
    Set-Content -Path $versionFile -Value '{"api":{"requestedAccessTokenVersion":2}}' -Encoding ascii

    Write-Host '  access token version: 2'
    Invoke-Az -Quiet @(
        'rest', '--method', 'PATCH',
        '--uri', "https://graph.microsoft.com/v1.0/applications/$apiObjectId",
        '--headers', 'Content-Type=application/json',
        '--body', "@$versionFile") | Out-Null

    Remove-Item $versionFile -ErrorAction SilentlyContinue

    # The service principal is the tenant-local instance of the application.
    # Without it there is nothing to assign a role ON.
    Invoke-Az -AllowFailure @('ad', 'sp', 'create', '--id', $apiAppId) | Out-Null
}

$apiSpObjectId = if ($DryRun) { '<api-sp-object-id>' } else {
    (Invoke-Az -Quiet @('ad', 'sp', 'show', '--id', $apiAppId, '--query', 'id', '-o', 'tsv')).Trim()
}

# ---------------------------------------------------------------------------
# 3-5. The two client identities.
# ---------------------------------------------------------------------------
$clients = [ordered]@{ curator = $CuratorAppName; reviewer = $ReviewerAppName }
$result  = [ordered]@{
    tenantId  = $tenantId
    apiAppId  = $apiAppId
    audience  = $audience
    authority = "https://login.microsoftonline.com/$tenantId/v2.0"
    scope     = "$audience/.default"
    clients   = [ordered]@{}
}

foreach ($role in $clients.Keys) {
    $name = $clients[$role]
    Write-Host ''
    Write-Host "Client '$name' ($role)..."

    $clientAppId = Get-AppId $name
    if ([string]::IsNullOrWhiteSpace($clientAppId)) {
        Invoke-Az @('ad', 'app', 'create', '--display-name', $name, '--sign-in-audience', 'AzureADMyOrg') | Out-Null
        if (-not $DryRun) { $clientAppId = (Get-AppId $name) }
        Write-Host "  created: $clientAppId"
    }
    else {
        Write-Host "  exists: $clientAppId"
    }

    if ($DryRun) {
        Write-Host '  DRYRUN would create a service principal, reset the secret, and assign the app role'
        continue
    }

    Invoke-Az -AllowFailure @('ad', 'sp', 'create', '--id', $clientAppId) | Out-Null
    $clientSpObjectId = (Invoke-Az -Quiet @('ad', 'sp', 'show', '--id', $clientAppId, '--query', 'id', '-o', 'tsv')).Trim()

    # RESET, not append: re-running should leave exactly one usable secret, not
    # a growing pile nobody can tell apart. The value is captured and never
    # printed.
    $secret = (Invoke-Az -Quiet @(
        'ad', 'app', 'credential', 'reset', '--id', $clientAppId,
        '--years', '1', '--query', 'password', '-o', 'tsv'
    )).Trim()

    # THE BODY GOES IN A FILE, NOT ON THE COMMAND LINE.
    #
    # az on Windows is az.bat, and a JSON string containing double quotes does
    # not survive PowerShell -> cmd -> az intact: the quotes are stripped and
    # Graph receives something it cannot parse. The first version of this
    # script passed ConvertTo-Json -Compress directly and every assignment
    # failed -- which I then attributed, in a long and confident warning
    # message, to a tenant permission the account turned out to have all along.
    # Running the identical call by hand with \"-escaped quotes succeeded.
    #
    # @file is az's documented escape hatch for exactly this and has no
    # quoting to get wrong.
    $bodyFile = Join-Path ([IO.Path]::GetTempPath()) "capstone-assign-$role.json"
    @{
        principalId = $clientSpObjectId
        resourceId  = $apiSpObjectId
        appRoleId   = $roleId
    } | ConvertTo-Json -Compress | Set-Content -Path $bodyFile -Encoding utf8

    $assigned = Invoke-Az -Quiet -AllowFailure @(
        'rest', '--method', 'POST',
        '--uri', "https://graph.microsoft.com/v1.0/servicePrincipals/$clientSpObjectId/appRoleAssignedTo",
        '--headers', 'Content-Type=application/json',
        '--body', "@$bodyFile"
    )

    Remove-Item $bodyFile -ErrorAction SilentlyContinue

    # Re-running this script re-attempts an assignment that already exists,
    # which Graph rejects. That is a success, not a failure, so check before
    # warning about anything.
    if ($null -eq $assigned) {
        # appRoleAssignmentS, NOT appRoleAssignedTo. The names differ by three
        # characters and point in opposite directions:
        #
        #   /servicePrincipals/{id}/appRoleAssignedTo   -> who may call ME
        #   /servicePrincipals/{id}/appRoleAssignments  -> what roles I HOLD
        #
        # A client is never a resource, so querying appRoleAssignedTo on a
        # client returns an empty list for an assignment that definitely
        # exists. That empty list is indistinguishable from "not assigned",
        # which is how this produced a confident warning about a tenant
        # permission the account has.
        #
        # The POST above is correct on appRoleAssignedTo because the BODY names
        # the resource; only the read direction was wrong.
        $existing = Invoke-Az -Quiet -AllowFailure @(
            'rest', '--method', 'GET',
            '--uri', "https://graph.microsoft.com/v1.0/servicePrincipals/$clientSpObjectId/appRoleAssignments",
            '--query', "value[?appRoleId=='$roleId'].id", '-o', 'tsv'
        )

        if (-not [string]::IsNullOrWhiteSpace($existing)) {
            Write-Host '  app role already assigned'
            $assigned = $existing
        }
    }

    if ($null -eq $assigned) {
        # Deliberately NOT asserting a cause. The previous version of this
        # message confidently blamed a tenant permission the account turned out
        # to have; the real fault was this script's own request encoding. Print
        # the command that shows the actual error instead of a guess dressed up
        # as a diagnosis.
        Write-Warning @"
  Could not assign the '$AppRoleName' role to '$name', and no existing
  assignment was found either.

  Run this to see Graph's ACTUAL error -- do not assume it is a permission
  problem until it says so:

    az rest --method POST ``
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$clientSpObjectId/appRoleAssignedTo" ``
      --headers "Content-Type=application/json" ``
      --body '{\"principalId\":\"$clientSpObjectId\",\"resourceId\":\"$apiSpObjectId\",\"appRoleId\":\"$roleId\"}'

  Authorization_RequestDenied would mean the tenant withholds app-role
  assignment, and the fallback is a single demo identity plus an anonymous
  negative test -- weaker, because it cannot show one caller refused while
  another succeeds, and the submission would have to say so.
"@
    }
    else {
        Write-Host "  app role assigned"
    }

    $result.clients[$role] = [ordered]@{ appId = $clientAppId; secret = $secret }
}

# ---------------------------------------------------------------------------
# Output. Path only -- never the contents.
# ---------------------------------------------------------------------------
Write-Host ''
if ($DryRun) {
    Write-Host 'DRY RUN -- nothing was created.'
    return
}

$result | ConvertTo-Json -Depth 5 | Set-Content -Path $SecretsPath -Encoding utf8

Write-Host "Wrote $SecretsPath"
Write-Host ''
Write-Host 'That file holds two client secrets. It is deliberately OUTSIDE the repository.'
Write-Host 'Do not commit it, do not paste it anywhere, and delete it when the demo is done.'
Write-Host ''
Write-Host 'For the Container App configuration:'
Write-Host "  AzureAd__Authority = $($result.authority)"
Write-Host "  AzureAd__Audience  = $audience"
