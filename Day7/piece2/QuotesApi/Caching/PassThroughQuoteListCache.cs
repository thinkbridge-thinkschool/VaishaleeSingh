using QuotesApi.Models;
using QuotesApi.Repositories;

namespace QuotesApi.Caching;

/// <summary>
/// The implementation used when Cache:Enabled is false: reads straight through
/// to the repository and caches nothing.
///
/// It exists so the endpoint has no `if (cacheEnabled)` in it. A branch in the
/// handler would mean the cached and uncached paths could drift -- different
/// projection, different validation order -- and the "the cached response is
/// byte-identical to the uncached one" assertion would be testing two pieces of
/// code rather than one.
///
/// It still records a request and a miss, so /api/cache/stats reads honestly
/// with caching off: requests climbing, hit ratio flat at zero. A stats
/// endpoint that showed nothing at all would be indistinguishable from a
/// broken instrument, which is the ambiguity Day 20's outbox status endpoint
/// was fixed to remove.
/// </summary>
public sealed class PassThroughQuoteListCache(
    IServiceScopeFactory scopeFactory,
    CacheMetrics metrics) : IQuoteListCache
{
    public async Task<QuoteListPage> GetPageAsync(
        int page,
        int size,
        string? author,
        CancellationToken cancellationToken)
    {
        metrics.RecordRequest(CacheKeys.QuoteListFamily);
        metrics.RecordMiss(CacheKeys.QuoteListFamily);

        await using var scope = scopeFactory.CreateAsyncScope();
        var repository = scope.ServiceProvider.GetRequiredService<IQuoteRepository>();

        var (items, total) = await repository.GetPagedAsync(page, size, author, cancellationToken);

        return new QuoteListPage(page, size, total, items.Select(QuoteListItem.From).ToList());
    }

    public Task InvalidateAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
