using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Claims pending CurationDbContext.OutboxMessages rows, publishes them to the
/// shared "capstone.collection-events" topic, marks them Sent.
///
/// PUBLISH THEN MARK, in that order -- reversed, a crash in the gap would lose
/// the message. In this order a crash republishes on restart, which every
/// consumer's ProcessedMessages table (commit 7) absorbs as a no-op. Losing a
/// message is unrecoverable; a duplicate is a row that already exists. See
/// ADR-0001 for why at-least-once is the target and exactly-once is not on
/// offer.
///
/// Deliberately simpler than the Day 20 QuotesApi relay this mirrors: no
/// IClock seam, no metrics, no configurable options -- foundation only as deep
/// as today's happy path needs. The claim-by-conditional-update mechanic,
/// which is the part that actually has to be correct, is unchanged.
/// </summary>
public sealed class CurationOutboxRelayService(
    IServiceScopeFactory scopeFactory,
    ServiceBusClient serviceBusClient,
    ILogger<CurationOutboxRelayService> logger) : BackgroundService
{
    private const int BatchSize = 20;
    private const int MaxAttempts = 5;
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan LeaseDuration = TimeSpan.FromSeconds(30);

    /// <summary>Identifies this relay in LockOwner -- a restarted process must not be mistaken for its predecessor's still-held leases.</summary>
    private readonly string _owner = BuildOwnerId();

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var sender = serviceBusClient.CreateSender(ServiceBusTopology.TopicName);
        using var timer = new PeriodicTimer(PollInterval);

        do
        {
            try
            {
                int dispatched;
                do
                {
                    dispatched = await RunOnceAsync(sender, stoppingToken);
                }
                while (dispatched == BatchSize && !stoppingToken.IsCancellationRequested);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // A tick that throws must not kill the relay -- a dead relay
                // is invisible: writes keep succeeding and nothing publishes.
                logger.LogError(exception, "Curation outbox relay tick failed; continuing after the poll interval");
            }
        }
        while (!stoppingToken.IsCancellationRequested
               && await timer.WaitForNextTickAsync(stoppingToken));
    }

    /// <summary>One claim-publish-mark pass. Public so a test can drive exactly one pass rather than racing a poll interval.</summary>
    public async Task<int> RunOnceAsync(ServiceBusSender sender, CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<CurationDbContext>();

        var claimed = await ClaimBatchAsync(db, cancellationToken);
        if (claimed.Count == 0)
            return 0;

        foreach (var row in claimed)
        {
            if (cancellationToken.IsCancellationRequested)
                break; // leave it claimed; the lease expires and another tick picks it up

            await DispatchAsync(db, sender, row, cancellationToken);
        }

        return claimed.Count;
    }

    private async Task<List<OutboxMessage>> ClaimBatchAsync(CurationDbContext db, CancellationToken cancellationToken)
    {
        var now = DateTime.UtcNow;
        var leaseUntil = now.Add(LeaseDuration);

        var candidates = await db.OutboxMessages
            .AsNoTracking()
            .Where(m => m.Status == OutboxStatus.Pending && (m.LockedUntilUtc == null || m.LockedUntilUtc < now))
            .OrderBy(m => m.Id)
            .Take(BatchSize)
            .ToListAsync(cancellationToken);

        var claimed = new List<OutboxMessage>(candidates.Count);

        foreach (var candidate in candidates)
        {
            // The conditional UPDATE is the guarantee; the read above is only
            // an optimisation. Two relays can both read the same candidate;
            // exactly one UPDATE reports a row changed.
            var affected = await db.OutboxMessages
                .Where(m => m.Id == candidate.Id
                            && m.Status == OutboxStatus.Pending
                            && (m.LockedUntilUtc == null || m.LockedUntilUtc < now))
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(m => m.LockedUntilUtc, leaseUntil)
                        .SetProperty(m => m.LockOwner, _owner)
                        .SetProperty(m => m.Attempts, m => m.Attempts + 1),
                    cancellationToken);

            if (affected == 1)
                claimed.Add(candidate);
        }

        return claimed;
    }

    private async Task DispatchAsync(
        CurationDbContext db,
        ServiceBusSender sender,
        OutboxMessage row,
        CancellationToken cancellationToken)
    {
        try
        {
            var message = new ServiceBusMessage(row.Payload)
            {
                MessageId = row.MessageId.ToString(),
                ContentType = "application/json"
            };

            // eventType is what the subscription SQL filter matches on -- the
            // body is not addressable in a Service Bus filter expression.
            message.ApplicationProperties["eventType"] = row.EventType;

            if (row.TraceParent is not null)
                message.ApplicationProperties["traceparent"] = row.TraceParent;

            await sender.SendMessageAsync(message, cancellationToken);

            await db.OutboxMessages
                .Where(m => m.Id == row.Id)
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(m => m.Status, OutboxStatus.Sent)
                        .SetProperty(m => m.SentAtUtc, DateTime.UtcNow)
                        .SetProperty(m => m.LockedUntilUtc, (DateTime?)null),
                    cancellationToken);
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Failed to publish outbox row {OutboxId} ({EventType})", row.Id, row.EventType);

            // Below the retry budget: leave Pending and unlocked so the next
            // tick (or another instance) tries again. Past it: Failed, so a
            // permanently broken row stops being reclaimed forever.
            // ClaimBatchAsync already incremented Attempts in the database; row
            // is the pre-claim snapshot, so the attempt just spent is
            // row.Attempts + 1. Comparing the stale value spent one attempt
            // more than MaxAttempts before a permanently broken row stopped
            // being reclaimed.
            var attemptsSoFar = row.Attempts + 1;
            var status = attemptsSoFar >= MaxAttempts ? OutboxStatus.Failed : OutboxStatus.Pending;

            await db.OutboxMessages
                .Where(m => m.Id == row.Id)
                .ExecuteUpdateAsync(
                    setters => setters
                        .SetProperty(m => m.Status, status)
                        .SetProperty(m => m.LastError, Truncate(exception.Message, 2000))
                        .SetProperty(m => m.LockedUntilUtc, (DateTime?)null),
                    cancellationToken);
        }
    }

    /// <summary>
    /// Fits LockOwner's 64 characters -- and truncates only when there is
    /// something to truncate.
    ///
    /// This was written as `[..64]`, which lowers to Substring(0, 64) and
    /// therefore THROWS whenever the string is shorter than 64. A Windows
    /// machine name is at most 15 characters, so the composed id is around 51
    /// and it threw every time. A hosted service whose field initializer
    /// throws fails while the host is starting, so the process never reached
    /// the point of listening -- which is why no run of the happy path was
    /// ever possible.
    /// </summary>
    private static string BuildOwnerId()
    {
        var owner = $"{Environment.MachineName}:{Environment.ProcessId}:{Guid.NewGuid():N}";
        return owner.Length <= 64 ? owner : owner[..64];
    }

    private static string Truncate(string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];
}
