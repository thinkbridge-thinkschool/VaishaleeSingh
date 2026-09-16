using FluentAssertions;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Application.Tests;

/// <summary>
/// The mapping from a decided review to the event that announces it.
///
/// These are cheap tests for an expensive class of bug: every one of them
/// would have passed trivially against code that ignored the review's subject,
/// except <see cref="An_approved_quote_review_does_not_announce_a_collection"/>,
/// which is the one that exists because that is exactly what the code did.
/// </summary>
public sealed class ModerationIntegrationEventTranslatorTests
{
    private static readonly DateTimeOffset Opened = new(2026, 9, 30, 9, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Decided = new(2026, 9, 30, 11, 30, 0, TimeSpan.Zero);

    [Fact]
    public void An_approved_collection_review_announces_CollectionApproved()
    {
        var subjectId = Guid.NewGuid();
        var review = Review.Open(ReviewSubject.Collection, subjectId, Opened);
        review.Approve("reviewer-1", Decided);

        var result = ModerationIntegrationEventTranslator.Translate(review);

        result.Should().BeOfType<CollectionApproved>()
            .Which.Should().BeEquivalentTo(new
            {
                CollectionId = subjectId,
                ReviewerId = "reviewer-1",
                OccurredAt = Decided
            });
    }

    [Fact]
    public void A_rejected_collection_review_announces_CollectionRejected_carrying_the_reason()
    {
        var subjectId = Guid.NewGuid();
        var review = Review.Open(ReviewSubject.Collection, subjectId, Opened);
        review.Reject("reviewer-1", "Item 2 is misattributed.", Decided);

        var result = ModerationIntegrationEventTranslator.Translate(review);

        result.Should().BeOfType<CollectionRejected>()
            .Which.Should().BeEquivalentTo(new
            {
                CollectionId = subjectId,
                ReviewerId = "reviewer-1",
                Reason = "Item 2 is misattributed.",
                OccurredAt = Decided
            });
    }

    [Fact]
    public void An_approved_quote_review_announces_QuoteApproved()
    {
        var subjectId = Guid.NewGuid();
        var review = Review.Open(ReviewSubject.Quote, subjectId, Opened);
        review.Approve("reviewer-2", Decided);

        var result = ModerationIntegrationEventTranslator.Translate(review);

        result.Should().BeOfType<QuoteApproved>()
            .Which.Should().BeEquivalentTo(new
            {
                QuoteId = subjectId,
                ReviewerId = "reviewer-2",
                OccurredAt = Decided
            });
    }

    /// <summary>
    /// The regression test. Approving a quote review used to publish a
    /// CollectionApproved carrying the QuoteId: Curation's handler would look
    /// up a collection with that id, find nothing, complete the message and
    /// leave no trace. Asserting the negative as well as the positive, because
    /// the failure was a wrong event rather than a missing one.
    /// </summary>
    [Fact]
    public void An_approved_quote_review_does_not_announce_a_collection()
    {
        var review = Review.Open(ReviewSubject.Quote, Guid.NewGuid(), Opened);
        review.Approve("reviewer-2", Decided);

        ModerationIntegrationEventTranslator.Translate(review)
            .Should().NotBeOfType<CollectionApproved>();
    }

    /// <summary>
    /// Nothing outside Moderation changes when a quote is rejected: it was
    /// never publishable, so there is nothing to undo. Telling the submitter
    /// is a notification, and those are deferred by design.
    /// </summary>
    [Fact]
    public void A_rejected_quote_review_announces_nothing()
    {
        var review = Review.Open(ReviewSubject.Quote, Guid.NewGuid(), Opened);
        review.Reject("reviewer-2", "Attribution could not be verified.", Decided);

        ModerationIntegrationEventTranslator.Translate(review).Should().BeNull();
    }

    [Fact]
    public void A_pending_review_announces_nothing()
    {
        var review = Review.Open(ReviewSubject.Collection, Guid.NewGuid(), Opened);

        ModerationIntegrationEventTranslator.Translate(review).Should().BeNull();
    }

    /// <summary>
    /// The event carries the moment the decision was made, not the moment it
    /// happened to be translated. They are the same in a request and diverge
    /// the day a decision is re-announced from a relay or a replay.
    /// </summary>
    [Fact]
    public void The_event_carries_the_reviews_own_decision_time()
    {
        var review = Review.Open(ReviewSubject.Collection, Guid.NewGuid(), Opened);
        review.Approve("reviewer-1", Decided);

        ModerationIntegrationEventTranslator.Translate(review)!
            .OccurredAt.Should().Be(Decided);
    }
}
