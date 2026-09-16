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

    private ServiceProvider? _provider;

    public IServiceProvider Services => _provider
        ?? throw new InvalidOperationException("Fixture not initialised.");

    public async Task InitializeAsync()
    {
        await _container.StartAsync();

        var services = new ServiceCollection();
        services.AddLogging();

        // The same four calls, in the same order, as Program.cs. The namespace
        // is never reached: no hosted service is started, so no ServiceBusClient
        // ever opens a connection.
        const string ns = "integration-tests.servicebus.windows.net";
        services.AddCatalogModule(_container.GetConnectionString(), ns);
        services.AddCurationModule(_container.GetConnectionString(), ns);
        services.AddPublishingModule(_container.GetConnectionString(), ns);
        services.AddModerationModule(_container.GetConnectionString(), ns);

        _provider = services.BuildServiceProvider(validateScopes: true);

        await using var scope = _provider.CreateAsyncScope();
        await scope.ServiceProvider.GetRequiredService<CatalogDbContext>().Database.MigrateAsync();
        await scope.ServiceProvider.GetRequiredService<CurationDbContext>().Database.MigrateAsync();
        await scope.ServiceProvider.GetRequiredService<ModerationDbContext>().Database.MigrateAsync();
        await scope.ServiceProvider.GetRequiredService<PublishingDbContext>().Database.MigrateAsync();
    }

    public async Task DisposeAsync()
    {
        // DisposeAsync, not Dispose: the provider holds a ServiceBusClient,
        // which is IAsyncDisposable and NOT IDisposable. Disposing it
        // synchronously throws after every assertion has already passed, which
        // reads as a broken test and is not one. The composition tests learned
        // this on Day 29; no reason to learn it twice.
        if (_provider is not null)
            await _provider.DisposeAsync();

        await _container.DisposeAsync();
    }
}

[CollectionDefinition(Name)]
public sealed class CapstoneCollection : ICollectionFixture<CapstoneFixture>
{
    public const string Name = "capstone-database";
}
