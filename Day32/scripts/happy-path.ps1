<#
.SYNOPSIS
    The end-to-end demo against the deployed capstone: two authenticated
    identities walking submit -> moderate -> approve -> publish, plus the two
    negative cases that make the positive one mean something.

.DESCRIPTION
    WHY TWO IDENTITIES. With one, the curator who owns the collection is also
    the reviewer who approves it, so Collection.RequireOwner and the Review
    audit trail are satisfied trivially and the run proves nothing about
    either. Two client-credential identities have two distinct `oid` claims,
    which is what makes step 7 (a stranger is refused) a real result.

    WHAT THIS PROVES THAT THE 76 TESTS CANNOT. The API tests strip out every
    hosted service, so nothing crosses the broker there. This is the only thing
    that exercises the outbox relays, the Service Bus topic and its filters,
    and the consumers -- against the real namespace, with managed identity.

    WHAT IT CANNOT PROVE. It is one run of the happy path plus two guards. It
    is not a test suite and it does not replace one.

.PARAMETER SecretsPath
    Written by 01-provision-identity.ps1. Outside the repository on purpose.

.EXAMPLE
    ./Day32/scripts/happy-path.ps1 -BaseUrl https://ca-quotes-capstone....azurecontainerapps.io
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BaseUrl,
    [string] $SecretsPath = (Join-Path $env:USERPROFILE '.capstone-demo-secrets.json'),

    # The broker is asynchronous. Every wait below polls rather than sleeping a
    # fixed amount: a fixed sleep is either too short (flaky) or too long
    # (slow), and it hides how long the flow actually took.
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')

if (-not (Test-Path $SecretsPath)) {
    throw "No secrets file at $SecretsPath. Run ./Day32/scripts/01-provision-identity.ps1 first."
}

$config = Get-Content $SecretsPath -Raw | ConvertFrom-Json

function Get-Token {
    param([string] $ClientId, [string] $ClientSecret)

    # Client credentials: no user, no interaction, and the `oid` in the
    # resulting token is the service principal's -- which is exactly the
    # identity Collection.RequireOwner will compare against.
    $response = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$($config.tenantId)/oauth2/v2.0/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = $config.scope
            grant_type    = 'client_credentials'
        }

    return $response.access_token
}

function Invoke-Api {
    param(
        [string] $Method, [string] $Path, [string] $Token,
        $Body, [int[]] $Expect = @(200)
    )

    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    $arguments = @{
        Method  = $Method
        Uri     = "$BaseUrl$Path"
        Headers = $headers
        # Without this a non-2xx throws and the status code has to be dug out
        # of an exception -- and on Windows PowerShell 5.1 -SkipHttpErrorCheck
        # does not exist, so the dig is the only option.
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $arguments['Body'] = ($Body | ConvertTo-Json -Depth 6)
        $arguments['ContentType'] = 'application/json'
    }

    $status = 0
    $content = $null
    try {
        $response = Invoke-WebRequest @arguments -UseBasicParsing
        $status = [int] $response.StatusCode
        if ($response.Content) { $content = $response.Content | ConvertFrom-Json }
    }
    catch {
        $r = $_.Exception.Response
        if ($r -and $r.StatusCode) { $status = [int] $r.StatusCode }
        else { throw }
    }

    if ($status -notin $Expect) {
        throw "$Method $Path returned $status, expected $($Expect -join ' or ')."
    }

    return [pscustomobject]@{ Status = $status; Body = $content }
}

function Wait-For {
    param([string] $Description, [scriptblock] $Probe)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $started  = Get-Date

    while ((Get-Date) -lt $deadline) {
        $value = & $Probe
        if ($null -ne $value) {
            $elapsed = [int] ((Get-Date) - $started).TotalSeconds
            Write-Host "    ($Description after ${elapsed}s)"
            return $value
        }
        Start-Sleep -Seconds 2
    }

    throw @"
Timed out after ${TimeoutSeconds}s waiting for: $Description

This is the asynchronous half of the system, so the likely causes are in order:
  * Service Bus RBAC has not propagated yet (minutes after a first deploy)
  * a subscription filter does not match the eventType being published
  * the message dead-lettered after MaxDeliveryCount
Check the app's logs before assuming the code is wrong.
"@
}

Write-Host "Target: $BaseUrl"
Write-Host ''

# ---------------------------------------------------------------------------
Write-Host '1. Acquiring tokens for two distinct identities...'
$curatorToken  = Get-Token $config.clients.curator.appId  $config.clients.curator.secret
$reviewerToken = Get-Token $config.clients.reviewer.appId $config.clients.reviewer.secret
Write-Host '   curator and reviewer: two different service principals, two different oid claims'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '2. Anonymous write is refused...'
Invoke-Api -Method POST -Path '/api/collections' -Body @{ name = 'anonymous' } -Expect 401 | Out-Null
Write-Host '   401'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '3. Curator creates a collection...'
$slug = "demo-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$created = Invoke-Api -Method POST -Path '/api/collections' -Token $curatorToken `
    -Body @{ name = "Live demo $slug" } -Expect 201
$collectionId = $created.Body.id
Write-Host "   $collectionId  owner=$($created.Body.ownerId)"
Write-Host '   NOTE: ownerId came from the token. The request body could not name an owner.'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '4. Curator adds three items (Collection.MinItemsToPublish)...'
for ($i = 1; $i -le 3; $i++) {
    Invoke-Api -Method POST -Path "/api/collections/$collectionId/items" -Token $curatorToken -Body @{
        quoteId       = [guid]::NewGuid()
        author        = "Author $i"
        text          = "Quote text number $i for the live demo."
        isPublishable = $true
    } | Out-Null
}
Write-Host '   3 items'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '5. A DIFFERENT authenticated caller tries to rename it...'
$refused = Invoke-Api -Method PATCH -Path "/api/collections/$collectionId" -Token $reviewerToken `
    -Body @{ name = 'Renamed by someone else' } -Expect 400
Write-Host "   $($refused.Status) -- Collection.RequireOwner, now comparing a stored owner against a TOKEN"
Write-Host '   Before today this check passed for anyone who typed the owner id into the body.'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '6. Curator submits for publication (crosses the broker)...'
Invoke-Api -Method POST -Path "/api/collections/$collectionId/submit" -Token $curatorToken -Body @{} | Out-Null
Write-Host '   submitted -> outbox -> Service Bus -> Moderation'

$review = Wait-For 'Moderation opened a review' {
    $r = Invoke-Api -Method GET -Path "/api/reviews/by-subject/$collectionId" -Token $reviewerToken -Expect @(200, 404)
    if ($r.Status -eq 200) { $r.Body } else { $null }
}
Write-Host "   review $($review.id)"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '7. Reviewer approves...'
$approved = Invoke-Api -Method POST -Path "/api/reviews/$($review.id)/approve" -Token $reviewerToken -Body @{}
Write-Host "   outcome=$($approved.Body.outcome)  reviewerId=$($approved.Body.reviewerId)"
Write-Host '   THE AUDIT TRAIL: reviewerId is the token subject. It cannot be dictated by the caller.'

if ($approved.Body.reviewerId -eq $created.Body.ownerId) {
    throw 'The reviewer and the owner are the same identity -- this run proves nothing about ownership.'
}
Write-Host '   reviewer != owner, so the guards above were genuinely exercised'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '8. Waiting for Publishing to create the edition...'
$collection = Wait-For 'collection reached Published' {
    $c = Invoke-Api -Method GET -Path "/api/collections/$collectionId" -Token $curatorToken
    if ($c.Body.state -eq 'Published') { $c.Body } else { $null }
}

# THE SLUG IS NOT JUST THE NAME. CollectionPublishedHandler.Slugify lowercases
# the name, collapses every run of non-alphanumerics to a single hyphen, and
# then SUFFIXES the first eight hex characters of the collection id -- so two
# differently-owned collections sharing a name cannot collide.
#
# The first version of this script guessed the rule from the name alone and
# timed out for two minutes on a 404, after the edition had in fact been
# published five seconds earlier. Reconstructing a rule that exists in the code
# is a guess wearing a calculation's clothes; this one at least matches.
$namePart = ($collection.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
$shortId  = ([guid] $collectionId).ToString('N').Substring(0, 8)
$slug     = "$namePart-$shortId"

$edition = Wait-For "edition '$slug' is readable" {
    $e = Invoke-Api -Method GET -Path "/api/editions/$slug" -Token $curatorToken -Expect @(200, 404)
    if ($e.Status -eq 200) { $e.Body } else { $null }
}

Write-Host "   edition $($edition.editionNumber) with $($edition.items.Count) items"

Write-Host ''
Write-Host 'HAPPY PATH VERIFIED against the live deployment.'
Write-Host ''
Write-Host 'What this run established:'
Write-Host '  * anonymous writes are refused (401)'
Write-Host '  * the owner is the token subject, not a request field'
Write-Host '  * a different authenticated caller cannot act as the owner'
Write-Host '  * the review records the approving identity from its token'
Write-Host '  * all four modules exchanged events over the real Service Bus namespace'
