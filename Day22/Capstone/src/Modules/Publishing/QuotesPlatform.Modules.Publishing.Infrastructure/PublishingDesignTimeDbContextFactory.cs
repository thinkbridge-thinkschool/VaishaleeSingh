using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// `dotnet ef migrations add` needs this to build a PublishingDbContext at
/// design time -- there's no running Host/DI container from this standalone
/// project. The connection string below is never opened for `migrations add`
/// (that command only diffs the model against the last migration); a real one
/// comes from the Host's configuration at run time.
///
/// To (re)generate migrations for this module:
///
///   dotnet ef migrations add &lt;Name&gt; --project QuotesPlatform.Modules.Publishing.Infrastructure --startup-project QuotesPlatform.Modules.Publishing.Infrastructure --context PublishingDbContext --output-dir Migrations
/// </summary>
public sealed class PublishingDesignTimeDbContextFactory : IDesignTimeDbContextFactory<PublishingDbContext>
{
    public PublishingDbContext CreateDbContext(string[] args)
    {
        var optionsBuilder = new DbContextOptionsBuilder<PublishingDbContext>();

        optionsBuilder.UseSqlServer(
            "Server=(local);Database=QuotesPlatform.DesignTime;Trusted_Connection=True;TrustServerCertificate=True;");

        return new PublishingDbContext(optionsBuilder.Options);
    }
}
