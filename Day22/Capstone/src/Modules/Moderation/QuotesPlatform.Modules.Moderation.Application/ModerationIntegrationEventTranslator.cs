using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Application;

/// <summary>
/// Turns a decided <see cref="Review"/> into the integration event that
/// announces it -- the same seam as Curation's translator, and here for a
/// reason that took a defect to find.
///
/// Before this existed, ModerationEndpoints built a <c>CollectionApproved</c>
/// from <c>review.SubjectId</c> without ever reading <c>review.Subject</c>.
/// That was correct only for as long as collection reviews were the only kind
/// of review. The moment Catalog opens a review for a QUOTE, approving it
/// published a CollectionApproved carrying a QuoteId: Curation's handler looks
/// for a collection with that id, finds nothing, and the approval disappears
/// with no error anywhere. A wrong event is worse than no event, because the
/// message is delivered, handled and completed.
///
/// So the mapping lives in one place, it is exhaustive over the subject, and
/// it is a pure function of the aggregate -- which is what makes it testable
/// without a database, a broker or a host.
/// </summary>
public static class ModerationIntegrationEventTranslator
{
    /// <summary>
    /// The event to publish for a decided review, or <c>null</c> when the
    /// decision has no cross-module consequence.
    ///
    /// Null is a real answer, not a gap: a REJECTED QUOTE changes nothing
    /// outside Moderation. The quote stays non-publishable in Catalog because
    /// it was never marked publishable in the first place, so there is nothing
    /// for Catalog to undo and nothing for Curation to mirror. Telling the
    /// submitter is a notification, and notifications are deliberately
    /// deferred (see the design's "Deferred, deliberately"). Publishing a
    /// QuoteRejected that no module consumes would be a message written to
    /// look like a feature.
    /// </summary>
    public static IIntegrationEvent? Translate(Review review)
    {
        if (review.Outcome == ReviewOutcome.Pending)
            return null;

        var decidedAt = review.DecidedAt ?? DateTimeOffset.UtcNow;
        var reviewerId = review.ReviewerId
            ?? throw new InvalidOperationException("A decided review always has a reviewer.");

        return (review.Subject, review.Outcome) switch
        {
            (ReviewSubject.Collection, ReviewOutcome.Approved) =>
                new CollectionApproved(Guid.NewGuid(), decidedAt, review.SubjectId, reviewerId),

            (ReviewSubject.Collection, ReviewOutcome.Rejected) =>
                new CollectionRejected(
                    Guid.NewGuid(), decidedAt, review.SubjectId, reviewerId,
                    review.Reason ?? throw new InvalidOperationException(
                        "A rejected review always has a reason; Review.Reject enforces it.")),

            (ReviewSubject.Quote, ReviewOutcome.Approved) =>
                new QuoteApproved(Guid.NewGuid(), decidedAt, review.SubjectId, reviewerId),

            // See the summary: a rejected quote has no downstream consumer.
            (ReviewSubject.Quote, ReviewOutcome.Rejected) => null,

            _ => throw new InvalidOperationException(
                $"No integration event is defined for a {review.Outcome} {review.Subject} review.")
        };
    }
}
