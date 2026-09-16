using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
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
        // Migrations history per schema, not the shared dbo.__EFMigrationsHistory.
        // Four DbContexts over one database otherwise write their migration rows
        // into one table: two modules that generate a migration with the same
        // name in the same second collide on its primary key, and every
        // `dotnet ef` command for one module reads three other modules' rows.
        services.AddDbContext<CurationDbContext>(options =>
            options.UseSqlServer(connectionString, sql =>
                sql.MigrationsHistoryTable("__EFMigrationsHistory", CurationDbContext.Schema)));

        services.AddScoped<ICollectionRepository, EfCollectionRepository>();
        services.AddScoped<ICurationIntegrationEventPublisher, EfOutboxIntegrationEventPublisher>();

        // TryAdd, not Add. All four modules want a client for the SAME namespace
        // (the Host hands each of them the same value), and four AddSingleton
        // calls against one service type do not produce four clients -- the
        // container keeps the last and silently drops the other three. One
        // client is also what the Azure SDK asks for: it owns an AMQP
        // connection and is built to be shared. So each module says "I need one
        // of these" and the first registration satisfies the rest, which is
        // what was already happening, now on purpose rather than by accident.
        services.TryAddSingleton(_ =>
            new ServiceBusClient(serviceBusFullyQualifiedNamespace, new DefaultAzureCredential()));
        services.AddHostedService<CurationOutboxRelayService>();
        services.AddHostedService<CurationServiceBusConsumerHost>();

        services.AddKeyedScoped<IIntegrationEventHandler, CollectionApprovedHandler>(nameof(CollectionApproved));
        services.AddKeyedScoped<IIntegrationEventHandler, CollectionRejectedHandler>(nameof(CollectionRejected));

        return services;
    }
}
