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

builder.Services.AddCatalogModule(connectionString);
builder.Services.AddCurationModule(connectionString);
builder.Services.AddPublishingModule(connectionString);
builder.Services.AddModerationModule(connectionString);

var app = builder.Build();

// Endpoints are mapped per module as the slices are built (Day 23 onwards).
// Health is here because it is the Host's own concern, not any module's.
app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.Run();
