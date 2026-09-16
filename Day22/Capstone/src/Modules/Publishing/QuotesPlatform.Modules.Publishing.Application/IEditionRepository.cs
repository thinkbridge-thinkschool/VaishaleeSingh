using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Application;

/// <summary>
/// The module's own port, defined by the layer that uses it and implemented in
/// Infrastructure. It stays inside this module -- unlike
/// IIntegrationEventPublisher, which is a cross-module contract.
///
/// It returns and accepts the AGGREGATE, not a queryable. Handing out
/// IQueryable&lt;Edition&gt; would let a caller compose a query that loads half an
/// aggregate, and an aggregate loaded in pieces cannot enforce its invariants.
/// </summary>
public interface IEditionRepository
{
    Task<Edition?> GetAsync(Guid id, CancellationToken cancellationToken = default);

    /// <summary>The live edition for a slug -- the highest EditionNumber, since slugs are stable per collection across editions.</summary>
    Task<Edition?> GetLatestBySlugAsync(string slug, CancellationToken cancellationToken = default);

    Task AddAsync(Edition aggregate, CancellationToken cancellationToken = default);

    /// <summary>
    /// One aggregate per transaction. There is no SaveAll: a use case that
    /// needs two aggregates committed together is a use case whose boundaries
    /// are wrong, or one that needs an integration event.
    /// </summary>
    Task SaveChangesAsync(CancellationToken cancellationToken = default);
}
