using QuotesApi.Models;

namespace QuotesApi.Queries;

/// <summary>
/// Day 12 — the query side of CQRS-lite for collections.
///
/// This interface exists so the read path has somewhere to live that is NOT
/// ICollectionRepository. That separation is the entire deliverable, so it is
/// worth being explicit about what each side is now allowed to do:
///
///   ICollectionRepository (command side, Repositories/)
///       loads and saves the Collection AGGREGATE. Tracked, because
///       SaveChanges needs the change tracker to detect what the aggregate's
///       methods changed. Its job is to protect invariants — a collection
///       cannot hold more than 50 items, cannot hold the same quote twice,
///       cannot have a name outside 3..80 characters. Those rules live in
///       Collection itself and are only reachable by loading the real entity.
///
///   ICollectionQueries (query side, this file)
///       never loads an aggregate at all. It projects straight from the tables
///       into a read model shaped for one screen, AsNoTracking, selecting only
///       the columns that screen renders.
///
/// WHY A SEPARATE INTERFACE RATHER THAN MORE METHODS ON THE REPOSITORY
/// The repository used to carry ListByOwnerAsync alongside GetByIdAsync/Add/
/// Update/Delete, and the two kinds of method pulled it in opposite
/// directions. A repository that must serve reads gets pressure to expose
/// query-shaped things (filters, paging, projections, "just give me the count")
/// until it is a thin wrapper over DbContext; a repository that must serve
/// writes wants the opposite — a narrow surface returning whole aggregates so
/// invariants cannot be bypassed. Splitting them lets each be good at one job.
///
/// Note there is no MediatR, no ICommandHandler/IQueryHandler machinery, and
/// no event sourcing here — the exercise explicitly rules that out, and it
/// would be the wrong trade for one feature anyway. "CQRS-lite" here means
/// exactly one thing: two paths, two shapes, one database.
/// </summary>
public interface ICollectionQueries
{
    /// <summary>
    /// Rows for the "my collections" list screen. One query.
    /// </summary>
    Task<IReadOnlyList<CollectionListItem>> ListByOwnerAsync(
        string ownerId,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// One collection with its quotes, for the detail screen. One query.
    /// Returns null when no collection with that id exists <em>for this
    /// owner</em>.
    ///
    /// OWNERSHIP IS A PARAMETER, NOT THE CALLER'S RESPONSIBILITY. Day 27 found
    /// that GET /api/collections/{id} had no ownership check at all, so any
    /// authenticated user could read every other user's collections by walking
    /// integer ids. The endpoint was fixed -- and the rule was also moved
    /// HERE, because an endpoint that must remember to filter is the same
    /// arrangement that produced the bug. With ownerId in the signature this
    /// query cannot return somebody else's row, whatever a future caller
    /// forgets.
    /// </summary>
    Task<CollectionDetail?> GetDetailAsync(
        int id,
        string ownerId,
        CancellationToken cancellationToken = default);
}
