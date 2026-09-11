using Azure.Identity;
using Microsoft.EntityFrameworkCore;
using QuotesApi.Data;
using QuotesApi.Extensions;
using QuotesApi.Middleware;
using Serilog;

// This file is the app's entry point. It runs top-to-bottom, once, when the
// app starts. Its whole job is to wire pieces together and then start
// listening for HTTP requests -- it deliberately contains no business logic.

var builder = WebApplication.CreateBuilder(args);

// Day 27 -- a ceiling on request size, BEFORE anything parses the body.
//
// THE FIELD VALIDATION WAS ALREADY THERE, AND THAT IS THE POINT. Author is
// capped at 200 characters and Text at 1000 (QuoteEndpointExtensions), and a
// collection name must be 3..80 (the aggregate's constructor). None of that
// runs until the request has been read off the wire and deserialised -- so a
// caller could send Kestrel's default 30 MB of JSON, have the server buffer
// and parse all of it, and only then be told the text field is too long. The
// work is done before the rejection, which is exactly the shape of a cheap
// denial of service: one client, a slow loop, and a database that scales to
// zero paying for it.
//
// 64 KB, and the number is not arbitrary: the largest legitimate body this
// API accepts is one quote -- 1000 characters of text, 200 of author, a URL --
// which is under 2 KB. Sixty-four thousand leaves two orders of magnitude of
// headroom for anything a future endpoint might reasonably take, and still
// refuses a megabyte at the transport layer, where refusing is free.
//
// Configurable, because a limit that cannot be raised without a deployment is
// a limit somebody will remove entirely the first time it is inconvenient.
builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.Limits.MaxRequestBodySize =
        builder.Configuration.GetValue<long?>("Limits:MaxRequestBodyBytes") ?? 64 * 1024;

    // Headers have their own budget, and it is separate for a reason: a body
    // limit does nothing about a request that sends megabytes of headers and
    // never reaches a body at all.
    kestrel.Limits.MaxRequestHeadersTotalSize =
        builder.Configuration.GetValue<int?>("Limits:MaxRequestHeaderBytes") ?? 32 * 1024;
});

// --- Secrets ---------------------------------------------------------------
// Connection strings and keys are never committed. They come from, in order
// of preference: Key Vault when a vault is configured (deployed
// environments, authenticating with the app's managed identity), otherwise
// .NET user-secrets or environment variables locally -- both of which live
// outside the repository.
//
// Conditional on purpose: a developer with no Azure login, and CI, must
// still be able to run the app. Adding the provider unconditionally would
// make DefaultAzureCredential fail at startup for anyone not signed in.
//
// Note Key Vault secret names cannot contain ':', so the hierarchy is
// written with a double dash -- a secret named
// "ApplicationInsights--ConnectionString" is read as the configuration key
// "ApplicationInsights:ConnectionString".
var keyVaultUri = builder.Configuration["KeyVault:Uri"];
if (!string.IsNullOrWhiteSpace(keyVaultUri))
{
    builder.Configuration.AddAzureKeyVault(
        new Uri(keyVaultUri),
        new DefaultAzureCredential());
}

// Replaces the default Microsoft.Extensions.Logging console provider with
// Serilog end-to-end, reading levels/sinks from the "Serilog" config section
// (see appsettings.json) rather than "Logging" -- that section is what
// ReadFrom.Configuration actually looks for.
//
// This uses the (context, services, loggerConfig) lambda form rather than
// the more common `Log.Logger = new LoggerConfiguration()...CreateLogger();`
// static-assignment pattern on purpose: this exact Program.cs is re-run
// fresh inside every WebApplicationFactory<Program> in the integration test
// suite, often several at once. A single shared static Log.Logger getting
// reassigned/disposed across concurrently-running test hosts would be
// exactly the kind of hidden cross-test coupling worth avoiding. Scoping
// the logger pipeline to each host's own builder keeps every test's
// Serilog setup fully independent, with no global mutable state at all.
// ClearProviders() first: WebApplication.CreateBuilder registers the default
// Console/Debug/EventSource logging providers, and with writeToProviders
// below Serilog forwards every event to all of them -- so leaving them in
// place prints each line twice, once in Microsoft.Extensions.Logging format
// and again in Serilog format. (Observed exactly that before adding this.)
// Clearing them leaves the console to Serilog alone, while providers
// registered LATER -- notably the one the Azure Monitor distro installs in
// AddObservability -- are still picked up.
builder.Logging.ClearProviders();

// writeToProviders: true matters once Application Insights is in play.
// By default Serilog REPLACES the logging pipeline, so anything written
// through ILogger goes only to Serilog's own sinks and never reaches other
// registered ILoggerProviders. The Azure Monitor distro ships logs through
// exactly such a provider, so without this flag the console would show logs
// while App Insights showed traces and metrics but no logs at all -- and
// nothing would report an error, which is the worst kind of gap to have in
// telemetry.
builder.Host.UseSerilog(
    (context, services, loggerConfig) =>
        loggerConfig
            .ReadFrom.Configuration(context.Configuration)
            .Enrich.FromLogContext(),
    writeToProviders: true);

// AddProblemDetails() makes unhandled errors come back to the client as a
// standard RFC 7807 JSON shape instead of a raw stack trace.
builder.Services.AddProblemDetails();

// Everything the app needs (database, repositories, services, and
// authentication/authorization) is registered inside this one method. See
// Extensions/InfrastructureExtensions.cs for the details of each piece.
builder.Services.AddInfrastructure(builder.Configuration);

// Day 13 -- the one CORS policy this API has. Needed because Day 13 adds an
// Angular SPA on its own origin (http://localhost:4200 in development), and
// a browser will not let that page read a response from this API unless the
// API names its origin. Every client before Day 13 was a server, a CLI or a
// test, none of which the same-origin policy applies to, which is why there
// was no policy here at all until now. See Extensions/CorsExtensions.cs for
// why it names origins rather than allowing any, and why it does not allow
// credentials.
builder.Services.AddSpaCors(builder.Configuration);

// Day 27 -- rate limiting. Registered here; the middleware is turned on below,
// after authentication, and the strict policy is attached to /api/auth in
// AuthEndpointExtensions. See Extensions/RateLimitingExtensions.cs for why the
// limits are the numbers they are.
builder.Services.AddQuotesRateLimiting();

// Distributed tracing (spans for requests, EF queries, outbound HTTP, plus
// this app's own custom spans). See ObservabilityExtensions.cs -- in
// particular for why the OTLP exporter is only wired up when an endpoint is
// actually configured.
builder.Services.AddObservability(builder.Configuration);

// Liveness and readiness checks. Split deliberately -- see
// HealthCheckExtensions.cs for why a database check must not be allowed to
// fail a liveness probe.
builder.Services.AddQuotesHealthChecks();

var app = builder.Build();

// Stamps every log line written during a request with that request's
// TraceId (see CorrelationIdMiddleware). Registered FIRST, so it wraps
// ExceptionHandlingMiddleware below rather than sitting after it: the one
// log line you most need tied back to a request is the exception log for a
// failed one, and that has to carry the same TraceId as everything else
// from that request.
app.UseMiddleware<CorrelationIdMiddleware>();

// Catches any exception that escapes an endpoint and turns it into a clean
// ProblemDetails response instead of leaking a raw .NET stack trace.
app.UseMiddleware<ExceptionHandlingMiddleware>();

// Day 27 -- security headers.
//
// ABOVE UseStaticFiles, deliberately. Static files are a response like any
// other and the SPA's own HTML is the response a browser applies a CSP to --
// registering this below the static middleware would leave exactly the
// documents that need the policy without one.
app.UseMiddleware<SecurityHeadersMiddleware>();

// Backend-owned static assets (quote backgrounds) served from wwwroot.
app.UseStaticFiles();


// UseRouting EXPLICITLY, AFTER the static file middleware. Keep it here.
//
// Day 24 spent an afternoon on this. StaticFileMiddleware does not serve a
// file once routing has selected an endpoint, and WebApplication PREPENDS its
// own UseRouting when you never call one -- so with a catch-all route in the
// table, routing matched every request before static files ran and wwwroot
// stopped being served at all. Assets came back as 200 with
// Content-Type: text/html and nothing was logged anywhere.
//
// The catch-all that caused it is gone (the front end is its own container
// app now), so nothing currently depends on this line. It stays because the
// next person to add a fallback route would otherwise reintroduce the same
// failure, and because static files before routing is the order you want
// regardless.
app.UseRouting();

// Applies any pending EF Core migrations on startup, so the database schema
// is always up to date before the app starts accepting requests.
//
// One path for both providers, deliberately. Between 24 August and Day 19
// this branched on IsSqlServer() and called EnsureCreatedAsync() there,
// because the SQL Server migration set had gone stale and creating the
// schema straight from the model was the quick way past it. Three things
// that cost, none of them obvious at the time:
//
//   - EnsureCreated writes no __EFMigrationsHistory, so nothing records what
//     the deployed schema is or lets it be moved forward incrementally. The
//     only way to pick up a model change is to drop the database.
//   - It silently bypassed QuotesApi.Migrations.SqlServer entirely, so the
//     provider-specific migrations nobody was running kept drifting further
//     from the model.
//   - SqlServerMigrationTests asserts every migration is applied, and has
//     been failing since that day. Nobody saw it: CI builds Day5/piece2, so
//     the Day 7 SQL Server suite has not run anywhere in weeks.
//
// The SQL Server migrations have been regenerated to match the current model
// (see QuotesApi.Migrations.SqlServer), so MigrateAsync is once again the
// honest call for both providers.
//
// DEPLOYED DATABASES: one created by the old EnsureCreated path has the
// tables but no migrations-history table, and MigrateAsync will try to
// CREATE TABLE over them. Such a database has to be baselined (or dropped
// and recreated) before the first deploy that carries this change --
// Day19/verification/day19-evidence-runbook.md has the baseline script.
//
// DAY 24 CORRECTION, AND IT CONTRADICTS THE PARAGRAPH ABOVE. That paragraph
// says MigrateAsync "is once again the honest call for both providers". It is
// not, and the first deployment to Azure SQL proved it: the container crashed
// on every start with
//
//   PendingModelChangesWarning: The model for context 'QuotesDbContext' has
//   pending changes. Add a new migration before updating the database.
//
// and EF Core 10 makes that an error rather than a warning, so the process
// exited before Kestrel bound a port. The revision reported ActivationFailed
// and ingress had no healthy backend at all, which presents as a connection
// refusal rather than an HTTP error.
//
// The pending change was FICTITIOUS. `dotnet ef migrations add` against
// QuotesApi.Migrations.SqlServer produced an EMPTY Up() and left the model
// snapshot byte-identical, which is what finally located the real fault:
//
//   * QuotesApi.Migrations.SqlServer references QuotesApi. QuotesApi
//     references nothing, so that assembly is NOT deployed with the app.
//   * InfrastructureExtensions calls UseSqlServer(connection) with no
//     MigrationsAssembly, so EF falls back to the assembly holding the
//     DbContext -- QuotesApi -- whose Migrations/ folder is the SQLITE set.
//   * So EF diffed the SQL Server model against a SQLite snapshot. Of course
//     it found changes.
//
// Adding the reference the other way is a circular dependency: the migrations
// assembly needs QuotesDbContext, which lives in this project. The structural
// fix is to extract the DbContext into its own assembly, and that is a
// follow-up rather than something to attempt mid-migration.
//
// So SQL Server migrations are applied OUT OF BAND, by the deployment, from
// an idempotent script generated out of the provider's own migrations project:
//
//   dotnet ef migrations script --idempotent \
//     --project QuotesApi.Migrations.SqlServer \
//     --startup-project QuotesApi.Migrations.SqlServer \
//     --context QuotesApi.Data.QuotesDbContext -o migrate.sql
//
// This is the ordinary practice for anything running more than one replica
// anyway: two instances starting together both call MigrateAsync, and EF's
// migration lock is the only thing standing between that and a race.
//
// SQLite keeps migrating in-process, because there the migrations ARE in this
// assembly and a local file database has no deployment pipeline to hook.
//
// WHAT THIS IS NOT: it is not a return to the pre-Day-19 EnsureCreatedAsync
// branch. That branch bypassed the migration history entirely and let the
// provider-specific migrations rot unnoticed. This one still applies those
// exact migrations, still writes __EFMigrationsHistory, and refuses to start
// if they have not been applied -- the schema is still described by
// migrations, and the only thing that moved is who runs them.
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<QuotesDbContext>();

    if (db.Database.IsSqlServer())
    {
        // GetAppliedMigrationsAsync reads __EFMigrationsHistory from the
        // database. Unlike GetPendingMigrationsAsync it does NOT need the local
        // migrations assembly, which is the whole reason it can be used here.
        var applied = (await db.Database.GetAppliedMigrationsAsync()).ToList();

        if (applied.Count == 0)
        {
            // Fail loudly and immediately rather than serving requests against
            // an empty or half-built schema. An app that starts and then 500s
            // on every data endpoint is much harder to diagnose than one that
            // refuses to start and says why.
            throw new InvalidOperationException(
                "The SQL Server database has no applied migrations. They are applied by the " +
                "deployment, not by this app -- see the comment above this line. Generate the " +
                "script with `dotnet ef migrations script --idempotent --project " +
                "QuotesApi.Migrations.SqlServer --startup-project QuotesApi.Migrations.SqlServer " +
                "--context QuotesApi.Data.QuotesDbContext` and apply it to the target database.");
        }

        app.Logger.LogInformation(
            "SQL Server schema is at migration {Migration} ({Count} applied). Migrations are " +
            "applied by the deployment, not at startup.",
            applied[^1], applied.Count);
    }
    else
    {
        await db.Database.MigrateAsync();
    }

    await DbInitializer.SeedAsync(db);
}

// Day 13 -- CORS runs BEFORE authentication and authorization, and that
// order is not cosmetic. A rejected cross-origin request should be rejected
// as a CORS failure that names the origin, and a browser preflight (OPTIONS,
// carrying no Authorization header at all) must be answered before anything
// tries to authenticate it -- otherwise every preflight comes back 401 and
// the real request the browser was asking permission for is never sent.
app.UseCors(CorsExtensions.SpaPolicyName);

// --- Turn authentication/authorization ON ----------------------------------
// UseAuthentication() reads the incoming request's token and figures out
// "who is this?" (it runs the CustomJwt/EntraId/MultiScheme logic that was
// registered in InfrastructureExtensions.cs).
//
// UseAuthorization() then enforces "are they allowed to call this endpoint?"
// on any endpoint marked with .RequireAuthorization() (see
// QuoteEndpointExtensions.cs and CollectionEndpointExtensions.cs).
//
// Order matters: authentication must run before authorization, and both
// must run before the endpoints below so the identity is known by the time
// a request reaches them.
app.UseAuthentication();
app.UseAuthorization();

// Day 27 -- rate limiting runs AFTER authentication, and the order is a
// choice rather than a convention.
//
// Before authentication would throttle slightly earlier and save the token
// validation on a rejected request. After it means the limiter can see who
// the caller is, which is what makes a per-account policy possible later
// without moving this line -- and it means a 429 is only ever returned to a
// request that was otherwise going to be served, so a throttled caller and an
// unauthenticated one are never confused for each other in the logs.
app.UseRateLimiter();

// /api/auth/* is intentionally mapped without any auth requirement of its
// own -- these are the endpoints that HAND OUT tokens in the first place.
// Mapped in the versioned loop below with everything else, so /api/v1/auth
// exists too: a client pinned to v1 must be able to obtain a token without
// dropping back to an unversioned path.

// Health endpoints are mapped without any authorization requirement: an
// orchestrator probing a container has no token to present, and a probe
// that can fail for authentication reasons is worse than no probe. The
// response body is deliberately free of anything sensitive.
app.MapQuotesHealthChecks();

// Day 27 -- API VERSIONING, ADDITIVELY.
//
// Every group is mapped TWICE: once at its existing path and once under
// /api/v1. Nothing that works today stops working, which is the only way to
// introduce versioning to an API that already has a client -- the SPA and the
// verification scripts move to /v1 in their own commit, and the unversioned
// routes stay as deprecated aliases until they do.
//
// WHY ROUTE GROUPS AND NOT THE Asp.Versioning PACKAGE. The package brings
// version discovery, per-version OpenAPI documents and a policy for how
// clients select a version -- machinery that earns its place when there are
// several live versions and consumers you cannot phone. There is one version
// and one consumer. A second route prefix does what the exercise asks with no
// new dependency and no new failure mode.
//
// WHY NOT A URL REWRITE, which would have been less code. Rewriting /api/v1/x
// to /api/x means the two paths can never differ -- and being able to differ
// is the entire point of a version. v2 has to be allowed to change a response
// shape that v1 keeps.
//
// THE COST, STATED: the route table now holds each endpoint twice, so route
// counts and per-endpoint metrics double. The p50/p99 query from Day 26 groups
// by request name, which means /api/quotes and /api/v1/quotes will appear as
// separate rows for the same handler.
foreach (var prefix in new[] { "/api", "/api/v1" })
{
    app.MapAuthEndpoints(prefix);
    app.MapQuoteEndpoints(prefix);
    app.MapCollectionEndpoints(prefix);
    app.MapBackgroundJobEndpoints(prefix);
}

// Day 21 -- GET /api/cache/stats. Mapped in every environment, for the same
// reason as the outbox status endpoint below: it is what an operator reads when
// they suspect the cache has stopped helping.
app.MapCacheEndpoints();

// Day 20 -- GET /api/outbox/status. Mapped in every environment, unlike the
// diagnostics routes below: this is what an operator reads when they suspect
// the relay has stopped, and that suspicion does not arise in Development.
app.MapOutboxEndpoints();

// Day 18 -- requests enqueue quote-author reports and return 202 immediately;
// QueuedBackgroundJobService drains the bounded channel outside the request.
// Mapped in the versioned loop above. Leaving the call here as well mapped the
// same pattern twice and would have thrown on the first request to it.

// Day 11 -- the deliberately slow endpoint used for performance profiling,
// plus the seed/index/stats helpers needed to profile it. Mapped LAST and,
// unlike everything above, mapped conditionally: MapDiagnosticsEndpoints
// returns without registering a single route unless this app is running in
// Development or "Diagnostics:Enabled" is explicitly true. In a deployed
// environment these routes do not exist -- see
// Extensions/DiagnosticsEndpointExtensions.cs for why that is the right
// guarantee for endpoints that are both unauthenticated and destructive.
app.MapDiagnosticsEndpoints();

app.Run();

// Exposes the auto-generated Program class to the test project, so
// WebApplicationFactory<Program> in the integration tests can boot this
// exact app in-memory.
public partial class Program { }
