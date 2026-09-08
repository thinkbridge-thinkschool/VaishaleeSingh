using Azure.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.FileProviders;
using QuotesApi.Data;
using QuotesApi.Extensions;
using QuotesApi.Middleware;
using Serilog;

// This file is the app's entry point. It runs top-to-bottom, once, when the
// app starts. Its whole job is to wire pieces together and then start
// listening for HTTP requests -- it deliberately contains no business logic.

var builder = WebApplication.CreateBuilder(args);

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

// Backend-owned static assets (quote backgrounds) served from wwwroot.
app.UseStaticFiles();

// --- The Angular front end, served by this app ------------------------------
// Day 24. Until now the SPA was hosted by Azure Static Web Apps, which
// reverse-proxied /api/* to this container over a linked backend. That is not
// available in the new subscription: Microsoft.Web/staticSites exists in only a
// handful of regions worldwide and none of them are permitted by this
// subscription's allowed-locations policy. So the SPA is served from here.
//
// This is the arrangement the front end already assumed, which is why it needs
// no change: Day13/quotes-web/src/environments/environment.production.ts sets
// apiBaseUrl to '' and its own comment says that is correct "when the SPA is
// served from the same host as the API -- behind the same reverse proxy,
// ingress, or Azure Container Apps ingress rule". Every request is now
// same-origin.
//
// A SEPARATE DIRECTORY, NOT wwwroot. wwwroot holds assets this backend owns and
// commits; the SPA is build output from another project. Mixing them means a
// stale main-<hash>.js from a previous build sits in source control next to a
// quote background, and no one can tell which files are which. spa/ is
// gitignored in its entirety.
//
// CONDITIONAL, and that is the load-bearing part. The directory does not exist
// during local `dotnet run`, in the unit and integration suites, or in ci.yml --
// only the deploy workflow builds the Angular bundle into it. An unconditional
// PhysicalFileProvider on a missing directory throws at startup, which would
// turn "the front end was not built" into "the API will not boot".
var spaRoot = Path.Combine(app.Environment.ContentRootPath, "spa");
if (Directory.Exists(spaRoot))
{
    var spaFiles = new PhysicalFileProvider(spaRoot);
    var spaOptions = new StaticFileOptions { FileProvider = spaFiles };

    // Serves index.html for a request to "/" itself. Without it, "/" is a
    // directory with no handler and answers 404 while every deep link works --
    // a failure mode that looks like a routing bug in the SPA.
    app.UseDefaultFiles(new DefaultFilesOptions { FileProvider = spaFiles });
    app.UseStaticFiles(spaOptions);

    // The SPA fallback: any unmatched path returns index.html so the Angular
    // router can handle it client-side.
    //
    // THE REGEX IS THE WHOLE POINT, AND IT REPLACES A CONFIG FILE. The Static
    // Web App did this with navigationFallback.exclude: ["/api/*"] in
    // staticwebapp.config.json, and day17-swa-deploy.yml asserted that entry was
    // present because without it "API errors return index.html with a 200" --
    // its own words. The same hazard exists here: a bare
    // MapFallbackToFile("index.html") answers an unmatched /api/quotes/99999
    // with the HTML shell and a 200, so a client parsing JSON gets a syntax
    // error instead of a 404, and a smoke test that only checks status codes
    // passes against a broken API.
    //
    // Excluding health/ as well: an orchestrator probe that receives an HTML
    // 200 from a misconfigured route is a probe that can never fail.
    // The alternation matches a segment followed by "/" OR by end-of-string.
    // The first version was `^(?!api/|health/).*$`, which only excluded paths
    // with a TRAILING SLASH -- so a request to exactly /health or /api fell
    // through to the SPA shell and answered 200 with HTML. Harmless for /api,
    // which is not an endpoint, but actively misleading for /health: anything
    // probing that path would receive a cheerful 200 from a page, not from the
    // app's health checks.
    app.MapFallbackToFile(
        "{*path:regex(^(?!(api|health)(/|$)).*$)}",
        "index.html",
        spaOptions);
}

// UseRouting HERE, EXPLICITLY, AND THE PLACEMENT IS THE WHOLE POINT.
//
// This one line is the difference between a working front end and an app that
// serves index.html for every asset it owns. It cost an afternoon to find, and
// the failure looked nothing like its cause.
//
// StaticFileMiddleware DOES NOT SERVE A FILE IF ROUTING HAS ALREADY SELECTED AN
// ENDPOINT. That is deliberate on its part: an endpoint won the request, so a
// file should not silently pre-empt it. And WebApplication PREPENDS UseRouting
// to the front of the pipeline when you never call it yourself -- convenient
// right up to the moment you add a catch-all route.
//
// MapFallbackToFile above matches every path that is not api/ or health/. So
// routing selected an endpoint for essentially every request BEFORE the static
// file middleware ran, both UseStaticFiles calls passed straight through, and
// the fallback answered everything with the SPA shell:
//
//   /main-<hash>.js  ->  200, Content-Type: text/html, body = index.html
//
// A module script served as HTML never executes, so <app-root> stayed empty and
// NOTHING was logged -- no console error, no server error, an apparently
// healthy app rendering a blank page. The tell was that wwwroot assets broke
// too (/quote-backgrounds/*.jpg, which predate the SPA work entirely): a bug in
// the SPA block could not explain that, but poisoning routing for the whole app
// could.
//
// Calling UseRouting explicitly stops WebApplication prepending its own, so the
// pipeline becomes: static files first, routing second. Files win when a file
// exists; the fallback answers only what no file matched, which is what a SPA
// fallback is supposed to mean.
//
// Do not move this above the UseStaticFiles calls.
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

// /api/auth/* is intentionally mapped without any auth requirement of its
// own -- these are the endpoints that HAND OUT tokens in the first place.
app.MapAuthEndpoints();

// Health endpoints are mapped without any authorization requirement: an
// orchestrator probing a container has no token to present, and a probe
// that can fail for authentication reasons is worse than no probe. The
// response body is deliberately free of anything sensitive.
app.MapQuotesHealthChecks();

app.MapQuoteEndpoints();
app.MapCollectionEndpoints();

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
app.MapBackgroundJobEndpoints();

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
