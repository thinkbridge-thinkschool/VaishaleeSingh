using Microsoft.EntityFrameworkCore;
using QuotesApi.Data;
using QuotesApi.Models;

namespace QuotesApi.Queries;

/// <summary>
/// Day 12 — the read path for collections. See ICollectionQueries for why this
/// is a separate type from ICollectionRepository.
///
/// Every method here follows the same three rules, and they are the rules that
/// make this a read model rather than "the repository with a different name":
///
///   1. AsNoTracking, always. Nothing returned from here is ever saved, so a
///      change-tracker entry for it would be pure cost — measured on Day 10 as
///      roughly 3x the time and 2.3x the allocations on a 10,000-row read.
///   2. Project in the database, never in memory. The Select is part of the
///      query, so EF builds its SELECT list from the read model and the
///      columns the screen does not show are never fetched (Day 10, task 2).
///   3. One query per screen. Not one per collection, and not "load the
///      aggregates then reshape" — which is what the old
///      CollectionRepository.ListByOwnerAsync did in two round trips.
///
/// It takes QuotesDbContext directly rather than going through a repository.
/// That is intentional: a read model's whole value is being able to shape a
/// query freely, and putting a repository in front of it would either restrict
/// the shapes available or force the repository to grow a method per screen.
/// The DbContext is already the unit of work; for reads there is nothing to
/// abstract.
/// </summary>
public sealed class CollectionQueries : ICollectionQueries
{
    private readonly QuotesDbContext _db;

    public CollectionQueries(QuotesDbContext db)
    {
        _db = db;
    }

    public async Task<IReadOnlyList<CollectionListItem>> ListByOwnerAsync(
        string ownerId,
        CancellationToken cancellationToken = default)
    {
        // The list screen renders: name, how many quotes, when it last changed.
        // So that is exactly what the SELECT asks for. Count and Max become
        // correlated aggregates over the owned CollectionItem table -- computed
        // by the database, returned as scalars on the row.
        //
        // Compare with what this replaced: the old code loaded every Collection
        // aggregate for the owner (with all of its items), gathered every quote
        // id across all of them, ran a second query for those quotes' Author
        // AND full Text, then reshaped in memory. For a list screen that shows
        // neither the authors nor the text. Two round trips and up to 750 quote
        // bodies to render 15 rows.
        return await _db.Collections
            .AsNoTracking()
            .Where(c => c.OwnerId == ownerId)
            .OrderBy(c => c.Name)
            .Select(c => new CollectionListItem(
                c.Id,
                c.Name,
                c.Items.Count,
                // Nullable cast matters: Max over an empty collection is NULL in
                // SQL, and without the cast EF materializes it into a non-
                // nullable DateTime and throws. An empty collection is a normal
                // state here (create one, add nothing yet), not an edge case.
                c.Items.Max(i => (DateTime?)i.AddedAt)))
            .ToListAsync(cancellationToken);
    }

    public async Task<CollectionDetail?> GetDetailAsync(
        int id,
        string ownerId,
        CancellationToken cancellationToken = default)
    {
        // One query, projecting a nested collection. The join from
        // CollectionItem to Quote has to be written by hand because
        // CollectionItem holds a bare QuoteId, not a navigation property --
        // deliberately, since Day 7's aggregate design keeps Collection from
        // owning Quote. A projection can join across that boundary without
        // either entity gaining a reference to the other, which is precisely
        // the freedom the read side is supposed to have.
        //
        // The nested .ToList() inside the Select is what keeps this to one
        // round trip: EF Core translates a projected collection into a single
        // statement (a join, or a split query it manages itself) rather than a
        // query per parent row.
        return await _db.Collections
            .AsNoTracking()
            // Owner in the WHERE, not in a check afterwards. The row for
            // somebody else's collection never leaves the database, so there
            // is no moment at which the wrong data exists in memory waiting
            // for an if-statement to catch it.
            .Where(c => c.Id == id && c.OwnerId == ownerId)
            .Select(c => new CollectionDetail(
                c.Id,
                c.Name,
                c.Items.Count,
                (from item in c.Items
                 join quote in _db.Quotes on item.QuoteId equals quote.Id
                 orderby item.AddedAt
                 select new CollectionQuote(
                     quote.Id,
                     quote.Author,
                     quote.Text,
                     item.AddedAt))
                .ToList()))
            // FirstOrDefault, not Single: an id that does not exist is an
            // ordinary 404, not an exception. Projecting BEFORE this call is
            // what stops the aggregate from being materialized just to be
            // thrown away when the id is missing.
            .FirstOrDefaultAsync(cancellationToken);
    }
}
