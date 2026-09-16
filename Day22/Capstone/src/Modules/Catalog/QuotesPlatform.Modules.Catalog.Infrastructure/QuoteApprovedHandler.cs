using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Application;

namespace QuotesPlatform.Modules.Catalog.Infrastructure;

/// <summary>
/// Flow 3, the step that makes a quote usable. Moderation approved it, so
/// Catalog marks it publishable and announces that as QuotePublishable --
/// which Curation mirrors onto its own snapshots so the rule "a collection
/// cannot be submitted while it holds an unreviewed quote" is enforced inside
/// the aggregate rather than by a synchronous call into this module.
///
/// TWO EVENTS FOR WHAT LOOKS LIKE ONE FACT, and the distinction is the
/// design's, not an accident. QuoteApproved is Moderation's decision;
/// QuotePublishable is Catalog's consequence of it. Curation consumes the
/// second and not the first, so a change to how Catalog decides publishability
/// -- an extra check, an embargo date -- does not become a change every
/// consumer of Moderation has to know about.
///
/// No SaveChangesAsync here: CatalogServiceBusConsumerHost commits this change,
/// the new outbox row, and its own ProcessedMessages row together.
/// </summary>
public sealed class QuoteApprovedHandler(
    IQuoteRepository repository, ICatalogIntegrationEventPublisher publisher) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<QuoteApproved>(payload)
            ?? throw new InvalidOperationException("QuoteApproved payload deserialized to null.");

        var quote = await repository.GetAsync(evt.QuoteId, cancellationToken)
            ?? throw new InvalidOperationException($"Quote {evt.QuoteId} not found for QuoteApproved.");

        if (quote.IsPublishable)
            return;

        quote.MarkPublishable();

        await publisher.EnqueueAsync(
            new QuotePublishable(Guid.NewGuid(), DateTimeOffset.UtcNow, quote.Id),
            cancellationToken);
    }
}
