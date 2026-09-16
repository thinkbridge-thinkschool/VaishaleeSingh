using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Application;

/// <summary>
/// The module's own port, defined by the layer that uses it and implemented in
/// Infrastructure. It stays inside this module -- unlike
/// IIntegrationEventPublisher, which is a cross-module contract.
///
/// It returns and accepts the AGGREGATE, not a queryable. Handing out
/// IQueryable&lt;Review&gt; would let a caller compose a query that loads half an
/// aggregate, and an aggregate loaded in pieces cannot enforce its invariants.
/// </summary>
public interface IReviewRepository
{
    Task<Review?> GetAsync(Guid id, CancellationToken cancellationToken = default);

    /// <summary>
    /// The pending review for a subject, if one is open -- how a reviewer (or
    /// the happy-path script) finds the review Open() created without already
    /// knowing its generated Id.
    /// </summary>
    Task<Review?> GetPendingBySubjectAsync(ReviewSubject subject, Guid subjectId, CancellationToken cancellationToken = default);

    Task AddAsync(Review aggregate, CancellationToken cancellationToken = default);

    /// <summary>
    /// One aggregate per transaction. There is no SaveAll: a use case that
    /// needs two aggregates committed together is a use case whose boundaries
    /// are wrong, or one that needs an integration event.
    /// </summary>
    Task SaveChangesAsync(CancellationToken cancellationToken = default);
}
