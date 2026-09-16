using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// Curation's own endpoints -- the Host cannot see Collection (ArchitectureTests),
/// so Curation maps its own routes, same seam as AddCurationModule.
///
/// AddItem takes the quote's author/text/isPublishable directly in the
/// request rather than Curation calling Catalog to fetch them: modules never
/// call each other synchronously, so the caller supplies the snapshot (having
/// read it from GET /api/quotes/{id} first) -- see Collection.AddItem's own
/// signature, which already takes a snapshot rather than a lookup.
/// </summary>
public static class CurationEndpoints
{
    public static IEndpointRouteBuilder MapCurationEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/collections", async (CreateCollectionRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
        {
            try
            {
                var collection = Collection.Create(request.Name, request.OwnerId, DateTimeOffset.UtcNow);
                await repository.AddAsync(collection, cancellationToken);
                await repository.SaveChangesAsync(cancellationToken);

                return Results.Created($"/api/collections/{collection.Id}", ToResponse(collection));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        app.MapGet("/api/collections/{id:guid}", async (Guid id, ICollectionRepository repository, CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetAsync(id, cancellationToken);
            return collection is null ? Results.NotFound() : Results.Ok(ToResponse(collection));
        });

        app.MapPost("/api/collections/{id:guid}/items", async (
            Guid id, AddCollectionItemRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetAsync(id, cancellationToken);
            if (collection is null)
                return Results.NotFound();

            try
            {
                collection.AddItem(
                    request.QuoteId, request.Author, request.Text, request.IsPublishable,
                    request.ActorId, DateTimeOffset.UtcNow);
                await repository.SaveChangesAsync(cancellationToken);

                return Results.Ok(ToResponse(collection));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        app.MapPost("/api/collections/{id:guid}/submit", async (
            Guid id, SubmitCollectionRequest request, ICollectionRepository repository,
            ICurationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetAsync(id, cancellationToken);
            if (collection is null)
                return Results.NotFound();

            try
            {
                collection.SubmitForPublication(request.ActorId, DateTimeOffset.UtcNow);

                // Enqueued on the SAME DbContext SaveChangesAsync below
                // commits -- the aggregate's new state and the intent to
                // publish land in one transaction, or neither does.
                foreach (var integrationEvent in CurationIntegrationEventTranslator.Translate(collection, collection.DomainEvents))
                    await publisher.EnqueueAsync(integrationEvent, cancellationToken);

                collection.ClearDomainEvents();
                await repository.SaveChangesAsync(cancellationToken);

                return Results.Ok(ToResponse(collection));
            }
            catch (DomainException exception)
            {
                return Results.BadRequest(new { error = exception.Message });
            }
        });

        return app;
    }

    private static CollectionResponse ToResponse(Collection collection) => new(
        collection.Id,
        collection.Name,
        collection.OwnerId,
        collection.State.ToString(),
        collection.EditionNumber,
        collection.Items.Select(i => new CollectionItemResponse(i.Position, i.QuoteId, i.Author, i.Text, i.IsPublishable)).ToList());
}

public sealed record CreateCollectionRequest(string Name, string OwnerId);

public sealed record AddCollectionItemRequest(Guid QuoteId, string Author, string Text, bool IsPublishable, string ActorId);

public sealed record SubmitCollectionRequest(string ActorId);

public sealed record CollectionItemResponse(int Position, Guid QuoteId, string Author, string Text, bool IsPublishable);

public sealed record CollectionResponse(
    Guid Id, string Name, string OwnerId, string State, int EditionNumber, IReadOnlyList<CollectionItemResponse> Items);
