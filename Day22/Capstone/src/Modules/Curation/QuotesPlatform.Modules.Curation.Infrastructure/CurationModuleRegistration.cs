using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Application;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// The module's own composition, so the Host wires modules rather than types.
///
/// This is the seam that keeps the Host from becoming the place where every
/// module's internals are known: Program.cs calls AddCurationModule and cannot
/// see a repository, a DbContext or a handler. A module that needs a new
/// service registers it here, and nothing outside changes.
/// </summary>
public static class CurationModuleRegistration
{
    public static IServiceCollection AddCurationModule(
        this IServiceCollection services,
        string connectionString,
        string serviceBusFullyQualifiedNamespace)
    {
        services.AddDbContext<CurationDbContext>(options => options.UseSqlServer(connectionString));

        services.AddScoped<ICollectionRepository, EfCollectionRepository>();
        services.AddScoped<IIntegrationEventPublisher, EfOutboxIntegrationEventPublisher>();

        // One client per module rather than one shared client -- keeps a
        // module's messaging concern inside its own registration, the same
        // way its DbContext is not shared with any other module.
        services.AddSingleton(_ =>
            new ServiceBusClient(serviceBusFullyQualifiedNamespace, new DefaultAzureCredential()));
        services.AddHostedService<CurationOutboxRelayService>();

        // Use-case handlers and the consumer messaging pieces are registered
        // here as they are written (Day 29, commit 7 onward).

        return services;
    }
}
