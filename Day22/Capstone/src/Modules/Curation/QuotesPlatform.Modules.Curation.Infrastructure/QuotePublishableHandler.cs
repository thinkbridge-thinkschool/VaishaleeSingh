using System.Text.Json;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Flow 3, last hop, and the one that makes invariant 4's sibling rule
/// enforceable inside the aggregate: "a collection cannot be submitted while
/// it holds a quote that has not cleared review."
///
/// Curation mirrors the flag rather than asking Catalog for it. That is the
/// whole point -- SubmitForPublication checks IsPublishable on its own items,
/// inside its own transaction, with no synchronous call across a module
/// boundary and no chance of the answer changing between the check and the
/// commit.
///
/// Until today that flag was set by hand: Day 29's POST /api/quotes/{id}/
/// mark-publishable existed because this event had no producer. It is retired
/// in the same commit that adds this handler, because two ways to make a quote
/// publishable is one way too many and only one of them is audited.
///
/// Shares GetEditableByQuoteIdAsync with QuoteRevisedHandler, and therefore
/// shares its deliberate exception to one-aggregate-per-transaction -- see
/// ADR-0002.
/// </summary>
public sealed class QuotePublishableHandler(
    ICollectionRepository repository,
    ILogger<QuotePublishableHandler> logger) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<QuotePublishable>(payload)
            ?? throw new InvalidOperationException("QuotePublishable payload deserialized to null.");

        var collections = await repository.GetEditableByQuoteIdAsync(evt.QuoteId, cancellationToken);

        // A quote nobody has collected yet is the common case, not a failure:
        // most quotes clear review before anyone puts them in a collection.
        if (collections.Count == 0)
            return;

        foreach (var collection in collections)
            collection.MarkQuotePublishable(evt.QuoteId);

        logger.LogInformation(
            "Quote {QuoteId} is publishable; updated {Count} editable collection(s).",
            evt.QuoteId, collections.Count);
    }
}
