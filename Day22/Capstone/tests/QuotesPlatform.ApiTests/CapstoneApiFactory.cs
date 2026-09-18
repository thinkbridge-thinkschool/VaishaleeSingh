using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
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
    /// <summary>
    /// The scheme the test host authenticates with, replacing JwtBearer. Named
    /// rather than reusing "Bearer" so a test can never accidentally be
    /// validating a real token, or failing to.
    /// </summary>
    public const string TestScheme = "CapstoneTests";

    /// <summary>
    /// Callers put the acting user's id in this header. No header means an
    /// anonymous request, which is how Anonymous_requests_are_refused can
    /// exist at all.
    /// </summary>
    public const string ActorHeader = "X-Test-Actor";

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        // Program.cs throws if any of these is missing -- deliberate fail-fast,
        // and it means a test host has to supply them rather than the Host
        // growing a "testing" branch. The AzureAd pair are never used to
        // validate anything here (the scheme below replaces JwtBearer), but
        // Program must still refuse to start without them, and that refusal is
        // worth exercising on every test run.
        builder.UseSetting("ConnectionStrings:Default", connectionString);
        builder.UseSetting("ServiceBus:FullyQualifiedNamespace", "api-tests.servicebus.windows.net");
        builder.UseSetting("AzureAd:Authority", "https://login.microsoftonline.com/api-tests/v2.0");
        builder.UseSetting("AzureAd:Audience", "api://api-tests");

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

            // THE SECOND TRAP, AND THE RISKIEST LINE ADDED ON DAY 32.
            //
            // A test authentication scheme that always succeeds turns every
            // authorisation test green while proving nothing -- the suite keeps
            // passing and the middleware could be entirely absent. The handler
            // below therefore returns NoResult() when the actor header is
            // missing, so an anonymous request is refused exactly as it would
            // be in production, and Anonymous_requests_are_refused can fail.
            //
            // Registered AFTER Program's AddAuthentication, so these defaults
            // win: the JwtBearer scheme is still registered but nothing selects
            // it, which is what we want -- no test should depend on a real
            // signing key or a reachable authority.
            services
                .AddAuthentication(TestScheme)
                .AddScheme<AuthenticationSchemeOptions, TestAuthenticationHandler>(TestScheme, _ => { });
        });
    }

    /// <summary>
    /// A client that authenticates as <paramref name="actorId"/>. Every test
    /// that expects to get past the fallback policy uses one of these; a client
    /// from CreateClient() is deliberately anonymous.
    /// </summary>
    public HttpClient CreateClientAs(string actorId)
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Add(ActorHeader, actorId);
        return client;
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

/// <summary>
/// Turns the actor header into a principal carrying an `oid` claim -- the same
/// claim CallerIdentity reads out of a real Entra token, under the same name,
/// because Program sets MapInboundClaims = false.
///
/// It does NOT mint a real JWT and it does not need to: what these tests verify
/// is that endpoints take the actor from the PRINCIPAL rather than the body.
/// Whether a signature validates is JwtBearer's job, and a test that re-proves
/// it would be testing Microsoft's library against itself.
/// </summary>
public sealed class TestAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(CapstoneApiFactory.ActorHeader, out var actor)
            || string.IsNullOrWhiteSpace(actor))
        {
            // NoResult, not Fail and not Success-with-an-empty-principal. This
            // is the line that lets an anonymous request be refused, and it is
            // the whole reason the authorisation tests mean anything.
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var identity = new ClaimsIdentity(
            [new Claim(CallerIdentityClaims.ObjectId, actor.ToString())],
            CapstoneApiFactory.TestScheme);

        return Task.FromResult(AuthenticateResult.Success(
            new AuthenticationTicket(new ClaimsPrincipal(identity), CapstoneApiFactory.TestScheme)));
    }
}

/// <summary>
/// The claim name is duplicated here on purpose rather than referenced from
/// SharedKernel: if someone renames the constant there, this test should FAIL,
/// because a rename would break every real client too. A shared constant would
/// let the two move together and hide it.
/// </summary>
internal static class CallerIdentityClaims
{
    internal const string ObjectId = "oid";
}

[CollectionDefinition(Name)]
public sealed class CapstoneApiCollection : ICollectionFixture<CapstoneApiFixture>
{
    public const string Name = "capstone-api";
}
