using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Publishing.Application;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same PublishingDbContext the caller's unit of
/// work runs on -- see IEditionRepository.SaveChangesAsync for why there is
/// one SaveChanges per aggregate rather than one per repository call.
/// </summary>
public sealed class EfEditionRepository(PublishingDbContext db) : IEditionRepository
{
    public Task<Edition?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Editions
            .Include(e => e.Items)
            .FirstOrDefaultAsync(e => e.Id == id, cancellationToken);

    public Task AddAsync(Edition aggregate, CancellationToken cancellationToken = default)
    {
        db.Editions.Add(aggregate);
        return Task.CompletedTask;
    }

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        db.SaveChangesAsync(cancellationToken);
}
