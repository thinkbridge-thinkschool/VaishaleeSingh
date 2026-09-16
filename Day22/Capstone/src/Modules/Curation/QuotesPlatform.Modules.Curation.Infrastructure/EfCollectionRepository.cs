using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Curation.Application;
using QuotesPlatform.Modules.Curation.Domain;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same CurationDbContext the caller's unit of
/// work runs on -- see ICollectionRepository.SaveChangesAsync for why there is
/// one SaveChanges per aggregate rather than one per repository call.
/// </summary>
public sealed class EfCollectionRepository(CurationDbContext db) : ICollectionRepository
{
    public Task<Collection?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Collections
            .Include(c => c.Items)
            .Include(c => c.Members)
            .FirstOrDefaultAsync(c => c.Id == id, cancellationToken);

    public async Task<IReadOnlyList<Collection>> GetEditableByQuoteIdAsync(
        Guid quoteId, CancellationToken cancellationToken = default) =>
        await db.Collections
            .Include(c => c.Items)
            .Include(c => c.Members)
            .Where(c => (c.State == CollectionState.Draft || c.State == CollectionState.Revising)
                && c.Items.Any(i => i.QuoteId == quoteId))
            .ToListAsync(cancellationToken);

    public Task AddAsync(Collection aggregate, CancellationToken cancellationToken = default)
    {
        db.Collections.Add(aggregate);
        return Task.CompletedTask;
    }

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        db.SaveChangesAsync(cancellationToken);
}
