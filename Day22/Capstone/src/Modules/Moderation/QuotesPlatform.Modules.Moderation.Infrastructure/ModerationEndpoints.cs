using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// Moderation's own endpoints -- the Host cannot see Review (ArchitectureTests),
/// so Moderation maps its own routes, same seam as AddModerationModule.
///
/// CollectionApproved is built directly here rather than through a translator
/// like Curation's: Review raises no domain events (a decision is final, not
/// announced internally), so there is nothing to translate -- the endpoint is
/// the only place that knows both "this got approved" and "publish that".
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

        app.MapGet("/api/reviews/{id:guid}", async (Guid id, IReviewRepository repository, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetAsync(id, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        app.MapPost("/api/reviews/{id:guid}/approve", async (
            Guid id, ApproveReviewRequest request, IReviewRepository repository,
            IModerationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetAsync(id, cancellationToken);
            if (review is null)
                return Results.NotFound();

            try
            {
                review.Approve(request.ReviewerId, DateTimeOffset.UtcNow);

                await publisher.EnqueueAsync(
                    new CollectionApproved(Guid.NewGuid(), DateTimeOffset.UtcNow, review.SubjectId, request.ReviewerId),
                    cancellationToken);

                await repository.SaveChangesAsync(cancellationToken);

                return Results.Ok(ToResponse(review));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        return app;
    }

    private static ReviewResponse ToResponse(Review review) => new(
        review.Id, review.Subject.ToString(), review.SubjectId, review.Outcome.ToString(),
        review.ReviewerId, review.Reason, review.OpenedAt, review.DecidedAt);
}

public sealed record ApproveReviewRequest(string ReviewerId);

public sealed record ReviewResponse(
    Guid Id, string Subject, Guid SubjectId, string Outcome,
    string? ReviewerId, string? Reason, DateTimeOffset OpenedAt, DateTimeOffset? DecidedAt);
