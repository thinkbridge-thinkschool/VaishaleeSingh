using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Opens a Review for a collection Curation just submitted. Deliberately no
/// SaveChangesAsync here -- ModerationServiceBusConsumerHost commits this add
/// and its own ProcessedMessages row in one SaveChanges, so the review and the
/// record that it was handled land together or not at all.
/// </summary>
public sealed class CollectionSubmittedForPublicationHandler(IReviewRepository repository) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<CollectionSubmittedForPublication>(payload)
            ?? throw new InvalidOperationException("CollectionSubmittedForPublication payload deserialized to null.");

        var review = Review.Open(ReviewSubject.Collection, evt.CollectionId, DateTimeOffset.UtcNow);
        await repository.AddAsync(review, cancellationToken);
    }
}
