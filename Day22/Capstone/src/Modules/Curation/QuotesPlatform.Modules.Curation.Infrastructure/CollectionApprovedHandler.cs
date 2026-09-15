using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Applies Moderation's decision: loads the collection, calls Approve (which
/// raises CollectionEditionPublished), translates that into the fat
/// CollectionPublished integration event, and enqueues it -- all before the
/// consumer host's own SaveChangesAsync, which commits this change, the new
/// outbox row, and the host's own ProcessedMessages insert together.
/// </summary>
public sealed class CollectionApprovedHandler(
    ICollectionRepository repository, IIntegrationEventPublisher publisher) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<CollectionApproved>(payload)
            ?? throw new InvalidOperationException("CollectionApproved payload deserialized to null.");

        var collection = await repository.GetAsync(evt.CollectionId, cancellationToken)
            ?? throw new InvalidOperationException($"Collection {evt.CollectionId} not found for CollectionApproved.");

        collection.Approve(evt.OccurredAt);

        foreach (var integrationEvent in CurationIntegrationEventTranslator.Translate(collection, collection.DomainEvents))
            await publisher.EnqueueAsync(integrationEvent, cancellationToken);

        collection.ClearDomainEvents();
    }
}
