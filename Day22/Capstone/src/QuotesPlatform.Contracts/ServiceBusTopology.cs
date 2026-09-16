namespace QuotesPlatform.Contracts;

/// <summary>
/// The one topic every module's outbox relay publishes to, and the
/// subscriptions each consuming module reads from. Named here, not in any one
/// module, because the topology is itself part of the cross-module contract --
/// see the design's async flows and Day 29's happy path.
/// </summary>
public static class ServiceBusTopology
{
    public const string TopicName = "capstone.collection-events";

    public static class Subscriptions
    {
        /// <summary>Moderation reads CollectionSubmittedForPublication here.</summary>
        public const string ModerationReviewRequests = "moderation-review-requests";

        /// <summary>Curation reads CollectionApproved/CollectionRejected here.</summary>
        public const string CurationReviewDecisions = "curation-review-decisions";

        /// <summary>Publishing reads CollectionPublished here.</summary>
        public const string PublishingEditions = "publishing-editions";

        /// <summary>Catalog reads QuoteApproved here (flow 3).</summary>
        public const string CatalogQuoteDecisions = "catalog-quote-decisions";
    }
}
