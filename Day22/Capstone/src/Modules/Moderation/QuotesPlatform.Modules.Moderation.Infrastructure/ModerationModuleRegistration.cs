using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Moderation.Application;

namespace QuotesPlatform.Modules.Moderation.Infrastructure;

/// <summary>
/// The module's own composition, so the Host wires modules rather than types.
///
/// This is the seam that keeps the Host from becoming the place where every
/// module's internals are known: Program.cs calls AddModerationModule and cannot
/// see a repository, a DbContext or a handler. A module that needs a new
/// service registers it here, and nothing outside changes.
/// </summary>
public static class ModerationModuleRegistration
{
    public static IServiceCollection AddModerationModule(
        this IServiceCollection services,
        string connectionString,
        string serviceBusFullyQualifiedNamespace)
    {
        services.AddDbContext<ModerationDbContext>(options => options.UseSqlServer(connectionString));

        services.AddScoped<IReviewRepository, EfReviewRepository>();
        services.AddScoped<IModerationIntegrationEventPublisher, EfOutboxIntegrationEventPublisher>();

        services.AddSingleton(_ =>
            new ServiceBusClient(serviceBusFullyQualifiedNamespace, new DefaultAzureCredential()));
        services.AddHostedService<ModerationOutboxRelayService>();
        services.AddHostedService<ModerationServiceBusConsumerHost>();

        services.AddKeyedScoped<IIntegrationEventHandler, CollectionSubmittedForPublicationHandler>(
            nameof(CollectionSubmittedForPublication));

        return services;
    }
}
