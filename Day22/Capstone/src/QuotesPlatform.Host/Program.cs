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

builder.Services.AddCatalogModule(connectionString, serviceBusNamespace);
builder.Services.AddCurationModule(connectionString, serviceBusNamespace);
builder.Services.AddPublishingModule(connectionString, serviceBusNamespace);
builder.Services.AddModerationModule(connectionString, serviceBusNamespace);

var app = builder.Build();

// Endpoints are mapped per module as the slices are built (Day 29 onwards).
// Health is here because it is the Host's own concern, not any module's.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

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
