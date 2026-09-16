namespace QuotesPlatform.SharedKernel;

/// <summary>
/// Tracks which (MessageId, SubscriptionName) pairs a consumer has already
/// handled -- consumer-side idempotency for at-least-once delivery.
///
/// Composite key: two subscriptions on the same topic can receive the same
/// MessageId for one publish (not the case for any single module today, since
/// each module owns exactly one subscription, but the key shape is what keeps
/// that true if a module ever grows a second one).
///
/// The PRIMARY KEY constraint is the actual guarantee under concurrency, not
/// an application-level check-then-act: two concurrent deliveries can both
/// read "not seen", and exactly one INSERT succeeds. The loser's
/// DbUpdateException is what "already processed" looks like -- see each
/// module's ServiceBusConsumerHost.
/// </summary>
public sealed class ProcessedMessage
{
    public required string MessageId { get; set; }
    public required string SubscriptionName { get; set; }
    public required DateTime ProcessedAtUtc { get; set; }
}
