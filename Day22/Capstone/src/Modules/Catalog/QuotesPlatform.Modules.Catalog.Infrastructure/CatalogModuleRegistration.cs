using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Application;

namespace QuotesPlatform.Modules.Catalog.Infrastructure;

/// <summary>
/// The module's own composition, so the Host wires modules rather than types.
///
/// This is the seam that keeps the Host from becoming the place where every
/// module's internals are known: Program.cs calls AddCatalogModule and cannot
/// see a repository, a DbContext or a handler. A module that needs a new
/// service registers it here, and nothing outside changes.
/// </summary>
public static class CatalogModuleRegistration
{
    public static IServiceCollection AddCatalogModule(
        this IServiceCollection services,
        string connectionString,
        string serviceBusFullyQualifiedNamespace)
    {
        services.AddDbContext<CatalogDbContext>(options => options.UseSqlServer(connectionString));

        services.AddScoped<IQuoteRepository, EfQuoteRepository>();
        services.AddScoped<IIntegrationEventPublisher, EfOutboxIntegrationEventPublisher>();

        services.AddSingleton(_ =>
            new ServiceBusClient(serviceBusFullyQualifiedNamespace, new DefaultAzureCredential()));
        services.AddHostedService<CatalogOutboxRelayService>();

        // Use-case handlers and the consumer messaging pieces are registered
        // here as they are written (Day 29, commit 7 onward).

        return services;
    }
}
