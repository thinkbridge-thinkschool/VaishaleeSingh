namespace QuotesPlatform.Modules.Catalog.Infrastructure;

/// <summary>
/// One handler per integration event type this module's subscription can
/// receive, keyed by EventType (the CLR type name the publisher stamped on
/// the message -- see EfOutboxIntegrationEventPublisher).
///
/// Catalog was the last module to need this. Until flow 3 it was the only
/// publish-only module: it announced QuoteSubmitted and QuoteRevised and
/// listened for nothing, because the one event it cares about (QuoteApproved)
/// did not have a producer yet.
/// </summary>
public interface IIntegrationEventHandler
{
    Task HandleAsync(string payload, CancellationToken cancellationToken);
}
