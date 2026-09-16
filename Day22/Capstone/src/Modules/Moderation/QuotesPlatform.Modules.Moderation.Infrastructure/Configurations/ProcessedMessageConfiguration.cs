using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Moderation.Infrastructure.Configurations;

public sealed class ProcessedMessageConfiguration : IEntityTypeConfiguration<ProcessedMessage>
{
    public void Configure(EntityTypeBuilder<ProcessedMessage> builder)
    {
        builder.ToTable("ProcessedMessages");
        builder.HasKey(m => new { m.MessageId, m.SubscriptionName });

        builder.Property(m => m.MessageId).HasMaxLength(64);
        builder.Property(m => m.SubscriptionName).HasMaxLength(100);
        builder.Property(m => m.ProcessedAtUtc).IsRequired();

        // Supports the retention sweep this foundation does not yet build.
        builder.HasIndex(m => m.ProcessedAtUtc);
    }
}
