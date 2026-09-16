using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Application;
using QuotesPlatform.Modules.Catalog.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Catalog.Infrastructure;

/// <summary>
/// Catalog's own endpoints, mapped by Catalog rather than by the Host --
/// the Host cannot see Quote (ArchitectureTests), so it cannot map a route
/// that touches one. Program.cs calls MapCatalogEndpoints and stays exactly
/// as short as AddCatalogModule keeps it.
///
/// POST /api/quotes/{id}/mark-publishable IS GONE. It was Day 29's stand-in
/// for the quote-moderation flow, and that flow now exists: submitting a quote
/// announces QuoteSubmitted, Moderation opens a review, approving it publishes
/// QuoteApproved, and QuoteApprovedHandler marks the quote publishable.
///
/// Removed rather than left alongside, because two ways to make a quote
/// publishable is one way too many and only one of them leaves a Review
/// recording who decided and when. A stand-in that outlives the thing it stood
/// in for becomes the back door nobody audits.
/// </summary>
public static class CatalogEndpoints
{
    public static IEndpointRouteBuilder MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/quotes", async (
            SubmitQuoteRequest request, IQuoteRepository repository,
            ICatalogIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
        {
            try
            {
                var quote = Quote.Submit(request.Author, request.Text, request.SubmittedByUserId, DateTimeOffset.UtcNow);
                await repository.AddAsync(quote, cancellationToken);

                // Flow 3 starts here. Enqueued on the same DbContext the save
                // below commits, so the quote and the request for a review
                // land together or neither does -- a quote that exists with no
                // review pending is a quote nobody will ever approve.
                await publisher.EnqueueAsync(
                    new QuoteSubmitted(Guid.NewGuid(), DateTimeOffset.UtcNow, quote.Id, request.SubmittedByUserId),
                    cancellationToken);

                await repository.SaveChangesAsync(cancellationToken);

                return Results.Created($"/api/quotes/{quote.Id}", ToResponse(quote));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        app.MapGet("/api/quotes/{id:guid}", async (Guid id, IQuoteRepository repository, CancellationToken cancellationToken) =>
        {
            var quote = await repository.GetAsync(id, cancellationToken);
            return quote is null ? Results.NotFound() : Results.Ok(ToResponse(quote));
        });

        // Flow 2: the canonical text changes, and Curation refreshes the
        // snapshot in every DRAFT collection holding it while published
        // editions keep the text they were published with. That split is a
        // product decision with a defensible answer either way, argued in the
        // design; this endpoint is only where the fact originates.
        //
        // The event is built here rather than by a translator, unlike
        // Curation's. Quote raises no domain events -- there is nothing for a
        // translator to translate, and an empty one would be a layer added to
        // look consistent. Moderation's translator exists because ITS mapping
        // depends on the aggregate's state; this one does not.
        app.MapPut("/api/quotes/{id:guid}", async (
            Guid id, ReviseQuoteRequest request, IQuoteRepository repository,
            ICatalogIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
        {
            var quote = await repository.GetAsync(id, cancellationToken);
            if (quote is null)
                return Results.NotFound();

            try
            {
                quote.Revise(request.Author, request.Text);

                // Enqueued on the SAME DbContext SaveChangesAsync below
                // commits: the corrected text and the intent to announce it
                // land together, or neither does.
                await publisher.EnqueueAsync(
                    new QuoteRevised(Guid.NewGuid(), DateTimeOffset.UtcNow, quote.Id, quote.Author, quote.Text),
                    cancellationToken);

                await repository.SaveChangesAsync(cancellationToken);

                return Results.Ok(ToResponse(quote));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        return app;
    }

    private static QuoteResponse ToResponse(Quote quote) => new(
        quote.Id, quote.Author, quote.Text, quote.IsPublishable, quote.SubmittedByUserId, quote.CreatedAt);
}

public sealed record SubmitQuoteRequest(string Author, string Text, string SubmittedByUserId);

public sealed record ReviseQuoteRequest(string Author, string Text);

public sealed record QuoteResponse(
    Guid Id, string Author, string Text, bool IsPublishable, string? SubmittedByUserId, DateTimeOffset CreatedAt);
