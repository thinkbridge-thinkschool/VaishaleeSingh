using QuotesPlatform.Modules.Curation.Domain;

namespace QuotesPlatform.Modules.Curation.Application;

/// <summary>
/// The module's own port, defined by the layer that uses it and implemented in
/// Infrastructure. It stays inside this module -- unlike
/// IIntegrationEventPublisher, which is a cross-module contract.
///
/// It returns and accepts the AGGREGATE, not a queryable. Handing out
/// IQueryable&lt;Collection&gt; would let a caller compose a query that loads half an
/// aggregate, and an aggregate loaded in pieces cannot enforce its invariants.
/// </summary>
public interface ICollectionRepository
{
    Task<Collection?> GetAsync(Guid id, CancellationToken cancellationToken = default);

    /// <summary>
    /// Every collection holding this quote that is still editable -- what a
    /// QuoteRevised correction has to reach (design flow 2).
    ///
    /// It returns whole aggregates rather than a queryable, for the reason
    /// above, and it filters on state HERE rather than letting the caller do
    /// it because "editable" is the same rule Collection.ApplyQuoteRevision
    /// applies internally. Having it in two places is the risk; having the
    /// query load published collections only for the aggregate to silently
    /// ignore them is the waste. This loads the ones that can change.
    ///
    /// A LIST IS THE POINT OF TENSION, and it is worth naming rather than
    /// hiding. SaveChangesAsync below says one aggregate per transaction, and
    /// a correction touching six collections commits six aggregates at once.
    /// See QuoteRevisedHandler for why that is a deliberate exception and not
    /// a quiet breach.
    /// </summary>
    Task<IReadOnlyList<Collection>> GetEditableByQuoteIdAsync(Guid quoteId, CancellationToken cancellationToken = default);

    Task AddAsync(Collection aggregate, CancellationToken cancellationToken = default);

    /// <summary>
    /// One aggregate per transaction. There is no SaveAll: a use case that
    /// needs two aggregates committed together is a use case whose boundaries
    /// are wrong, or one that needs an integration event.
    /// </summary>
    Task SaveChangesAsync(CancellationToken cancellationToken = default);
}
