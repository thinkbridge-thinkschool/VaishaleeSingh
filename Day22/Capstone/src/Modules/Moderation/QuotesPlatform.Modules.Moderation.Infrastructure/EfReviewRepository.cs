using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Scoped, and resolved from the same ModerationDbContext the caller's unit of
/// work runs on -- see IReviewRepository.SaveChangesAsync for why there is one
/// SaveChanges per aggregate rather than one per repository call.
/// </summary>
public sealed class EfReviewRepository(ModerationDbContext db) : IReviewRepository
{
    public Task<Review?> GetAsync(Guid id, CancellationToken cancellationToken = default) =>
        db.Reviews.FindAsync([id], cancellationToken).AsTask();

    public Task<Review?> GetPendingBySubjectAsync(
        ReviewSubject subject, Guid subjectId, CancellationToken cancellationToken = default) =>
        db.Reviews
            .Where(r => r.Subject == subject && r.SubjectId == subjectId && r.Outcome == ReviewOutcome.Pending)
            .OrderByDescending(r => r.OpenedAt)
            .FirstOrDefaultAsync(cancellationToken);

    public Task<Review?> GetLatestBySubjectAsync(
        ReviewSubject subject, Guid subjectId, CancellationToken cancellationToken = default) =>
        db.Reviews
            .Where(r => r.Subject == subject && r.SubjectId == subjectId)
            .OrderByDescending(r => r.OpenedAt)
            .FirstOrDefaultAsync(cancellationToken);

    public Task AddAsync(Review aggregate, CancellationToken cancellationToken = default)
    {
        db.Reviews.Add(aggregate);
        return Task.CompletedTask;
    }

    public Task SaveChangesAsync(CancellationToken cancellationToken = default) =>
        db.SaveChangesAsync(cancellationToken);
}
