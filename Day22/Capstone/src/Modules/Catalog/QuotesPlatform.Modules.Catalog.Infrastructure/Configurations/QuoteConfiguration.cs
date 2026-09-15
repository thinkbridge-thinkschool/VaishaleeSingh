using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.Modules.Catalog.Domain;

namespace QuotesPlatform.Modules.Catalog.Infrastructure.Configurations;

public sealed class QuoteConfiguration : IEntityTypeConfiguration<Quote>
{
    public void Configure(EntityTypeBuilder<Quote> builder)
    {
        builder.ToTable("Quotes");
        builder.HasKey(q => q.Id);

        builder.Property(q => q.Author)
            .IsRequired()
            .HasMaxLength(Quote.MaxAuthorLength);

        builder.Property(q => q.Text)
            .IsRequired()
            .HasMaxLength(Quote.MaxTextLength);

        builder.Property(q => q.SubmittedByUserId);

        builder.Property(q => q.CreatedAt)
            .IsRequired();

        builder.Property(q => q.IsPublishable)
            .IsRequired();

        // Curation mirrors this flag via QuotePublishable; this is where
        // Catalog itself needs to filter "what can be added to a collection".
        builder.HasIndex(q => q.IsPublishable);

        builder.Ignore(q => q.DomainEvents);
    }
}
