using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;
using Testcontainers.MsSql;

namespace QuotesPlatform.ApiTests;

/// <summary>
/// One real SQL Server for the run; each test gets its own database and its own
/// Host, started in-process by WebApplicationFactory.
///
/// THESE ARE THE FIRST TESTS IN THE SOLUTION THAT SEND AN HTTP REQUEST.
/// The Day 30 integration tests resolve handlers from the container and invoke
/// them directly, which proves the handlers work and proves nothing about
/// routing, model binding, status codes, or the DomainException-to-400 mapping
/// every endpoint depends on. A handler that works behind an endpoint that
/// returns 500 is still a broken feature.
/// </summary>
public sealed class CapstoneApiFixture : IAsyncLifetime
{
    // Built through DockerRequired rather than directly: Build() is where
    // Testcontainers pings Docker, so with the daemon stopped this line is what
    // throws, once per test, with a forty-frame stack trace. See DockerRequired.
    private MsSqlContainer _container = null!;

    public async Task InitializeAsync()
    {
        _container = DockerRequired.Build("mcr.microsoft.com/mssql/server:2022-latest");
        await _container.StartAsync();
    }

    public Task DisposeAsync() =>
        _container is null ? Task.CompletedTask : _container.DisposeAsync().AsTask();

    /// <summary>
    /// A Host bound to a database of its own. Per test, for the reason the
    /// Day 30 fixture learned the hard way: sharing a container is the
    /// optimisation that matters, sharing a database is how a suite goes
    /// quietly flaky.
    /// </summary>
    public async Task<CapstoneApiFactory> CreateHostAsync()
    {
        var connectionString = new SqlConnectionStringBuilder(_container.GetConnectionString())
        {
            InitialCatalog = $"QuotesPlatform_Api_{Guid.NewGuid():N}"
        }.ConnectionString;

        var factory = new CapstoneApiFactory(connectionString);
        await factory.MigrateAsync();

        return factory;
    }
}

public sealed class CapstoneApiFactory(string connectionString) : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // Program.cs throws if either of these is missing -- deliberate
        // fail-fast, and it means a test host has to supply both rather than
        // the Host growing a "testing" branch.
        builder.UseSetting("ConnectionStrings:Default", connectionString);
        builder.UseSetting("ServiceBus:FullyQualifiedNamespace", "api-tests.servicebus.windows.net");

        builder.ConfigureServices(services =>
        {
            // THE TRAP, AND WHY THIS IS NOT services.RemoveAll<IHostedService>().
            //
            // Each module registers two hosted services: an outbox relay and
            // (for three of them) a consumer host. Started for real, all eight
            // construct a ServiceBusClient with DefaultAzureCredential against
            // a namespace no test can reach, so they must go.
            //
            // But ASP.NET Core's own GenericWebHostService IS an IHostedService
            // -- it is what runs the request pipeline. RemoveAll<IHostedService>()
            // takes it out too, and the result is a TestServer that starts
            // cleanly and answers nothing, which reads like a routing bug.
            //
            // So: remove only the ones from this solution's assemblies.
            var ours = services
                .Where(descriptor =>
                    descriptor.ServiceType == typeof(IHostedService)
                    && descriptor.ImplementationType?.FullName?.StartsWith(
                        "QuotesPlatform.", StringComparison.Ordinal) == true)
                .ToList();

            foreach (var descriptor in ours)
                services.Remove(descriptor);
        });
    }

    /// <summary>
    /// The Host does not migrate on startup -- by design, migrations are a
    /// deployment step -- so the test does it.
    /// </summary>
    public async Task MigrateAsync()
    {
        using var scope = Services.CreateScope();
        var services = scope.ServiceProvider;

        // The first call creates the database; the rest add their own schema.
        await services.GetRequiredService<CatalogDbContext>().Database.MigrateAsync();
        await services.GetRequiredService<CurationDbContext>().Database.MigrateAsync();
        await services.GetRequiredService<ModerationDbContext>().Database.MigrateAsync();
        await services.GetRequiredService<PublishingDbContext>().Database.MigrateAsync();
    }

    /// <summary>
    /// Asserts the workers really are gone. Without this, a future change that
    /// renames a namespace silently reinstates eight background services that
    /// would try to reach Azure from CI -- and the symptom would be a slow,
    /// intermittently failing suite rather than an obvious error.
    /// </summary>
    public IReadOnlyList<string> RunningHostedServices() =>
        Services.GetServices<IHostedService>()
            .Select(service => service.GetType().Name)
            .ToList();
}

[CollectionDefinition(Name)]
public sealed class CapstoneApiCollection : ICollectionFixture<CapstoneApiFixture>
{
    public const string Name = "capstone-api";
}
