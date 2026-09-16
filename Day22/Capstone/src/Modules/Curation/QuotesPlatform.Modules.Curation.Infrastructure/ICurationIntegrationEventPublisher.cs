using QuotesPlatform.Contracts;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Curation's own outbox port, and the reason it exists is worth stating.
///
/// IIntegrationEventPublisher is ONE interface in Contracts, and every module
/// registered its own implementation against it in the SAME container. The
/// container resolves the LAST registration, so every module received
/// whichever module Program.cs happened to register last -- writing its outbox
/// row to that module's DbContext, which the caller never saves. The row was
/// discarded silently: the endpoint still returned 200 and the event was never
/// published.
///
/// A key string would have fixed the symptom and kept the shape that caused
/// it: a copy-pasted key still compiles. This type cannot be resolved from
/// another module because another module cannot see it -- the module boundary
/// tests forbid the reference that would make it visible. The same reason
/// IIntegrationEventHandler is already declared per module rather than shared.
/// </summary>
public interface ICurationIntegrationEventPublisher : IIntegrationEventPublisher
{
}
