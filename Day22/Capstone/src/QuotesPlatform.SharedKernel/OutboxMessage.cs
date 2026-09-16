namespace QuotesPlatform.SharedKernel;

/// <summary>
/// One row per integration event a committed change intends to publish.
///
/// Written in the SAME transaction as the domain change it describes -- each
/// module's repository SaveChangesAsync commits both together, so the two
/// cannot diverge. This is the mechanism ADR-0001
/// (Day28/docs/adr/0001-transactional-outbox.md) argues for and Day 29 builds.
///
/// The relay (commit 6) publishes and then marks the row Sent -- two systems,
/// no distributed transaction between them -- so a crash in that gap
/// republishes on restart. That is deliberate and safe only because every
/// consumer dedupes on MessageId (see each module's ProcessedMessages table,
/// commit 7).
/// </summary>
public sealed class OutboxMessage
{
    /// <summary>Database-generated. The relay claims and publishes in Id order, not by OccurredAtUtc -- wall-clock timestamps skew between instances.</summary>
    public long Id { get; set; }

    /// <summary>The integration event's own MessageId -- unique here, and the broker's MessageId once sent.</summary>
    public required Guid MessageId { get; set; }

    /// <summary>The event's CLR type name, read without deserialising Payload -- the relay uses it to route.</summary>
    public required string EventType { get; set; }

    /// <summary>The serialised integration event, frozen at write time.</summary>
    public required string Payload { get; set; }

    /// <summary>W3C traceparent of the request that enqueued this row, so the relay's span can be its child.</summary>
    public string? TraceParent { get; set; }

    public required DateTime OccurredAtUtc { get; set; }

    /// <summary>Pending | Sent | Failed. See <see cref="OutboxStatus"/>.</summary>
    public required string Status { get; set; }

    public int Attempts { get; set; }

    public string? LastError { get; set; }

    /// <summary>Claim lease, not a boolean flag -- a relay killed mid-batch must not hold its rows forever.</summary>
    public DateTime? LockedUntilUtc { get; set; }

    public string? LockOwner { get; set; }

    public DateTime? SentAtUtc { get; set; }
}

public static class OutboxStatus
{
    public const string Pending = "Pending";
    public const string Sent = "Sent";
    public const string Failed = "Failed";
}
