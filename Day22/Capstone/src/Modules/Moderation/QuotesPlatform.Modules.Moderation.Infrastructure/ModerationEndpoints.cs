using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Moderation's own endpoints -- the Host cannot see Review (ArchitectureTests),
/// so Moderation maps its own routes, same seam as AddModerationModule.
///
/// Neither decision endpoint builds its own integration event any more. Both
/// hand the decided Review to ModerationIntegrationEventTranslator, which is
/// exhaustive over (subject, outcome); see that type for what went wrong when
/// approve built a CollectionApproved for every review regardless of subject.
/// </summary>
public static class ModerationEndpoints
{
    public static IEndpointRouteBuilder MapModerationEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/reviews/by-subject/{subjectId:guid}", async (
            Guid subjectId, IReviewRepository repository, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetPendingBySubjectAsync(ReviewSubject.Collection, subjectId, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        // The pending lookup above cannot answer "why was my collection sent
        // back", because the review carrying the reason is decided by then.
        // Curation does not store the reason -- see
        // IReviewRepository.GetLatestBySubjectAsync for why that is deliberate
        // -- so this is where a curator reads it. Added rather than changing
        // the route above, which Day 29's happy-path script calls and reads as
        // "is a review open yet".
        app.MapGet("/api/reviews/by-subject/{subjectId:guid}/latest", async (
            Guid subjectId, IReviewRepository repository, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetLatestBySubjectAsync(ReviewSubject.Collection, subjectId, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        app.MapGet("/api/reviews/{id:guid}", async (Guid id, IReviewRepository repository, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetAsync(id, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        app.MapPost("/api/reviews/{id:guid}/approve", (
            Guid id, ApproveReviewRequest request, IReviewRepository repository,
            IModerationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
            DecideAsync(
                id, repository, publisher, cancellationToken,
                review => review.Approve(request.ReviewerId, DateTimeOffset.UtcNow)));

        app.MapPost("/api/reviews/{id:guid}/reject", (
            Guid id, RejectReviewRequest request, IReviewRepository repository,
            IModerationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
            DecideAsync(
                id, repository, publisher, cancellationToken,
                review => review.Reject(request.ReviewerId, request.Reason, DateTimeOffset.UtcNow)));

        return app;
    }

    /// <summary>
    /// Approve and reject differ by one line, and that line is the only thing
    /// that should differ. Sharing the rest is what stops one of them growing
    /// a publish step the other does not have -- which is how the subject bug
    /// survived: there was only ever one decision endpoint to be wrong.
    /// </summary>
    private static async Task<IResult> DecideAsync(
        Guid id,
        IReviewRepository repository,
        IModerationIntegrationEventPublisher publisher,
        CancellationToken cancellationToken,
        Action<Review> decide)
    {
        var review = await repository.GetAsync(id, cancellationToken);
        if (review is null)
            return Results.NotFound();

        try
        {
            decide(review);

            // Enqueued on the SAME DbContext SaveChangesAsync below commits --
            // the decision and the intent to announce it land in one
            // transaction, or neither does.
            var integrationEvent = ModerationIntegrationEventTranslator.Translate(review);
            if (integrationEvent is not null)
                await publisher.EnqueueAsync(integrationEvent, cancellationToken);

            await repository.SaveChangesAsync(cancellationToken);

            return Results.Ok(ToResponse(review));
        }
        catch (DomainException exception)
        {
            return Results.BadRequest(new { error = exception.Message });
        }
    }

    private static ReviewResponse ToResponse(Review review) => new(
        review.Id, review.Subject.ToString(), review.SubjectId, review.Outcome.ToString(),
        review.ReviewerId, review.Reason, review.OpenedAt, review.DecidedAt);
}

public sealed record ApproveReviewRequest(string ReviewerId);

/// <summary>
/// Reason is not optional, and Review.Reject rejects a blank one -- a
/// rejection a curator cannot act on wastes the whole review round trip.
/// </summary>
public sealed record RejectReviewRequest(string ReviewerId, string Reason);

public sealed record ReviewResponse(
    Guid Id, string Subject, Guid SubjectId, string Outcome,
    string? ReviewerId, string? Reason, DateTimeOffset OpenedAt, DateTimeOffset? DecidedAt);
