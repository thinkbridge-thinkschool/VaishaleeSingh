using System.Text.Json;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Opens a Review for a collection Curation just submitted. Deliberately no
/// SaveChangesAsync here -- ModerationServiceBusConsumerHost commits this add
/// and its own ProcessedMessages row in one SaveChanges, so the review and the
/// record that it was handled land together or not at all.
///
/// ON THE PENDING-REVIEW GUARD BELOW, and what it is and is not for.
///
/// It is NOT a fix for an observed bug, and saying otherwise would overstate
/// it. Walking the states, a second pending review is hard to reach: a
/// collection in InReview refuses another SubmitForPublication, and a
/// resubmission only becomes possible after a decision, by which point the
/// previous review is decided rather than pending. Redelivery of the SAME
/// submission is already handled one layer up -- the consumer host records
/// MessageId in ProcessedMessages and a repeat is a no-op.
///
/// What it IS: the cheapest possible guarantee that "the pending review for
/// this collection" is a phrase with one answer. GetPendingBySubjectAsync
/// already orders by OpenedAt and takes the first, which is a query written by
/// someone who expected more than one row to be possible; with two of them,
/// which review a reviewer approves decides which round of edits gets
/// published, and it decides it invisibly. The guard makes the ambiguity
/// unrepresentable instead of merely unlikely, for four lines and one query.
/// </summary>
public sealed class CollectionSubmittedForPublicationHandler(
    IReviewRepository repository,
    ILogger<CollectionSubmittedForPublicationHandler> logger) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<CollectionSubmittedForPublication>(payload)
            ?? throw new InvalidOperationException("CollectionSubmittedForPublication payload deserialized to null.");

        var open = await repository.GetPendingBySubjectAsync(
            ReviewSubject.Collection, evt.CollectionId, cancellationToken);

        if (open is not null)
        {
            // Logged rather than thrown. Throwing would dead-letter a message
            // whose intent -- "this collection needs a review" -- is already
            // satisfied, and a dead-lettered message that describes a correct
            // state is noise an operator has to triage.
            logger.LogInformation(
                "Collection {CollectionId} already has review {ReviewId} open; not opening a second one.",
                evt.CollectionId, open.Id);
            return;
        }

        var review = Review.Open(ReviewSubject.Collection, evt.CollectionId, DateTimeOffset.UtcNow);
        await repository.AddAsync(review, cancellationToken);
    }
}
