namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// One handler per integration event type this module's subscription can
/// receive, keyed by EventType (the CLR type name the publisher stamped on
/// the message -- see EfOutboxIntegrationEventPublisher).
///
/// No handler is registered against this yet (Day 29 commit 7 builds the
/// pipe, not the business logic); CurationServiceBusConsumerHost completes
/// the message as a logged no-op until commit 11 registers one.
/// </summary>
public interface IIntegrationEventHandler
{
    Task HandleAsync(string payload, CancellationToken cancellationToken);
}
