using System.Security.Claims;
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
/// and every rule they appear to enforce lives in Collection, not here.
///
/// DAY 32: THE ACTOR NO LONGER COMES FROM THE REQUEST. Every route below used
/// to read an ActorId (and Create an OwnerId) out of the body, which meant the
/// caller supplied both sides of every ownership comparison. They now come from
/// ClaimsPrincipal.ActorId() -- the validated token -- and the fields are gone
/// from the request records entirely rather than left ignored. An ignored field
/// is a field somebody will keep sending and keep believing in.
///
/// This is a BREAKING API CHANGE and it is meant to be: a client still sending
/// actorId now has that value discarded, which is what should happen to a value
/// that was never trustworthy.
/// </summary>
public static class CurationEndpoints
{
    public static IEndpointRouteBuilder MapCurationEndpoints(this IEndpointRouteBuilder app)
    {
        // The creator IS the owner. The body used to name an owner, so a caller
        // could create a collection owned by somebody else -- and under the old
        // rules anyone could then act as that owner.
        app.MapPost("/api/collections", async (
            CreateCollectionRequest request, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
        {
            try
            {
                var collection = Collection.Create(request.Name, user.ActorId(), DateTimeOffset.UtcNow);
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
            Guid id, RenameCollectionRequest request, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.Rename(request.Name, user.ActorId())));

        app.MapPost("/api/collections/{id:guid}/members", (
            Guid id, AddMemberRequest request, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c =>
            {
                if (!Enum.TryParse<CollectionRole>(request.Role, ignoreCase: true, out var role))
                    throw new DomainException($"'{request.Role}' is not a collection role.");

                // request.UserId is the member being ADDED and stays in the
                // body: it is data about someone else, not a claim about who is
                // calling. user.ActorId() is the one doing the adding.
                c.AddMember(request.UserId, role, user.ActorId());
            }));

        app.MapPost("/api/collections/{id:guid}/items", (
            Guid id, AddCollectionItemRequest request, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.AddItem(
                request.QuoteId, request.Author, request.Text, request.IsPublishable,
                user.ActorId(), DateTimeOffset.UtcNow)));

        // This one took its actor from the QUERY STRING rather than the body,
        // and was the easiest of the twelve to miss when auditing the surface.
        // Worth recording: "the actor is in the body" was never quite true.
        app.MapDelete("/api/collections/{id:guid}/items/{quoteId:guid}", (
            Guid id, Guid quoteId, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.RemoveItem(quoteId, user.ActorId())));

        // A target position, not a position per item. Two clients each "setting
        // position 3" cannot leave the collection with two items at 3 and a
        // hole at 4, because the aggregate renumbers rather than accepting
        // numbers -- see Collection.Reorder.
        app.MapPost("/api/collections/{id:guid}/items/{quoteId:guid}/reorder", (
            Guid id, Guid quoteId, ReorderItemRequest request, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.Reorder(quoteId, request.Position, user.ActorId())));

        // Opens the next edition for editing. The live edition keeps serving
        // from Publishing throughout -- Publishing is not told, and has no
        // reason to be: nothing about the published edition has changed.
        app.MapPost("/api/collections/{id:guid}/revise", (
            Guid id, ClaimsPrincipal user,
            ICollectionRepository repository, CancellationToken cancellationToken) =>
            MutateAsync(id, repository, cancellationToken, c => c.BeginRevision(user.ActorId())));

        app.MapPost("/api/collections/{id:guid}/submit", async (
            Guid id, ClaimsPrincipal user, ICollectionRepository repository,
            ICurationIntegrationEventPublisher publisher, CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetAsync(id, cancellationToken);
            if (collection is null)
                return Results.NotFound();

            try
            {
                collection.SubmitForPublication(user.ActorId(), DateTimeOffset.UtcNow);

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

// The actor fields are GONE from these records rather than deprecated. A record
// that still accepts actorId and ignores it is one somebody keeps filling in,
// and no reader can tell from its shape whether the value is honoured.

public sealed record CreateCollectionRequest(string Name);

public sealed record RenameCollectionRequest(string Name);

/// <summary>UserId is the member being added -- not the caller.</summary>
public sealed record AddMemberRequest(string UserId, string Role);

public sealed record AddCollectionItemRequest(Guid QuoteId, string Author, string Text, bool IsPublishable);

public sealed record ReorderItemRequest(int Position);

public sealed record CollectionItemResponse(int Position, Guid QuoteId, string Author, string Text, bool IsPublishable);

public sealed record CollectionMemberResponse(string UserId, string Role);

public sealed record CollectionResponse(
    Guid Id, string Name, string OwnerId, string State, int EditionNumber,
    IReadOnlyList<CollectionItemResponse> Items, IReadOnlyList<CollectionMemberResponse> Members);
