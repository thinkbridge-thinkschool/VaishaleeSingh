using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Catalog.Infrastructure.Configurations;

public sealed class OutboxMessageConfiguration : IEntityTypeConfiguration<OutboxMessage>
{
    public void Configure(EntityTypeBuilder<OutboxMessage> builder)
    {
        builder.ToTable("OutboxMessages");
        builder.HasKey(m => m.Id);

        builder.HasIndex(m => m.MessageId).IsUnique();

        builder.Property(m => m.EventType).IsRequired().HasMaxLength(200);
        builder.Property(m => m.Payload).IsRequired();
        builder.Property(m => m.Status).IsRequired().HasMaxLength(20);
        builder.Property(m => m.OccurredAtUtc).IsRequired();
        builder.Property(m => m.LastError).HasMaxLength(2000);
        builder.Property(m => m.LockOwner).HasMaxLength(64);

        builder.HasIndex(m => new { m.Status, m.LockedUntilUtc });
    }
}
