using QuotesApi.Models;

namespace QuotesApi.Caching;

/// <summary>
/// The read-through seam for the quotes list.
///
/// One method, and no Get/Set pair. That is the point: an interface exposing
/// TryGet and Set invites the check-then-populate shape that stampedes --
///
///     if (!cache.TryGetValue(key, out var page))          // 100 callers miss
///         cache.Set(key, await repository.GetPagedAsync()) // 100 DB hits
///
/// -- and no amount of care at the call site fixes it, because the race is
/// between the check and the set. A single read-through method makes that
/// shape unwritable: the caller cannot observe a miss, so it cannot race on
/// one.
///
/// Two implementations, chosen by Cache:Enabled, so the endpoint has no branch:
/// HybridQuoteListCache and PassThroughQuoteListCache. Same pattern as Day 19's
/// NoOpQuoteEventPublisher.
/// </summary>
public interface IQuoteListCache
{
    Task<QuoteListPage> GetPageAsync(
        int page,
        int size,
        string? author,
        CancellationToken cancellationToken);

    /// <summary>
    /// Called after a quote write commits. Cheap, and safe to call when
    /// caching is disabled.
    /// </summary>
    Task InvalidateAsync(CancellationToken cancellationToken);
}
