using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;
using Testcontainers.MsSql;

namespace QuotesPlatform.IntegrationTests;

/// <summary>
/// One real SQL Server for the whole run, composed exactly the way the Host
/// composes it, with all four modules' migrations applied.
///
/// REAL SQL SERVER, not SQLite and not InMemory, for the same reason Day 29
/// insisted on it: the defect that cost that day its fourth failed run was EF
/// issuing an UPDATE for a row that was never inserted, which only appears
/// against a provider that actually enforces what an UPDATE means. A test
/// double would have passed.
///
/// One container for the whole run, one DATABASE per test -- see
/// CreateDatabaseAsync for why the second half matters.
///
/// SERVICE BUS IS NOT HERE, deliberately. These tests invoke handlers directly
/// and commit the way CurationServiceBusConsumerHost does -- handler work and
/// the ProcessedMessages row in one transaction. What that leaves untested is
/// the broker itself: filters, subscriptions, delivery. Those have bitten this
/// project three times and none of them is catchable here, which is why
/// happy-path.ps1 against the live namespace stays part of the deliverable
/// rather than being replaced by this.
/// </summary>
public sealed class CapstoneFixture : IAsyncLifetime
{
    // The image goes in the constructor, not WithImage: the parameterless
    // MsSqlBuilder() is obsolete as of Testcontainers 4.15 and warns.
    //
    // "2022-latest" is a floating tag, which Day 7's fixture already flagged as
    // a real reproducibility trade-off -- Microsoft moves it to newer cumulative
    // updates, so this run and the same run in six months can pull different
    // images with nothing here changing. Left floating for the same reason as
    // there: a guessed CU tag that does not exist fails every pull outright,
    // which is worse than the risk it guards against. If this suite ever fails
    // in a way that looks environment-specific rather than code-specific, pin it.
    private readonly MsSqlContainer _container =
        new MsSqlBuilder("mcr.microsoft.com/mssql/server:2022-latest").Build();

    public Task InitializeAsync() => _container.StartAsync();

    public Task DisposeAsync() => _container.DisposeAsync().AsTask();

    /// <summary>
    /// A FRESH DATABASE PER TEST, on the one shared container.
    ///
    /// This is the half of Day 7's pattern the first version of this fixture
    /// dropped. Starting a SQL Server per test costs real seconds, so the
    /// container is shared; sharing the DATABASE as well is what makes a suite
    /// go quietly flaky later. Every test here passed against one shared
    /// database only because each generates its own GUIDs -- the first test
    /// that counts rows, or asserts "there is exactly one review", would have
    /// started failing depending on what ran before it, and it would have
    /// looked like a bug in the code under test.
    ///
    /// Creating a database and running four sets of migrations costs about a
    /// second per test. That is the right trade against a suite nobody trusts.
    /// </summary>
    public async Task<CapstoneDatabase> CreateDatabaseAsync()
    {
        var connectionString = new SqlConnectionStringBuilder(_container.GetConnectionString())
        {
            InitialCatalog = $"QuotesPlatform_{Guid.NewGuid():N}"
        }.ConnectionString;

        var services = new ServiceCollection();
        services.AddLogging();

        // The same four calls, in the same order, as Program.cs. The namespace
        // is never reached: no hosted service is started, so no ServiceBusClient
        // ever opens a connection.
        const string ns = "integration-tests.servicebus.windows.net";
        services.AddCatalogModule(connectionString, ns);
        services.AddCurationModule(connectionString, ns);
        services.AddPublishingModule(connectionString, ns);
        services.AddModerationModule(connectionString, ns);

        var provider = services.BuildServiceProvider(validateScopes: true);

        await using (var scope = provider.CreateAsyncScope())
        {
            // The first Migrate creates the database; the rest add their schema.
            await scope.ServiceProvider.GetRequiredService<CatalogDbContext>().Database.MigrateAsync();
            await scope.ServiceProvider.GetRequiredService<CurationDbContext>().Database.MigrateAsync();
            await scope.ServiceProvider.GetRequiredService<ModerationDbContext>().Database.MigrateAsync();
            await scope.ServiceProvider.GetRequiredService<PublishingDbContext>().Database.MigrateAsync();
        }

        return new CapstoneDatabase(provider);
    }
}

/// <summary>One test's database and the container composed against it.</summary>
public sealed class CapstoneDatabase(ServiceProvider provider) : IAsyncDisposable
{
    public IServiceProvider Services => provider;

    // DisposeAsync, not Dispose, and the difference is not cosmetic: the
    // provider holds a ServiceBusClient, which is IAsyncDisposable and NOT
    // IDisposable. Disposing it synchronously throws AFTER every assertion has
    // passed, which reads as a broken test and is not one. The composition
    // tests learned this on Day 29; no reason to learn it twice.
    public ValueTask DisposeAsync() => provider.DisposeAsync();
}

[CollectionDefinition(Name)]
public sealed class CapstoneCollection : ICollectionFixture<CapstoneFixture>
{
    public const string Name = "capstone-database";
}
