using Microsoft.EntityFrameworkCore;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// One DbContext per module, over ONE database, with its own schema
/// ("curation") and no foreign key to any other schema.
///
/// The single database is what makes this a modular monolith rather than
/// microservices: a transaction inside a module is a real transaction, not a
/// saga. The schema separation and the missing cross-schema FKs are what keep
/// the module extractable later -- a cross-schema FK is a join waiting to be
/// written, and a join across a boundary is the boundary gone.
///
/// Cross-module references are therefore ids: Curation holds Guids belonging to
/// other modules and resolves them through integration events, never through
/// a navigation property.
/// </summary>
public sealed class CurationDbContext(DbContextOptions<CurationDbContext> options) : DbContext(options)
{
    public const string Schema = "curation";

    public DbSet<Collection> Collections => Set<Collection>();

    /// <summary>Written in the same transaction as a Collection change -- see EfOutboxIntegrationEventPublisher.</summary>
    public DbSet<OutboxMessage> OutboxMessages => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasDefaultSchema(Schema);

        // Configurations live beside this context and are applied by
        // assembly scan, so adding an entity does not mean editing this
        // method -- the pattern Day7/piece2 arrived at for QuotesDbContext.
        modelBuilder.ApplyConfigurationsFromAssembly(typeof(CurationDbContext).Assembly);

        base.OnModelCreating(modelBuilder);
    }
}
