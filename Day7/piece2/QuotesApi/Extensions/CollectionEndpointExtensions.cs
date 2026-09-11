using System.Security.Claims;
using QuotesApi.Models;
using QuotesApi.Queries;
using QuotesApi.Repositories;
using QuotesApi.Services;

namespace QuotesApi.Extensions;

/// <summary>
/// All HTTP endpoints for /api/collections live here.
///
/// Before this change, this whole group had NO authorization at all --
/// any anonymous request could create, read, or mutate a collection. That
/// gap is closed the same way /api/quotes was closed in
/// QuoteEndpointExtensions.cs: a baseline .RequireAuthorization() on the
/// group, plus a specific collections.* scope policy on every route --
/// see InfrastructureExtensions.cs for what each policy checks.
/// </summary>
public static class CollectionEndpointExtensions
{
    public static IEndpointRouteBuilder MapCollectionEndpoints(
        this IEndpointRouteBuilder app, string prefix = "/api")
    {
        // .RequireAuthorization() here means "must be authenticated at
        // all" -- a baseline every route needs. Each route below then adds
        // its own, more specific, scope policy on top of that baseline.
        var group = app.MapGroup($"{prefix}/collections")
            .RequireAuthorization();

        // Create a collection. Validation (name length, non-empty) lives
        // on the aggregate's constructor, not here -- a broken invariant
        // throws and the middleware turns it into a 400 ProblemDetails.
        //
        // OwnerId is taken from the CALLER's own token, not from the
        // request body. Trusting a client-supplied "ownerId" would let
        // any authenticated caller create a collection claiming to belong
        // to someone else entirely -- the same reasoning
        // QuoteEndpointExtensions already uses for CreatedByUserId.
        group.MapPost("/", async (
            CreateCollectionRequest request,
            ICollectionRepository repository,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var ownerId = user.FindFirst(ClaimTypes.NameIdentifier)?.Value
                ?? user.FindFirst("sub")?.Value
                ?? throw new InvalidOperationException(
                    "Authenticated request had no caller id claim.");

            var collection = new Collection(request.Name, ownerId);

            await repository.AddAsync(collection, cancellationToken);

            return Results.Created(
                $"/api/collections/{collection.Id}",
                collection);
        }).RequireAuthorization("can-edit-collections");

        // ---------------------------------------------------------------
        // Day 12 -- READ PATH. Both GETs take ICollectionQueries, not
        // ICollectionRepository.
        //
        // That is the visible half of the CQRS-lite split: a reader of this
        // file can tell which endpoints command and which query purely from
        // the dependency each one asks for. The write endpoints below still
        // take ICollectionRepository, because they must load the real
        // Collection aggregate to let its methods enforce the invariants.
        // ---------------------------------------------------------------

        // GET /api/collections -- rows for the "my collections" list screen:
        // name, quote count, last-changed. Deliberately NOT the quotes
        // themselves; the list screen does not render them, so fetching them
        // would be over-fetching. Needs the collections.read scope.
        group.MapGet("/", async (
            ICollectionQueries queries,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var collections = await queries.ListByOwnerAsync(CallerId(user), cancellationToken);

            return Results.Ok(collections);
        }).RequireAuthorization("can-read-collections");

        // GET /api/collections/{id} -- the detail screen: the collection plus
        // its quotes, each with when it was added to THIS collection.
        //
        // This used to return the Collection aggregate itself, which meant a
        // read was serialising a write model: private setters, an Items list
        // of bare QuoteIds the client cannot render, and no quote text at all.
        // Needs the collections.read scope.
        // OWNERSHIP, AND WHY IT WAS MISSING HERE WHILE PRESENT NEXT DOOR.
        //
        // "can-read-collections" answers "may this caller read collections",
        // which the token knows. It does NOT answer "may this caller read
        // THIS collection", which only the loaded row knows. The list
        // endpoint above scopes by owner and the whole-collection delete
        // below compares OwnerId -- this one did neither, so any
        // authenticated caller could walk /api/collections/1, /2, /3 and read
        // every user's collections. Integer ids make that a loop, not an
        // attack.
        group.MapGet("/{id:int}", async (
            int id,
            ICollectionQueries queries,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var collection = await queries.GetDetailAsync(id, CallerId(user), cancellationToken);

            // 404 HERE, WHERE THE DELETE BELOW RETURNS 403, AND THE DIFFERENCE
            // IS DELIBERATE. The delete's comment argues that ids are not
            // secrets, so a caller may know a collection exists and simply be
            // refused -- fair for an id they supplied and believe is theirs.
            // A read is the operation an attacker uses to ENUMERATE, and
            // answering 403 for "exists, not yours" versus 404 for "does not
            // exist" hands them a map of which ids are real. Same information,
            // different value to the person asking.
            return collection is null
                ? Results.NotFound()
                : Results.Ok(collection);
        }).RequireAuthorization("can-read-collections");

        // Add a quote to a collection. All mutation goes through the
        // aggregate root: collection.AddItem(...) enforces the max-50
        // and no-duplicate-QuoteId invariants and throws when they'd
        // break, rather than the endpoint touching db.Items directly.
        // Needs the collections.write scope.
        group.MapPost("/{id:int}/items", async (
            int id,
            AddCollectionItemRequest request,
            ICollectionRepository repository,
            IClock clock,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetByIdAsync(id, cancellationToken);

            if (collection is null)
                return Results.NotFound();

            // Writing into a collection the caller does not own. Worse than
            // the read above, because it changes what somebody else sees.
            if (collection.OwnerId != CallerId(user))
                return Results.Forbid();

            collection.AddItem(request.QuoteId, clock.UtcNow);

            await repository.UpdateAsync(collection, cancellationToken);

            return Results.Ok(collection);
        }).RequireAuthorization("can-edit-collections");

        // Remove a quote from a collection. collection.RemoveItem(...)
        // throws KeyNotFoundException (-> 404 ProblemDetails) if the
        // quote isn't in the collection. Needs the collections.delete
        // scope.
        group.MapDelete("/{id:int}/items/{quoteId:int}", async (
            int id,
            int quoteId,
            ICollectionRepository repository,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetByIdAsync(id, cancellationToken);

            if (collection is null)
                return Results.NotFound();

            if (collection.OwnerId != CallerId(user))
                return Results.Forbid();

            collection.RemoveItem(quoteId);

            await repository.UpdateAsync(collection, cancellationToken);

            return Results.NoContent();
        }).RequireAuthorization("can-delete-collections");

        // DELETE /api/collections/{id} -- remove the WHOLE collection, not one
        // item within it (that is DELETE /{id}/items/{quoteId} above).
        //
        // Same two-check shape as DELETE /api/quotes/{id}: "can-delete-collections"
        // is a claim-based policy that runs from the token alone, before this
        // body executes at all -- see .RequireAuthorization below. Ownership can
        // only be checked HERE, after the collection is loaded, because whether
        // this caller owns THIS collection is not something the token carries.
        //
        // Unlike Quote, Collection has no "unowned, so anyone may act on it"
        // case -- the aggregate's constructor always requires an OwnerId, so
        // this is a plain equality check rather than a resource-based
        // AuthorizationHandler like MustOwnQuoteHandler. Introducing that
        // machinery for a rule with no second branch would be indirection with
        // nothing behind it.
        group.MapDelete("/{id:int}", async (
            int id,
            ICollectionRepository repository,
            ClaimsPrincipal user,
            CancellationToken cancellationToken) =>
        {
            var collection = await repository.GetByIdAsync(id, cancellationToken);

            if (collection is null)
                return Results.NotFound();

            // 403, not 404: the caller is allowed to know a collection with this
            // id exists (ids are not secrets), they are just not allowed to
            // delete this one. QuoteEndpointExtensions' delete makes the same
            // choice for the same reason.
            if (collection.OwnerId != CallerId(user))
                return Results.Forbid();

            await repository.DeleteAsync(collection, cancellationToken);

            return Results.NoContent();
        }).RequireAuthorization("can-delete-collections");

        return app;
    }

    /// <summary>
    /// The caller's user id, from whichever claim carries it.
    ///
    /// ONE HELPER RATHER THAN FIVE COPIES, and the reason is the bug this
    /// file was just fixed for. The claim lookup was written inline in the
    /// two endpoints whose author was thinking about ownership, and simply
    /// absent from the three who were not -- so any authenticated caller
    /// could read, add to and delete from every other user's collections.
    /// A rule that must hold on five endpoints and is spelled out on two is
    /// not a rule; it is a habit.
    ///
    /// Throws rather than returning null: every route here sits behind
    /// .RequireAuthorization(), so a request with no caller id claim is a
    /// broken authentication pipeline and not a case to handle politely. A
    /// null here would compare unequal to every OwnerId and quietly deny
    /// everything, which looks like a permissions bug and hides a real one.
    /// </summary>
    private static string CallerId(ClaimsPrincipal user) =>
        user.FindFirst(ClaimTypes.NameIdentifier)?.Value
        ?? user.FindFirst("sub")?.Value
        ?? throw new InvalidOperationException(
            "Authenticated request had no caller id claim.");
}

/// <summary>
/// Shape of the JSON body for POST /api/collections. Note there is no
/// OwnerId here anymore -- it used to be taken from this request body,
/// which meant any caller could claim to own a collection as anyone.
/// OwnerId is now always derived from the caller's authenticated identity
/// instead (see the endpoint above).
/// </summary>
public record CreateCollectionRequest(string Name);

public record AddCollectionItemRequest(int QuoteId);
