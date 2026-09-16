using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using QuotesPlatform.Modules.Publishing.Application;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Publishing's own endpoints -- the Host cannot see Edition (ArchitectureTests),
/// so Publishing maps its own routes, same seam as AddPublishingModule.
///
/// Read-only: the only way an Edition comes to exist is CollectionPublishedHandler
/// reacting to the event, never a write through this API.
/// </summary>
public static class PublishingEndpoints
{
    public static IEndpointRouteBuilder MapPublishingEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/editions/{slug}", async (string slug, IEditionRepository repository, CancellationToken cancellationToken) =>
        {
            var edition = await repository.GetLatestBySlugAsync(slug, cancellationToken);
            return edition is null ? Results.NotFound() : Results.Ok(ToResponse(edition));
        });

        return app;
    }

    private static EditionResponse ToResponse(Edition edition) => new(
        edition.Id,
        edition.CollectionId,
        edition.EditionNumber,
        edition.Name,
        edition.Slug,
        edition.OwnerId,
        edition.PublishedAt,
        edition.Items.Select(i => new EditionItemResponse(i.Position, i.QuoteId, i.Author, i.Text)).ToList());
}

public sealed record EditionItemResponse(int Position, Guid QuoteId, string Author, string Text);

public sealed record EditionResponse(
    Guid Id, Guid CollectionId, int EditionNumber, string Name, string Slug, string OwnerId,
    DateTimeOffset PublishedAt, IReadOnlyList<EditionItemResponse> Items);
