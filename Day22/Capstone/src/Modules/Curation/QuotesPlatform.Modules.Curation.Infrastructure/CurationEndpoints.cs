using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
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
///
/// Every route below is a thin shell over a method the aggregate already had
/// and every rule they appear to enforce lives in Collection, not here. Day 29
/// wired up only the three the happy path walked through, which left a module
/// that could add an item but not remove one, and could publish an edition but
/// never revise it. That is the gap this closes.
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

        app.MapPatch("/api/collections/{id:guid}", (
            Guid id, RenameCollectionRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.Rename(request.Name, request.ActorId)));

        app.MapPost("/api/collections/{id:guid}/members", (
            Guid id, AddMemberRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c =>
            {
                if (!Enum.TryParse<CollectionRole>(request.Role, ignoreCase: true, out var role))
                    throw new DomainException($"'{request.Role}' is not a collection role.");

                c.AddMember(request.UserId, role, request.ActorId);
            }));

        app.MapPost("/api/collections/{id:guid}/items", (
            Guid id, AddCollectionItemRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.AddItem(
                request.QuoteId, request.Author, request.Text, request.IsPublishable,
                request.ActorId, DateTimeOffset.UtcNow)));

        app.MapDelete("/api/collections/{id:guid}/items/{quoteId:guid}", (
            Guid id, Guid quoteId, string actorId, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.RemoveItem(quoteId, actorId)));

        // A target position, not a position per item. Two clients each "setting
        // position 3" cannot leave the collection with two items at 3 and a
        // hole at 4, because the aggregate renumbers rather than accepting
        // numbers -- see Collection.Reorder.
        app.MapPost("/api/collections/{id:guid}/items/{quoteId:guid}/reorder", (
            Guid id, Guid quoteId, ReorderItemRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.Reorder(quoteId, request.Position, request.ActorId)));

        // Opens the next edition for editing. The live edition keeps serving
        // from Publishing throughout -- Publishing is not told, and has no
        // reason to be: nothing about the published edition has changed.
        app.MapPost("/api/collections/{id:guid}/revise", (
            Guid id, ReviseCollectionRequest request, ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.BeginRevision(request.ActorId)));

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

    /// <summary>
    /// Load, call one aggregate method, save. Every route that changes a
    /// collection without announcing anything is exactly this, and writing it
    /// once means none of them can quietly grow a rule of its own: a check
    /// that belongs in Collection cannot be added to an endpoint that has no
    /// body to put it in.
    ///
    /// Submit is deliberately NOT routed through here. It publishes, and the
    /// ordering of enqueue-then-save is the one thing in this file worth
    /// reading carefully rather than hiding behind a helper.
    /// </summary>
    private static async Task<IResult> MutateAsync(
        Guid id,
        ICollectionRepository repository,
        CancellationToken cancellationToken,
        Action<Collection> mutate)
    {
        var collection = await repository.GetAsync(id, cancellationToken);
        if (collection is null)
            return Results.NotFound();

        try
        {
            mutate(collection);
            await repository.SaveChangesAsync(cancellationToken);

            return Results.Ok(ToResponse(collection));
        }
        catch (DomainException exception)
        {
            return Results.BadRequest(new { error = exception.Message });
        }
    }

    private static CollectionResponse ToResponse(Collection collection) => new(
        collection.Id,
        collection.Name,
        collection.OwnerId,
        collection.State.ToString(),
        collection.EditionNumber,
        collection.Items.Select(i => new CollectionItemResponse(i.Position, i.QuoteId, i.Author, i.Text, i.IsPublishable)).ToList(),
        collection.Members.Select(m => new CollectionMemberResponse(m.UserId, m.Role.ToString())).ToList());
}

public sealed record CreateCollectionRequest(string Name, string OwnerId);

public sealed record RenameCollectionRequest(string Name, string ActorId);

public sealed record AddMemberRequest(string UserId, string Role, string ActorId);

public sealed record AddCollectionItemRequest(Guid QuoteId, string Author, string Text, bool IsPublishable, string ActorId);

public sealed record ReorderItemRequest(int Position, string ActorId);

public sealed record ReviseCollectionRequest(string ActorId);

public sealed record SubmitCollectionRequest(string ActorId);

public sealed record CollectionItemResponse(int Position, Guid QuoteId, string Author, string Text, bool IsPublishable);

public sealed record CollectionMemberResponse(string UserId, string Role);

public sealed record CollectionResponse(
    Guid Id, string Name, string OwnerId, string State, int EditionNumber,
    IReadOnlyList<CollectionItemResponse> Items, IReadOnlyList<CollectionMemberResponse> Members);
