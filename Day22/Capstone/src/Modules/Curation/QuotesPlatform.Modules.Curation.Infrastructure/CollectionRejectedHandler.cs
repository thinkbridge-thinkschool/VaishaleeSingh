using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// The other half of flow 1. Applies Moderation's rejection: Collection.Reject
/// returns the collection to Draft if it has never published and Revising if
/// it has, so a rejected revision does not lose the fact that a live edition
/// is still serving readers.
///
/// UNLIKE CollectionApprovedHandler, THIS PUBLISHES NOTHING. Approval produces
/// a new edition, which Publishing has to hear about; rejection produces a
/// collection the curator can edit again, and no other module has any stake in
/// that. Collection.Reject raises CollectionReviewRejected internally and the
/// translator has no case for it, which is the design saying the same thing:
/// a domain event without an integration event is a fact that stays home.
///
/// The reason travels no further either. It is already durable on Moderation's
/// Review, and a curator reads it from
/// GET /api/reviews/by-subject/{id}/latest rather than from a copy living in
/// Curation -- see IReviewRepository.GetLatestBySubjectAsync for that argument.
///
/// No SaveChangesAsync here: CurationServiceBusConsumerHost commits this state
/// change and its own ProcessedMessages row together.
/// </summary>
public sealed class CollectionRejectedHandler(ICollectionRepository repository) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<CollectionRejected>(payload)
            ?? throw new InvalidOperationException("CollectionRejected payload deserialized to null.");

        var collection = await repository.GetAsync(evt.CollectionId, cancellationToken)
            ?? throw new InvalidOperationException($"Collection {evt.CollectionId} not found for CollectionRejected.");

        collection.Reject(evt.Reason, evt.OccurredAt);
        collection.ClearDomainEvents();
    }
}
