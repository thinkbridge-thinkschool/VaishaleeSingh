using System.Security.Claims;
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
        // SUBJECT IS A PARAMETER, not a constant. It was hardcoded to Collection
        // until flow 3 existed, which was correct for exactly as long as
        // collection reviews were the only kind -- the same assumption, in the
        // same module, that made the approve endpoint publish the wrong event.
        // A quote review could not be found through this route at all: it
        // returned 404 for a review that was open and pending.
        //
        // Defaulted rather than required, so Day 29's happy-path script and any
        // existing caller keep working unchanged.
        app.MapGet("/api/reviews/by-subject/{subjectId:guid}", async (
            Guid subjectId, IReviewRepository repository, CancellationToken cancellationToken,
            string? subject = null) =>
        {
            if (!TryParseSubject(subject, out var reviewSubject))
                return Results.BadRequest(new { error = $"'{subject}' is not a review subject." });

            var review = await repository.GetPendingBySubjectAsync(reviewSubject, subjectId, cancellationToken);
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
            Guid subjectId, IReviewRepository repository, CancellationToken cancellationToken,
            string? subject = null) =>
        {
            if (!TryParseSubject(subject, out var reviewSubject))
                return Results.BadRequest(new { error = $"'{subject}' is not a review subject." });

            var review = await repository.GetLatestBySubjectAsync(reviewSubject, subjectId, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        app.MapGet("/api/reviews/{id:guid}", async (Guid id, IReviewRepository repository, CancellationToken cancellationToken) =>
        {
            var review = await repository.GetAsync(id, cancellationToken);
            return review is null ? Results.NotFound() : Results.Ok(ToResponse(review));
        });

        // DAY 32: THE REVIEWER COMES FROM THE TOKEN. This is the single most
        // important line changed today. Review exists to answer "who decided
        // this" -- its own doc comment says collapsing it into Collection would
        // make "who rejected edition 3" unanswerable -- and until now it
        // recorded whatever string the caller typed into ReviewerId. An audit
        // trail writable by the person it incriminates is worse than no audit
        // trail, because it gets believed.
        app.MapPost("/api/reviews/{id:guid}/approve", (
            Guid id, ClaimsPrincipal user, IReviewRepository repository,
            IModerationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
            DecideAsync(
                id, repository, publisher, cancellationToken,
                review => review.Approve(user.ActorId(), DateTimeOffset.UtcNow)));

        app.MapPost("/api/reviews/{id:guid}/reject", (
            Guid id, RejectReviewRequest request, ClaimsPrincipal user, IReviewRepository repository,
            IModerationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
            DecideAsync(
                id, repository, publisher, cancellationToken,
                review => review.Reject(user.ActorId(), request.Reason, DateTimeOffset.UtcNow)));

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

    /// <summary>
    /// Absent means Collection, which keeps every caller written before quote
    /// reviews existed working unchanged. An unrecognised value is a 400 rather
    /// than a silent fallback to Collection -- a typo that quietly searches the
    /// wrong subject returns 404 for a review that exists, which is the most
    /// confusing answer available.
    /// </summary>
    private static bool TryParseSubject(string? subject, out ReviewSubject parsed)
    {
        if (string.IsNullOrWhiteSpace(subject))
        {
            parsed = ReviewSubject.Collection;
            return true;
        }

        return Enum.TryParse(subject, ignoreCase: true, out parsed);
    }

    private static ReviewResponse ToResponse(Review review) => new(
        review.Id, review.Subject.ToString(), review.SubjectId, review.Outcome.ToString(),
        review.ReviewerId, review.Reason, review.OpenedAt, review.DecidedAt);
}

// ApproveReviewRequest is GONE. Its only field was ReviewerId, which now comes
// from the token, so the approve endpoint takes no body at all. An empty record
// kept "for symmetry" with reject would be a shape inviting someone to put an
// identity back into it.

/// <summary>
/// Reason is not optional, and Review.Reject rejects a blank one -- a
/// rejection a curator cannot act on wastes the whole review round trip.
///
/// ReviewerId is no longer here: who rejected is the token's to say, not the
/// request's. Reason is genuinely the caller's and stays.
/// </summary>
public sealed record RejectReviewRequest(string Reason);

public sealed record ReviewResponse(
    Guid Id, string Subject, Guid SubjectId, string Outcome,
    string? ReviewerId, string? Reason, DateTimeOffset OpenedAt, DateTimeOffset? DecidedAt);
