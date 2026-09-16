using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace QuotesPlatform.Modules.Curation.Infrastructure;

/// <summary>
/// `dotnet ef migrations add` needs this to build a CurationDbContext at
/// design time -- there's no running Host/DI container from this standalone
/// project. The connection string below is never opened for `migrations add`
/// (that command only diffs the model against the last migration); a real one
/// comes from the Host's configuration at run time.
///
/// To (re)generate migrations for this module:
///
///   dotnet ef migrations add &lt;Name&gt; --project QuotesPlatform.Modules.Curation.Infrastructure --startup-project QuotesPlatform.Modules.Curation.Infrastructure --context CurationDbContext --output-dir Migrations
/// </summary>
public sealed class CurationDesignTimeDbContextFactory : IDesignTimeDbContextFactory<CurationDbContext>
{
    public CurationDbContext CreateDbContext(string[] args)
    {
        var optionsBuilder = new DbContextOptionsBuilder<CurationDbContext>();

        optionsBuilder.UseSqlServer(
            "Server=(local);Database=QuotesPlatform.DesignTime;Trusted_Connection=True;TrustServerCertificate=True;",
            sql => sql.MigrationsHistoryTable("__EFMigrationsHistory", CurationDbContext.Schema));

        return new CurationDbContext(optionsBuilder.Options);
    }
}
