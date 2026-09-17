using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Publishing.Application;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same PublishingDbContext the caller's unit of
/// work runs on -- see IEditionRepository.SaveChangesAsync for why there is
/// one SaveChanges per aggregate rather than one per repository call.
///
/// BOTH READS ARE AsNoTracking, AND EDITION IS THE ONE TYPE WHERE THAT NEEDS NO
/// JUDGEMENT. It is immutable by construction -- no setters, no mutating
/// methods, and the only way one comes into existence is
/// CollectionPublishedHandler calling AddAsync with a fresh instance. Nothing
/// in this module ever loads an Edition in order to change it, so tracking one
/// buys identity-map and change-detection work for a result that can never be
/// saved.
///
/// GetLatestBySlugAsync is also the hottest path in the capstone: every other
/// endpoint is a curator or reviewer action, and this is the only one readers
/// hit. One write, unbounded reads.
/// </summary>
public sealed class EfEditionRepository(PublishingDbContext db) : IEditionRepository
{
    public Task<Edition?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Editions
            .AsNoTracking()
            .Include(e => e.Items)
            .FirstOrDefaultAsync(e => e.Id == id, cancellationToken);

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
