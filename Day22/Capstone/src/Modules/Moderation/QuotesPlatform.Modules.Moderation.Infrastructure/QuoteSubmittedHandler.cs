using System.Text.Json;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Flow 3, first hop. Catalog took a submission; Moderation opens a review for
/// it, exactly as it already does for a collection.
///
/// The SAME pending guard as CollectionSubmittedForPublicationHandler, and
/// here it earns its keep rather than being defence in depth. A quote has no
/// state machine stopping a second submission the way Collection.InReview
/// stops a second SubmitForPublication -- nothing in Catalog prevents the same
/// quote being announced twice -- so without this, one quote could carry two
/// pending reviews and whichever a reviewer happened to open would decide it.
///
/// Approving it publishes QuoteApproved rather than CollectionApproved,
/// because ModerationIntegrationEventTranslator reads review.Subject. That was
/// the first fix of Day 30 and this handler is the code that would have been
/// broken by its absence.
///
/// No SaveChangesAsync: the consumer host commits this add and its own
/// ProcessedMessages row together.
/// </summary>
public sealed class QuoteSubmittedHandler(
    IReviewRepository repository,
    ILogger<QuoteSubmittedHandler> logger) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<QuoteSubmitted>(payload)
            ?? throw new InvalidOperationException("QuoteSubmitted payload deserialized to null.");

        var open = await repository.GetPendingBySubjectAsync(
            ReviewSubject.Quote, evt.QuoteId, cancellationToken);

        if (open is not null)
        {
            logger.LogInformation(
                "Quote {QuoteId} already has review {ReviewId} open; not opening a second one.",
                evt.QuoteId, open.Id);
            return;
        }

        var review = Review.Open(ReviewSubject.Quote, evt.QuoteId, DateTimeOffset.UtcNow);
        await repository.AddAsync(review, cancellationToken);
    }
}
