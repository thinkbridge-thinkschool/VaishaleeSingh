using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
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
        string connectionString)
    {
        services.AddDbContext<ModerationDbContext>(options => options.UseSqlServer(connectionString));

        services.AddScoped<IReviewRepository, EfReviewRepository>();

        // Use-case handlers and the outbox/messaging pieces are registered
        // here as they are written (Day 29, commits 5 onward).

        return services;
    }
}
