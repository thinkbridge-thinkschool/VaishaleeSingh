using Microsoft.EntityFrameworkCore;
using QuotesApi.Data;
using QuotesApi.Models;

namespace QuotesApi.Repositories;

public class QuoteRepository : IQuoteRepository
{
    private readonly QuotesDbContext _db;
    private readonly ILogger<QuoteRepository> _logger;

    public QuoteRepository(
        QuotesDbContext db,
        ILogger<QuoteRepository> logger)
    {
        _db = db;
        _logger = logger;
    }

    public async Task<(IReadOnlyList<Quote> Items, int Total)> GetPagedAsync(
        int page,
        int size,
        string? author,
        CancellationToken cancellationToken)
    {
        // Day 21 -- TagWith emits a SQL comment ahead of the statement, and
        // DbCommandCounterInterceptor classifies commands by that tag.
        //
        // Tagging rather than matching the generated SQL is the point. An
        // interceptor looking for "COUNT(*)" and "LIMIT" would work today and
        // break silently the first time this query changes -- by reclassifying
        // these commands as "other", which makes the cached run look better
        // than it is. The tag only changes when someone means it to.
        //
        // BOTH statements carry it, because a page read costs two round trips
        // and the measurement is of database load, not of query count.
        var query = _db.Quotes.AsNoTracking();

        if (!string.IsNullOrWhiteSpace(author))
        {
            query = query.Where(q => EF.Functions.Like(q.Author, $"%{author.Trim()}%"));
        }

        query = query.TagWith(Caching.CacheKeys.QuoteListQueryTag);

        var total = await query.CountAsync(cancellationToken);

        var items = await query
            .OrderBy(q => q.Id)
            .Skip((page - 1) * size)
            .Take(size)
            .ToListAsync(cancellationToken);

        _logger.LogInformation(
            "Retrieved {Count} quotes for page {Page}",
            items.Count,
            page);

        return (items, total);
    }

    public async Task<Quote?> GetByIdAsync(
        int id,
        CancellationToken cancellationToken)
    {
        return await _db.Quotes
            .AsNoTracking()
            .FirstOrDefaultAsync(q => q.Id == id, cancellationToken);
    }

    public async Task<Quote> AddAsync(
        Quote quote,
        CancellationToken cancellationToken)
    {
        _db.Quotes.Add(quote);
        await _db.SaveChangesAsync(cancellationToken);

        _logger.LogInformation(
            "Created quote {QuoteId}",
            quote.Id);

        return quote;
    }

    public async Task<Quote?> UpdateAsync(
        int id,
        string author,
        string text,
        string backgroundImageUrl,
        CancellationToken cancellationToken)
    {
        var quote = await _db.Quotes
            .FirstOrDefaultAsync(q => q.Id == id, cancellationToken);

        if (quote is null)
            return null;

        quote.Author = author;
        quote.Text = text;
        quote.BackgroundImageUrl = backgroundImageUrl;

        await _db.SaveChangesAsync(cancellationToken);

        _logger.LogInformation(
            "Updated quote {QuoteId}",
            id);

        return quote;
    }

    public async Task<bool> DeleteAsync(
        int id,
        CancellationToken cancellationToken)
    {
        var quote = await _db.Quotes
            .FirstOrDefaultAsync(q => q.Id == id, cancellationToken);

        if (quote is null)
            return false;

        _db.Quotes.Remove(quote);
        await _db.SaveChangesAsync(cancellationToken);

        _logger.LogInformation(
            "Deleted quote {QuoteId}",
            id);

        return true;
    }
}