using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Publishing.Application;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// The module's own composition, so the Host wires modules rather than types.
///
/// This is the seam that keeps the Host from becoming the place where every
/// module's internals are known: Program.cs calls AddPublishingModule and cannot
/// see a repository, a DbContext or a handler. A module that needs a new
/// service registers it here, and nothing outside changes.
/// </summary>
public static class PublishingModuleRegistration
{
    public static IServiceCollection AddPublishingModule(
        this IServiceCollection services,
        string connectionString)
    {
        services.AddDbContext<PublishingDbContext>(options => options.UseSqlServer(connectionString));

        services.AddScoped<IEditionRepository, EfEditionRepository>();
        services.AddScoped<IIntegrationEventPublisher, EfOutboxIntegrationEventPublisher>();

        // Use-case handlers and the relay/consumer messaging pieces are
        // registered here as they are written (Day 29, commits 6 onward).

        return services;
    }
}
