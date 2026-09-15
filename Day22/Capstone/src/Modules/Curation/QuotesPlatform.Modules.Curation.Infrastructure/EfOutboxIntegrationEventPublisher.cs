using System.Diagnostics;
using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Stages a Pending row on the SAME CurationDbContext the caller's unit of
/// work is using -- deliberately no Save here. EfCollectionRepository's own
/// SaveChangesAsync commits the domain change and this row together, which is
/// the whole guarantee ADR-0001 depends on.
/// </summary>
public sealed class EfOutboxIntegrationEventPublisher(CurationDbContext db) : IIntegrationEventPublisher
{
    public Task EnqueueAsync(IIntegrationEvent integrationEvent, CancellationToken cancellationToken = default)
    {
        db.OutboxMessages.Add(new OutboxMessage
        {
            MessageId = integrationEvent.MessageId,
            EventType = integrationEvent.GetType().Name,
            Payload = JsonSerializer.Serialize(integrationEvent, integrationEvent.GetType()),
            TraceParent = Activity.Current?.Id,
            OccurredAtUtc = integrationEvent.OccurredAt.UtcDateTime,
            Status = OutboxStatus.Pending
        });

        return Task.CompletedTask;
    }
}
