using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

// ONE PROCESS, ONE DATABASE, FOUR MODULES.
//
// Each module composes itself (see its *ModuleRegistration). This file is
// deliberately the shortest interesting file in the solution: the moment it
// starts registering repositories or mapping endpoints for a module, the
// module has stopped owning its own composition and the Host has become the
// place where everything is known.
// A real SQL Server, not a default -- see appsettings.json for how to supply
// it via user-secrets. Failing fast here is cheaper than a module discovering
// it has no connection string the first time an endpoint touches its DbContext.
var connectionString = builder.Configuration.GetConnectionString("Default");
if (string.IsNullOrWhiteSpace(connectionString))
    throw new InvalidOperationException(
        "ConnectionStrings:Default is not set. Supply it via user-secrets or environment configuration.");

// The Service Bus namespace every module's outbox relay publishes to and every
// consumer reads from -- see QuotesPlatform.Contracts.ServiceBusTopology.
// Authenticated with DefaultAzureCredential inside each module's
// registration, never a connection string with a key.
var serviceBusNamespace = builder.Configuration["ServiceBus:FullyQualifiedNamespace"];
if (string.IsNullOrWhiteSpace(serviceBusNamespace))
    throw new InvalidOperationException(
        "ServiceBus:FullyQualifiedNamespace is not set. Supply it via user-secrets or environment configuration.");

// AUTHENTICATION -- added Day 32, the day this became reachable from the
// internet. ADR-0003 accepted the missing authentication "until 2026-10-31, or
// immediately on first deployment to any shared environment, whichever comes
// first", on the explicit argument that there was no attacker because there was
// no route. Deploying creates the route, so the acceptance ended here.
//
// Fails fast like the two above, and for a sharper reason: a Host that starts
// without an authority configured cannot validate a token, and the failure mode
// of "cannot validate" must never be "let it through".
var authority = builder.Configuration["AzureAd:Authority"];
if (string.IsNullOrWhiteSpace(authority))
    throw new InvalidOperationException(
        "AzureAd:Authority is not set (e.g. https://login.microsoftonline.com/<tenant-id>/v2.0). " +
        "The API cannot validate tokens without it and will not start unauthenticated.");

var audience = builder.Configuration["AzureAd:Audience"];
if (string.IsNullOrWhiteSpace(audience))
    throw new InvalidOperationException(
        "AzureAd:Audience is not set (e.g. api://<api-client-id>). Without it any correctly signed " +
        "token from the tenant would be accepted, including one issued for a different application.");

// PLAIN JwtBearer RATHER THAN Microsoft.Identity.Web, on purpose. Entra tokens
// validate against an authority and an audience; Identity.Web adds a package
// family, its own configuration shape and claim remapping to do the same job.
// One dependency at a version this repository already uses beats four at
// versions nobody here has run.
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = authority;
        options.Audience = audience;

        // Keep claims named as the token names them -- `oid`, `sub` -- rather
        // than rewriting them to long SOAP-era URIs. CallerIdentity looks for
        // `oid`, and a claim silently renamed under it is the kind of failure
        // that reads as "the owner cannot edit their own collection".
        options.MapInboundClaims = false;

        options.TokenValidationParameters.ValidateIssuer = true;
        options.TokenValidationParameters.ValidateAudience = true;
        options.TokenValidationParameters.ValidateLifetime = true;

        // The default is five minutes, which means a token stays usable for
        // five minutes after it expires. Small, but this guards an audit trail.
        options.TokenValidationParameters.ClockSkew = TimeSpan.FromSeconds(30);
    });

// DEFAULT DENY. Every endpoint requires an authenticated caller unless it says
// otherwise, and exactly one says otherwise (/health, below).
//
// The alternative -- .RequireAuthorization() on each of the twelve routes --
// was rejected because it fails OPEN: the day someone adds a thirteenth
// endpoint and forgets the call, that endpoint is public and nothing says so.
// This way the same mistake produces a 401 and a bug report, not a breach.
builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

builder.Services.AddCatalogModule(connectionString, serviceBusNamespace);
builder.Services.AddCurationModule(connectionString, serviceBusNamespace);
builder.Services.AddPublishingModule(connectionString, serviceBusNamespace);
builder.Services.AddModerationModule(connectionString, serviceBusNamespace);

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// Endpoints are mapped per module as the slices are built (Day 29 onwards).
// Health is here because it is the Host's own concern, not any module's.
//
// The ONE anonymous endpoint. Container Apps probes it before a revision is
// allowed to take traffic, and a probe cannot carry a token. It returns a
// constant and touches neither the database nor any aggregate.
app.MapGet("/health", () => Results.Ok(new { status = "ok" })).AllowAnonymous();

app.MapCatalogEndpoints();
app.MapCurationEndpoints();
app.MapModerationEndpoints();
app.MapPublishingEndpoints();

app.Run();

/// <summary>
/// WHY THIS EMPTY CLASS EXISTS.
///
/// Program.cs uses top-level statements, so the compiler generates an
/// INTERNAL Program class. WebApplicationFactory&lt;Program&gt; needs it to be
/// accessible, and without this declaration QuotesPlatform.ApiTests does not
/// compile -- the error names Program rather than the accessibility, which is
/// why it is worth a comment rather than a one-liner.
///
/// The alternative is [assembly: InternalsVisibleTo("QuotesPlatform.ApiTests")],
/// which opens every internal in the Host to the test project rather than the
/// one type the test framework actually needs. This is the narrower of the two.
/// </summary>
public partial class Program;
