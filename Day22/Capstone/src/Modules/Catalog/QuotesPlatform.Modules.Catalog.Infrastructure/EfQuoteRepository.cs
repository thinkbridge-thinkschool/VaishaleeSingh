using QuotesPlatform.Modules.Catalog.Application;
using QuotesPlatform.Modules.Catalog.Domain;

namespace QuotesPlatform.Modules.Catalog.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same CatalogDbContext the caller's unit of
/// work runs on -- see IQuoteRepository.SaveChangesAsync for why there is one
/// SaveChanges per aggregate rather than one per repository call.
/// </summary>
public sealed class EfQuoteRepository(CatalogDbContext db) : IQuoteRepository
{
    public Task<Quote?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Quotes.FindAsync([id], cancellationToken).AsTask();

    public Task AddAsync(Quote aggregate, CancellationToken cancellationToken = default)
    {
        db.Quotes.Add(aggregate);
        return Task.CompletedTask;
    }

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        db.SaveChangesAsync(cancellationToken);
}
