using System.Data.Common;
using FluentAssertions;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using QuotesApi.Data;
using QuotesApi.Models;
using QuotesApi.Queries;

using Xunit.Abstractions;

namespace Quotes.Tests.Unit;

/// <summary>
/// Originally the regression test for the Day 5 N+1; retargeted on Day 12 at
/// the read model that replaced the repository's read method.
///
/// The property being pinned has not changed — the number of database round
/// trips must not grow with the number of collections — but the bar is now
/// higher and can be stated exactly. The old repository read cost a *constant
/// two* round trips: one for the aggregates, one for the quotes, then a
/// reshape in memory. The read model projects in the database, so the list
/// costs exactly ONE. "Constant" was the property worth protecting after Day
/// 5; "one" is what the query side actually achieves, and asserting the weaker
/// version would let a regression back to two go unnoticed.
///
/// SQLite rather than the InMemory provider, deliberately: InMemory is not a
/// relational provider, never issues a DbCommand, and would make a command
/// interceptor silently count zero — a test that passes because it measures
/// nothing.
/// </summary>
public class CollectionListingQueryCountTests
{
    private const string OwnerId = "user-under-test";

    private readonly ITestOutputHelper _output;

    public CollectionListingQueryCountTests(ITestOutputHelper output)
    {
        _output = output;
    }

    // ---------------------------------------------------------------------
    // The list read model
    // ---------------------------------------------------------------------

    [Fact]
    public async Task List_CostsExactlyOneRoundTrip_RegardlessOfCollectionCount()
    {
        var few = await CountListRoundTripsAsync(collections: 3, quotesPerCollection: 10);
        var many = await CountListRoundTripsAsync(collections: 15, quotesPerCollection: 10);

        few.Should().Be(
            1,
            "the list read model projects in the database, so it is a single " +
            "statement -- the old repository read cost two (aggregates, then quotes)");

        many.Should().Be(
            few,
            "round trips must not grow with the number of collections -- before " +
            "the Day 5 fix this went from 4 to 16 because each collection " +
            "fetched its own quotes");
    }

    [Fact]
    public async Task List_ReturnsDenormalizedCountPerCollection()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        await using var db = CreateContext(connection, interceptor: null);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections: 4, quotesPerCollection: 6);

        var queries = new CollectionQueries(db);

        var result = await queries.ListByOwnerAsync(OwnerId);

        result.Should().HaveCount(4);

        // The count is the point: the database computed it and flattened it
        // onto the row. Nothing here had to be sent a nested array of quotes
        // in order to call .Count on it.
        result.Should().OnlyContain(row => row.QuoteCount == 6);
        result.Should().OnlyContain(row => row.LastAddedAt != null);
    }

    [Fact]
    public async Task List_EmptyCollection_ReportsZeroCountAndNullTimestamp()
    {
        // Guards a specific trap in the projection: SQL MAX over no rows is
        // NULL, so LastAddedAt must be a nullable DateTime. Without the
        // (DateTime?) cast in the Select, EF materializes NULL into a
        // non-nullable DateTime and throws. An empty collection is an ordinary
        // state -- create one, add nothing yet -- not an edge case.
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        await using var db = CreateContext(connection, interceptor: null);
        await db.Database.EnsureCreatedAsync();

        db.Collections.Add(new Collection("Empty collection", OwnerId));
        await db.SaveChangesAsync();
        db.ChangeTracker.Clear();

        var queries = new CollectionQueries(db);

        var result = await queries.ListByOwnerAsync(OwnerId);

        result.Should().HaveCount(1);
        result[0].QuoteCount.Should().Be(0);
        result[0].LastAddedAt.Should().BeNull();
    }

    [Fact]
    public async Task List_WithNoCollections_StillCostsOneRoundTrip()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        var interceptor = new CommandCountingInterceptor();
        await using var db = CreateContext(connection, interceptor);
        await db.Database.EnsureCreatedAsync();

        var queries = new CollectionQueries(db);
        interceptor.Reset();

        var result = await queries.ListByOwnerAsync(OwnerId);

        result.Should().BeEmpty();
        interceptor.Count.Should().Be(1);
    }

    // ---------------------------------------------------------------------
    // The detail read model
    // ---------------------------------------------------------------------

    [Fact]
    public async Task Detail_CostsOneRoundTrip_AndCarriesQuotesWithAddedAt()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        var interceptor = new CommandCountingInterceptor();
        await using var db = CreateContext(connection, interceptor);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections: 2, quotesPerCollection: 5);

        var firstId = await db.Collections.OrderBy(c => c.Id).Select(c => c.Id).FirstAsync();

        var queries = new CollectionQueries(db);
        interceptor.Reset();

        var detail = await queries.GetDetailAsync(firstId, OwnerId);

        interceptor.Count.Should().Be(
            1,
            "a projected nested collection is one statement, not one per parent row");

        detail.Should().NotBeNull();
        detail!.QuoteCount.Should().Be(5);
        detail.Quotes.Should().HaveCount(5);
        detail.Quotes.Should().OnlyContain(q => !string.IsNullOrWhiteSpace(q.Text));

        // AddedAt is the field the old shared read shape silently dropped. It
        // belongs to the collection-item relationship rather than to the
        // quote, which is exactly what a projection can flatten and an
        // entity-shaped response could not.
        detail.Quotes.Should().OnlyContain(q => q.AddedAt != default);
        detail.Quotes.Should().BeInAscendingOrder(q => q.AddedAt);
    }

    /// <summary>
    /// Day 27. The ownership rule lives in the QUERY, so it is tested here and
    /// not only through the endpoint.
    ///
    /// The endpoint tests in Quotes.Tests.Integration prove the HTTP behaviour;
    /// this one proves the property that makes the endpoint safe by
    /// construction -- that no caller of GetDetailAsync, present or future,
    /// can obtain another owner's collection even if they forget to check.
    /// That is the whole reason the filter was moved into the WHERE rather
    /// than written as an if-statement after the load.
    /// </summary>
    [Fact]
    public async Task Detail_ForAnotherOwner_ReturnsNull()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        await using var db = CreateContext(connection, interceptor: null);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections: 1, quotesPerCollection: 2);

        var id = await db.Collections.OrderBy(c => c.Id).Select(c => c.Id).FirstAsync();

        var queries = new CollectionQueries(db);

        var mine = await queries.GetDetailAsync(id, OwnerId);
        var theirs = await queries.GetDetailAsync(id, "somebody-else");

        mine.Should().NotBeNull("the owner must still be able to read their own collection");
        theirs.Should().BeNull("the row for another owner's collection must never leave the database");
    }

    [Fact]
    public async Task Detail_UnknownId_ReturnsNull()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        await using var db = CreateContext(connection, interceptor: null);
        await db.Database.EnsureCreatedAsync();

        var queries = new CollectionQueries(db);

        var detail = await queries.GetDetailAsync(9_999, OwnerId);

        detail.Should().BeNull("a missing id is an ordinary 404, not an exception");
    }


    // ---------------------------------------------------------------------
    // What SQL does the read model actually emit?
    //
    // These are the tests that make the read model's central claim checkable.
    // "Shaped for the screen" is only meaningful if the SELECT really does
    // omit what the screen does not show -- so assert on the generated SQL
    // rather than trusting the projection to have done the right thing.
    // ---------------------------------------------------------------------

    [Fact]
    public async Task List_Sql_IsOneStatement_AndNeverFetchesQuoteText()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        var interceptor = new CommandCountingInterceptor();
        await using var db = CreateContext(connection, interceptor);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections: 3, quotesPerCollection: 4);

        var queries = new CollectionQueries(db);
        interceptor.Reset();

        await queries.ListByOwnerAsync(OwnerId);

        interceptor.CommandTexts.Should().HaveCount(1);

        var sql = interceptor.CommandTexts[0];
        _output.WriteLine("--- LIST read model SQL ---");
        _output.WriteLine(sql);

        // The list screen shows a name and a count. It does not show quotes,
        // so the quotes table must not appear at all -- the count comes from
        // the owned CollectionItem table. The old repository read selected
        // every quote's Author AND full Text to render this same screen.
        sql.Should().NotContain(
            "Quotes",
            "the list screen renders no quotes, so the Quotes table has no business in its query");
        sql.Should().Contain("Collections");
        sql.Should().Contain("CollectionItem");
    }

    [Fact]
    public async Task Detail_Sql_IsOneStatement_AndJoinsQuotesExactlyOnce()
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();
        var interceptor = new CommandCountingInterceptor();
        await using var db = CreateContext(connection, interceptor);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections: 2, quotesPerCollection: 4);

        var firstId = await db.Collections.OrderBy(c => c.Id).Select(c => c.Id).FirstAsync();

        var queries = new CollectionQueries(db);
        interceptor.Reset();

        await queries.GetDetailAsync(firstId, OwnerId);

        interceptor.CommandTexts.Should().HaveCount(
            1,
            "a projected nested collection is a single statement -- if this " +
            "becomes 2 the projection has silently turned into a split query");

        var sql = interceptor.CommandTexts[0];
        _output.WriteLine("--- DETAIL read model SQL ---");
        _output.WriteLine(sql);

        // The detail screen DOES show quotes, so here the join is expected --
        // the point is that it happens once, in SQL, rather than once per item.
        sql.Should().Contain("Quotes");
        sql.Should().Contain("CollectionItem");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    private static async Task<int> CountListRoundTripsAsync(int collections, int quotesPerCollection)
    {
        await using var connection = new SqliteConnection("Filename=:memory:");
        await connection.OpenAsync();

        var interceptor = new CommandCountingInterceptor();
        await using var db = CreateContext(connection, interceptor);
        await db.Database.EnsureCreatedAsync();
        await SeedAsync(db, collections, quotesPerCollection);

        var queries = new CollectionQueries(db);

        // Only the read is measured -- EnsureCreated and the seed writes above
        // would otherwise dominate the count.
        interceptor.Reset();
        await queries.ListByOwnerAsync(OwnerId);

        return interceptor.Count;
    }

    private static QuotesDbContext CreateContext(
        SqliteConnection connection,
        CommandCountingInterceptor? interceptor)
    {
        var builder = new DbContextOptionsBuilder<QuotesDbContext>()
            .UseSqlite(connection);

        if (interceptor is not null)
            builder.AddInterceptors(interceptor);

        return new QuotesDbContext(builder.Options);
    }

    private static async Task SeedAsync(QuotesDbContext db, int collections, int quotesPerCollection)
    {
        var addedAt = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

        for (var c = 0; c < collections; c++)
        {
            var collection = new Collection($"Collection {c + 1}", OwnerId);

            for (var q = 0; q < quotesPerCollection; q++)
            {
                var quote = new Quote
                {
                    Author = $"Author {c}-{q}",
                    Text = $"Quote text {c}-{q}"
                };

                db.Quotes.Add(quote);
                await db.SaveChangesAsync();

                // Staggered so the detail read model's ordering by AddedAt is
                // actually exercised rather than every row sharing one instant.
                collection.AddItem(quote.Id, addedAt.AddMinutes(q));
            }

            db.Collections.Add(collection);
            await db.SaveChangesAsync();
        }

        db.ChangeTracker.Clear();
    }

    private sealed class CommandCountingInterceptor : DbCommandInterceptor
    {
        private int _count;

        public int Count => _count;

        // Day 12 -- the interceptor already saw every command, so having it keep
        // the SQL costs nothing and turns "the read model does not over-fetch"
        // from a claim in a comment into something a test can assert.
        public List<string> CommandTexts { get; } = new();

        public void Reset()
        {
            Interlocked.Exchange(ref _count, 0);
            CommandTexts.Clear();
        }

        public override InterceptionResult<DbDataReader> ReaderExecuting(
            DbCommand command,
            CommandEventData eventData,
            InterceptionResult<DbDataReader> result)
        {
            Interlocked.Increment(ref _count);
            CommandTexts.Add(command.CommandText);
            return base.ReaderExecuting(command, eventData, result);
        }

        public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
            DbCommand command,
            CommandEventData eventData,
            InterceptionResult<DbDataReader> result,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref _count);
            CommandTexts.Add(command.CommandText);
            return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
        }
    }
}
