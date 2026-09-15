<#
.SYNOPSIS
    Creates the topic, subscriptions and filter rules QuotesPlatform.Contracts.
    ServiceBusTopology names. Idempotent.

.DESCRIPTION
    WHY THIS EXISTS. Day 29 built four outbox relays that publish to
    "capstone.collection-events" and three consumer hosts that read from its
    subscriptions -- and nothing in this repository created any of them. The
    Bicep in Day7/piece2/infra provisions the namespace and the OLD topology
    ("quote-events" with "audit" and "search-index"); the capstone's topology
    was never added to it, to a script, or to the runbook.

    The failure mode is worth knowing, because it does not look like a missing
    topic. ServiceBusClient.CreateSender() succeeds -- it resolves nothing at
    construction -- so the relay starts cleanly and the first SendMessageAsync
    fails with MessagingEntityNotFound, which the relay logs and retries five
    times before parking the row as Failed. The consumer host fails louder, on
    StartProcessingAsync, but by then the host is already up.

    WHY A SCRIPT AND NOT BICEP. This is the honest short answer: it SHOULD be
    Bicep, alongside the existing servicebus.bicep module, and that is the next
    build day's job. A script that provisions it today is what lets the happy
    path actually run today; it is not where this belongs permanently. That is
    a trade recorded, not a decision made quietly.

    THE FILTER RULES MATTER. Each subscription carries a SQL filter on the
    "eventType" application property, which is what OutboxRelayService sets and
    what the body is not addressable by. Without them every subscription
    receives every event and each consumer logs "No handler registered ...
    completing as a no-op" -- survivable, but it dead-letters nothing, doubles
    the receive volume, and hides a genuinely missing handler in noise.

    And note what adding a rule does, which Day 23 learned the hard way:
    Service Bus DELETES the $Default (match-everything) rule the moment the
    first explicit rule is added to a subscription. That is why the rules below
    are created rather than "added alongside" -- there is nothing to remove.

.EXAMPLE
    ./Day29/scripts/00-provision-servicebus-topology.ps1 -DryRun
    ./Day29/scripts/00-provision-servicebus-topology.ps1
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId = '85567e22-432e-4648-aa68-ba2714167694',
    [string] $ResourceGroup  = 'thinkschool-dev-rg',
    [string] $Namespace      = 'sb-quotes-7mo4cimyk4vnk',

    # Must match QuotesPlatform.Contracts.ServiceBusTopology.TopicName.
    [string] $TopicName      = 'capstone.collection-events',

    # Matches the consumer hosts' own expectation (Day 22 design: dead-letter
    # after five, so a poison message stops being redelivered forever).
    [int]    $MaxDeliveryCount = 5,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Subscription name -> the eventType filter it should carry. Kept in one place
# so the three creates below cannot drift from each other.
$subscriptions = [ordered]@{
    'moderation-review-requests' = "eventType = 'CollectionSubmittedForPublication'"
    'curation-review-decisions'  = "eventType IN ('CollectionApproved','CollectionRejected')"
    'publishing-editions'        = "eventType = 'CollectionPublished'"
}

function Invoke-Az {
    param([string[]] $Arguments, [switch] $AllowFailure)

    if ($DryRun) {
        Write-Host "  DRYRUN az $($Arguments -join ' ')"
        return $null
    }

    # az writes its errors to stderr. Merging stderr into the output stream
    # while $ErrorActionPreference is 'Stop' makes PowerShell raise a
    # terminating NativeCommandError the moment az says anything there --
    # before $LASTEXITCODE is read. That made -AllowFailure unreachable, so
    # the first "does this exist?" probe that legitimately missed killed the
    # script instead of creating the entity. Drop to 'Continue' for the
    # duration of the call and decide on the exit code, which is the only
    # signal az gives us that distinguishes absent from broken.
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

        # Print az's own message. A generic "provisioning failed" in place of
        # the real reason is a guess wearing the clothes of a diagnosis.
        throw "az $($Arguments -join ' ') failed:`n$output"
    }

    return $output
}

function Test-AzEntity {
    <#
        Existence probe. Deliberately runs even under -DryRun: 'show' is
        read-only, and a dry run that skips its probes cannot tell you what a
        real run would do -- it can only tell you what it would type. The
        earlier version reported "already exists" for every entity because a
        skipped probe returns $null and $null was read as "found".

        Returns a boolean from the exit code rather than from output, because
        '-o none' prints nothing on success and nothing is indistinguishable
        from absent.
    #>
    param([string[]] $Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & az @Arguments 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
    }

    return ($LASTEXITCODE -eq 0)
}

Write-Host "Subscription : $SubscriptionId"
Write-Host "Namespace    : $Namespace ($ResourceGroup)"
Write-Host "Topic        : $TopicName"
Write-Host ""

Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

Write-Host "== Topic =="
$topicExists = Test-AzEntity @(
    'servicebus', 'topic', 'show',
    '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
    '--name', $TopicName, '-o', 'none')

if (-not $topicExists) {
    Invoke-Az @(
        'servicebus', 'topic', 'create',
        '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
        '--name', $TopicName,
        '--default-message-time-to-live', 'P1D',
        '--max-size', '1024',
        '--enable-duplicate-detection', 'false',
        '-o', 'none') | Out-Null
    Write-Host "  created $TopicName"
}
else {
    Write-Host "  $TopicName already exists"
}

foreach ($name in $subscriptions.Keys) {
    $filter = $subscriptions[$name]

    Write-Host ""
    Write-Host "== Subscription $name =="

    $subscriptionExists = $topicExists -and (Test-AzEntity @(
        'servicebus', 'topic', 'subscription', 'show',
        '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
        '--topic-name', $TopicName, '--name', $name, '-o', 'none'))

    if (-not $subscriptionExists) {
        Invoke-Az @(
            'servicebus', 'topic', 'subscription', 'create',
            '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
            '--topic-name', $TopicName, '--name', $name,
            '--max-delivery-count', "$MaxDeliveryCount",
            '--dead-letter-on-message-expiration', 'true',
            '--lock-duration', 'PT1M',
            '-o', 'none') | Out-Null
        Write-Host "  created $name"
    }
    else {
        Write-Host "  $name already exists"
    }

    # One rule per subscription, named for what it selects on. Recreated rather
    # than patched: a rule's filter cannot be updated in place, and leaving a
    # stale expression behind is how a subscription quietly stops matching.
    Invoke-Az @(
        'servicebus', 'topic', 'subscription', 'rule', 'delete',
        '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
        '--topic-name', $TopicName, '--subscription-name', $name,
        '--name', 'eventType', '-o', 'none') -AllowFailure | Out-Null

    Invoke-Az @(
        'servicebus', 'topic', 'subscription', 'rule', 'create',
        '--resource-group', $ResourceGroup, '--namespace-name', $Namespace,
        '--topic-name', $TopicName, '--subscription-name', $name,
        '--name', 'eventType',
        '--filter-sql-expression', $filter,
        '-o', 'none') | Out-Null

    Write-Host "  filter: $filter"
}

Write-Host ""
if ($DryRun) {
    Write-Host "DRY RUN -- nothing was created."
}
else {
    Write-Host "Topology ready. The app's managed identity or your own principal still needs"
    Write-Host "Azure Service Bus Data Sender on the topic and Data Receiver on each subscription"
    Write-Host "(the namespace has disableLocalAuth = true, so there is no connection-string path)."
}
