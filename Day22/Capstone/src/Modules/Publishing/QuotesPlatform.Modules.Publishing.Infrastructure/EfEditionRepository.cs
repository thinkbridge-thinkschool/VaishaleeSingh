using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Publishing.Application;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same PublishingDbContext the caller's unit of
/// work runs on -- see IEditionRepository.SaveChangesAsync for why there is
/// one SaveChanges per aggregate rather than one per repository call.
///
/// BOTH READS ARE AsNoTracking, AND THAT IS SAFE HERE FOR A SPECIFIC REASON
/// rather than because no-tracking reads are generally faster.
///
/// An Edition is write-once. The only way one comes into existence is
/// CollectionPublishedHandler reacting to CollectionPublished and calling
/// AddAsync; PublishingEndpoints exposes a single GET and no write route, and
/// nothing in this module loads an Edition in order to change it.
///
/// That matters because AsNoTracking on a read whose result IS later mutated
/// fails silently: SaveChangesAsync finds nothing to update and returns 0, the
/// call succeeds, and the write is simply lost. It is correct only while the
/// aggregate stays write-once -- if an Edition ever grows an update path, this
/// is the first line that has to be revisited.
/// </summary>
public sealed class EfEditionRepository(PublishingDbContext db) : IEditionRepository
{
    public Task<Edition?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Editions
            .AsNoTracking()
            .Include(e => e.Items)
            .FirstOrDefaultAsync(e => e.Id == id, cancellationToken);

    /// <summary>
    /// The hottest path in the solution: every GET /api/editions/{slug} lands
    /// here. Twenty items per edition means twenty-one entities the change
    /// tracker would otherwise snapshot and hold for the life of the request,
    /// for a response that is serialised and immediately discarded.
    /// </summary>
    public Task<Edition?> GetLatestBySlugAsync(string slug, CancellationToken cancellationToken = default) =>
        db.Editions
            .AsNoTracking()
            .Include(e => e.Items)
            .Where(e => e.Slug == slug)
            .OrderByDescending(e => e.EditionNumber)
            .FirstOrDefaultAsync(cancellationToken);

    public Task AddAsync(Edition aggregate, CancellationToken cancellationToken = default)
    {
        db.Editions.Add(aggregate);
        return Task.CompletedTask;
    }

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        db.SaveChangesAsync(cancellationToken);
}
