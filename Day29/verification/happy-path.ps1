<#
.SYNOPSIS
    Runs the Day 29 happy path end to end against a running QuotesPlatform.Host:
    submit + publish a quote, create a collection, add three items, submit for
    review, wait for Moderation to open the review, approve it, wait for
    Publishing to build the edition, and print it.

.DESCRIPTION
    Every step is a real HTTP call; the waits between Submit -> Review and
    Approve -> Edition are real waits on the outbox relay + Service Bus round
    trip built in commits 5-7 -- there is no shortcut here that bypasses the
    messaging path. A failure partway through means a specific hop is broken,
    not "something in the pipeline".

.PARAMETER BaseUrl
    Where QuotesPlatform.Host is listening. Defaults to the local dev port.

.NOTES
    NOT RUN IN THIS SANDBOX: no reachable SQL Server or Azure Service Bus
    namespace here, so this script's correctness is by inspection, not by a
    captured passing run -- the same "state plainly what could not be
    verified" discipline Day13's submission used. Run it locally per
    Day29/docs/day29-plan.md Step 0 and Day29/docs/day29-submission.md.
#>
param(
    [string]$BaseUrl = "https://localhost:7113",
    [int]$TimeoutSeconds = 30,
    [int]$PollIntervalSeconds = 2
)

$ErrorActionPreference = "Stop"

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Probe,
        [string]$Description
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $result = & $Probe
        if ($null -ne $result) { return $result }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    throw "Timed out after $TimeoutSeconds s waiting for: $Description"
}

function Invoke-Api {
    param([string]$Method, [string]$Path, [hashtable]$Body)

    $uri = "$BaseUrl$Path"
    if ($Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -ContentType "application/json" -Body ($Body | ConvertTo-Json)
    }
    return Invoke-RestMethod -Method $Method -Uri $uri
}

Write-Host "== Commit 8: Catalog -- submit and publish three quotes =="
$quotes = 1..3 | ForEach-Object {
    $quote = Invoke-Api POST "/api/quotes" @{ Author = "Author $_"; Text = "Quote text number $_."; SubmittedByUserId = "curator-1" }
    Invoke-Api POST "/api/quotes/$($quote.id)/mark-publishable" $null
    Invoke-Api GET "/api/quotes/$($quote.id)"
}
$quotes | ForEach-Object { Write-Host "  quote $($_.id) publishable=$($_.isPublishable)" }

Write-Host "== Commit 9: Curation -- create a collection and add all three quotes =="
$collection = Invoke-Api POST "/api/collections" @{ Name = "Day 29 happy path"; OwnerId = "curator-1" }
foreach ($quote in $quotes) {
    Invoke-Api POST "/api/collections/$($collection.id)/items" @{
        QuoteId = $quote.id; Author = $quote.author; Text = $quote.text
        IsPublishable = $quote.isPublishable; ActorId = "curator-1"
    } | Out-Null
}
Invoke-Api POST "/api/collections/$($collection.id)/submit" @{ ActorId = "curator-1" } | Out-Null
Write-Host "  collection $($collection.id) submitted for publication"

Write-Host "== Commit 10: waiting for Moderation to open a review (outbox -> Service Bus -> consumer) =="
$review = Wait-Until -Description "review opened for collection $($collection.id)" -Probe {
    try { Invoke-Api GET "/api/reviews/by-subject/$($collection.id)" } catch { $null }
}
Write-Host "  review $($review.id) opened, outcome=$($review.outcome)"

Invoke-Api POST "/api/reviews/$($review.id)/approve" @{ ReviewerId = "reviewer-1" } | Out-Null
Write-Host "  review $($review.id) approved"

Write-Host "== Commit 11 + 12: waiting for the edition (Curation applies the approval, Publishing builds it) =="
$edition = Wait-Until -Description "edition published for collection $($collection.id)" -Probe {
    $published = Invoke-Api GET "/api/collections/$($collection.id)"
    if ($published.state -ne "Published") { return $null }

    # Slug is derived deterministically in CollectionPublishedHandler from the
    # collection's name and id -- recomputed here rather than guessed, so this
    # script breaks the same way the handler would if the two ever disagree.
    $slugified = ($collection.name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    $shortId = $collection.id.ToString("N").Substring(0, 8)
    $slug = "$slugified-$shortId"

    try { Invoke-Api GET "/api/editions/$slug" } catch { $null }
}

Write-Host ""
Write-Host "HAPPY PATH VERIFIED"
Write-Host "  Collection: $($collection.id)"
Write-Host "  Edition:    $($edition.editionNumber) at slug '$($edition.slug)'"
Write-Host "  Items:      $($edition.items.Count)"
$edition.items | ForEach-Object { Write-Host "    [$($_.position)] $($_.author): $($_.text)" }
