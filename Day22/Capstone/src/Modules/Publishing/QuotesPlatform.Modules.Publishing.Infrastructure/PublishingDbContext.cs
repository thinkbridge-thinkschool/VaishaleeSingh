using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Publishing.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// One DbContext per module, over ONE database, with its own schema
/// ("publishing") and no foreign key to any other schema.
///
/// The single database is what makes this a modular monolith rather than
/// microservices: a transaction inside a module is a real transaction, not a
/// saga. The schema separation and the missing cross-schema FKs are what keep
/// the module extractable later -- a cross-schema FK is a join waiting to be
/// written, and a join across a boundary is the boundary gone.
///
/// Cross-module references are therefore ids: Publishing holds Guids belonging to
/// other modules and resolves them through integration events, never through
/// a navigation property.
/// </summary>
public sealed class PublishingDbContext(DbContextOptions<PublishingDbContext> options) : DbContext(options)
{
    public const string Schema = "publishing";

    public DbSet<Edition> Editions => Set<Edition>();

    /// <summary>Written in the same transaction as an Edition change -- see EfOutboxIntegrationEventPublisher.</summary>
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        // Configurations live beside this context and are applied by
        // assembly scan, so adding an entity does not mean editing this
        // method -- the pattern Day7/piece2 arrived at for QuotesDbContext.
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(PublishingDbContext).Assembly);

        base.OnModelCreating(modelBuilder);
    }
}
