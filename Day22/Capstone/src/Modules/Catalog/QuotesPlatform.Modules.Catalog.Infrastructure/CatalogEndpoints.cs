using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
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
/// mark-publishable stands in for the full quote-moderation flow (Catalog ->
/// Moderation -> QuotePublishable), which is explicitly deferred past today's
/// happy path -- see Day29/docs/day29-plan.md.
/// </summary>
public static class CatalogEndpoints
{
    public static IEndpointRouteBuilder MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/quotes", async (SubmitQuoteRequest request, IQuoteRepository repository, CancellationToken cancellationToken) =>
        {
            try
            {
                var quote = Quote.Submit(request.Author, request.Text, request.SubmittedByUserId, DateTimeOffset.UtcNow);
                await repository.AddAsync(quote, cancellationToken);
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

        app.MapPost("/api/quotes/{id:guid}/mark-publishable", async (Guid id, IQuoteRepository repository, CancellationToken cancellationToken) =>
        {
            var quote = await repository.GetAsync(id, cancellationToken);
            if (quote is null)
                return Results.NotFound();

            quote.MarkPublishable();
            await repository.SaveChangesAsync(cancellationToken);

            return Results.Ok(ToResponse(quote));
        });

        return app;
    }

    private static QuoteResponse ToResponse(Quote quote) => new(
        quote.Id, quote.Author, quote.Text, quote.IsPublishable, quote.SubmittedByUserId, quote.CreatedAt);
}

public sealed record SubmitQuoteRequest(string Author, string Text, string SubmittedByUserId);

public sealed record QuoteResponse(
    Guid Id, string Author, string Text, bool IsPublishable, string? SubmittedByUserId, DateTimeOffset CreatedAt);
