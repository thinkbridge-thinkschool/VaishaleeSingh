using System.Text.Json;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Flow 2: a correction in Catalog reaches drafts and stops at published
/// editions.
///
/// The stopping is the interesting half and it is NOT enforced here.
/// Collection.ApplyQuoteRevision returns quietly for anything published, and
/// GetEditableByQuoteIdAsync does not load those collections in the first
/// place -- two independent guards, because "a published edition never
/// changes" is the promise Publishing's whole existence rests on. If the
/// query is ever widened, the aggregate still refuses.
///
/// THIS COMMITS MORE THAN ONE AGGREGATE, which is a deliberate exception to
/// the rule on ICollectionRepository.SaveChangesAsync, and the argument is
/// worth stating because the next person to read it should be able to
/// disagree with it.
///
/// The rule exists to stop a use case from coupling two aggregates'
/// invariants -- "these two must be consistent with each other" is the signal
/// that a boundary is drawn wrong. That is not what happens here. Each
/// collection's snapshot is independent of every other's; none of them can
/// leave another one invalid. What this is is a broadcast applied N times, and
/// splitting it into N transactions is not available anyway: the consumer host
/// commits the handler's work together with its own ProcessedMessages row, and
/// a handler saving early would let a crash between the two leave a
/// correction applied with no record that the message was handled.
///
/// So the choice is one transaction over N independent aggregates, or a
/// broken idempotency guarantee. It should be an ADR rather than a comment,
/// and it is a comment today because the ADR is not written yet.
/// </summary>
public sealed class QuoteRevisedHandler(
    ICollectionRepository repository,
    ILogger<QuoteRevisedHandler> logger) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<QuoteRevised>(payload)
            ?? throw new InvalidOperationException("QuoteRevised payload deserialized to null.");

        var collections = await repository.GetEditableByQuoteIdAsync(evt.QuoteId, cancellationToken);

        // No collection holding this quote is a normal outcome, not a failure:
        // the event is a broadcast and most quotes are in nothing editable.
        // Throwing here would dead-letter a message that was handled correctly.
        if (collections.Count == 0)
            return;

        foreach (var collection in collections)
            collection.ApplyQuoteRevision(evt.QuoteId, evt.Author, evt.Text);

        logger.LogInformation(
            "Quote {QuoteId} revised; refreshed the snapshot in {Count} editable collection(s).",
            evt.QuoteId, collections.Count);
    }
}
