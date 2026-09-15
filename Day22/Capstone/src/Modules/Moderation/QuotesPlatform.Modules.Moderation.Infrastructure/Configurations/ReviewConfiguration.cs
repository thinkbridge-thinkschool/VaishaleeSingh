using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.Modules.Moderation.Domain;

namespace QuotesPlatform.Modules.Moderation.Infrastructure.Configurations;

public sealed class ReviewConfiguration : IEntityTypeConfiguration<Review>
{
    public void Configure(EntityTypeBuilder<Review> builder)
    {
        builder.ToTable("Reviews");
        builder.HasKey(r => r.Id);

        builder.Property(r => r.Subject)
            .IsRequired()
            .HasConversion<string>()
            .HasMaxLength(20);

        builder.Property(r => r.SubjectId)
            .IsRequired();

        builder.Property(r => r.Outcome)
            .IsRequired()
            .HasConversion<string>()
            .HasMaxLength(20);

        builder.Property(r => r.ReviewerId);

        builder.Property(r => r.Reason)
            .HasMaxLength(1000);

        builder.Property(r => r.OpenedAt)
            .IsRequired();

        builder.Property(r => r.DecidedAt);

        // Moderation opens at most one pending review per subject -- the
        // happy path never has to guess which of several open reviews to
        // decide.
        builder.HasIndex(r => new { r.Subject, r.SubjectId, r.Outcome });

        builder.Ignore(r => r.DomainEvents);
    }
}
