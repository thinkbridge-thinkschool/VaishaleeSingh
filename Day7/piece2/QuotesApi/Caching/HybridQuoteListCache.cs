using System.Diagnostics;
using Microsoft.Extensions.Caching.Hybrid;
using Microsoft.Extensions.Options;
using QuotesApi.Models;
using QuotesApi.Repositories;

namespace QuotesApi.Caching;

/// <summary>
/// The read-through cache over QuoteRepository.GetPagedAsync.
///
/// STAMPEDE PROTECTION IS NOT IMPLEMENTED HERE, and that is the correct amount
/// of code for it. HybridCache.GetOrCreateAsync deduplicates concurrent callers
/// for the same key: one runs the factory, the rest await its result. There is
/// no SemaphoreSlim per key, no double-checked locking, no lock dictionary to
/// leak. If a measurement ever shows fan-out, the cause will be a key that
/// varies per request -- a timestamp, a correlation id, a per-call options
/// value -- and not missing locking here.
///
/// ITS HONEST BOUNDARY: deduplication is per PROCESS. With N instances and a
/// cold key you get up to N factory invocations, not one. That is still an
/// N-fold reduction from N x concurrency, and it is the number to report rather
/// than rounding down to "one".
///
/// WHY THE FACTORY OPENS ITS OWN SCOPE:
/// the factory can be shared by every concurrent caller, so it must not capture
/// the scoped DbContext of whichever request happened to arrive first. If that
/// request is cancelled or its scope disposed while others are still awaiting,
/// a captured DbContext would fail for all of them -- an ObjectDisposedException
/// under load that never reproduces in a single-request test. Hence a singleton
/// service that resolves a fresh scope inside the factory, rather than a scoped
/// service holding the repository.
/// </summary>
public sealed class HybridQuoteListCache(
    HybridCache cache,
    IServiceScopeFactory scopeFactory,
    ICacheGeneration generation,
    CacheMetrics metrics,
    IOptions<CacheOptions> options,
    ILogger<HybridQuoteListCache> logger) : IQuoteListCache
{
    private readonly CacheOptions _options = options.Value;

    private readonly HybridCacheEntryOptions _entryOptions = new()
    {
        Expiration = options.Value.Expiration,
        LocalCacheExpiration = options.Value.LocalCacheExpiration
    };

    public async Task<QuoteListPage> GetPageAsync(
        int page,
        int size,
        string? author,
        CancellationToken cancellationToken)
    {
        metrics.RecordRequest(CacheKeys.QuoteListFamily);

        // Search results are served directly because the author is an unbounded
        // cache-key dimension. See CacheOptions.MaxCachedPage: `page` is
        // unbounded by the endpoint's validation, so caching every page a
        // caller cares to name would let them mint cache entries without
        // limit. A page past the hot range is served from the database, which
        // is the correct place for a read that is by definition not hot.
        if (!string.IsNullOrWhiteSpace(author) || page > _options.MaxCachedPage)
        {
            metrics.RecordBypass(CacheKeys.QuoteListFamily);
            return await LoadDirectAsync(page, size, author, cancellationToken);
        }

        var token = await generation.GetAsync(cancellationToken);
        var key = CacheKeys.QuoteList(token, page, size);
        metrics.RecordKey(key);

        // The state tuple is passed through rather than captured so the page
        // and size the factory loads are unambiguously the ones this call
        // asked for, even though the factory may end up serving many callers.
        return await cache.GetOrCreateAsync(
            key,
            (page, size),
            (state, ct) => LoadAsync(state, ct),
            _entryOptions,
            tags: null,
            cancellationToken);

        async ValueTask<QuoteListPage> LoadAsync((int Page, int Size) state, CancellationToken ct)
        {
            var stopwatch = Stopwatch.StartNew();

            // Reached only on a miss, which is exactly what makes this the
            // right place to count one. HybridCache does not tell the caller
            // whether a value was cached; the factory running IS the miss.
            metrics.RecordMiss(CacheKeys.QuoteListFamily);

            await using var scope = scopeFactory.CreateAsyncScope();
            var repository = scope.ServiceProvider.GetRequiredService<IQuoteRepository>();

            var (items, total) = await repository.GetPagedAsync(state.Page, state.Size, author, ct);

            var result = new QuoteListPage(
                state.Page,
                state.Size,
                total,
                items.Select(QuoteListItem.From).ToList());

            stopwatch.Stop();
            metrics.RecordFactoryDuration(CacheKeys.QuoteListFamily, stopwatch.Elapsed.TotalMilliseconds);

            logger.LogDebug(
                "Quote list cache miss for page {Page} size {Size}; loaded {Count} of {Total} in {ElapsedMilliseconds} ms",
                state.Page, state.Size, result.Items.Count, total, stopwatch.ElapsedMilliseconds);

            return result;
        }
    }

    /// <summary>
    /// Loads a page without touching the cache. Shared by the deep-page bypass
    /// and by the factory, so both produce an identical QuoteListPage -- a
    /// second projection would be a second chance to disagree with the first.
    /// </summary>
    private async Task<QuoteListPage> LoadDirectAsync(
        int page,
        int size,
        string? author,
        CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var repository = scope.ServiceProvider.GetRequiredService<IQuoteRepository>();

        var (items, total) = await repository.GetPagedAsync(page, size, author, cancellationToken);

        return new QuoteListPage(page, size, total, items.Select(QuoteListItem.From).ToList());
    }

    public async Task InvalidateAsync(CancellationToken cancellationToken)
    {
        await generation.BumpAsync(cancellationToken);
        metrics.RecordInvalidation(CacheKeys.QuoteListFamily);

        logger.LogInformation("Quote list cache invalidated: generation bumped");
    }
}
