using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure.Configurations;

/// <summary>
/// Edition is immutable once built -- see the domain type's own comment. Items
/// are an owned collection of value objects (EditionItem is a plain record,
/// no identity of its own), keyed on (EditionId, Position) since positions are
/// already unique and contiguous within one edition.
/// </summary>
public sealed class EditionConfiguration : IEntityTypeConfiguration<Edition>
{
    public void Configure(EntityTypeBuilder<Edition> builder)
    {
        builder.ToTable("Editions");
        builder.HasKey(e => e.Id);

        builder.Property(e => e.CollectionId)
            .IsRequired();

        builder.Property(e => e.EditionNumber)
            .IsRequired();

        builder.Property(e => e.Name)
            .IsRequired()
            .HasMaxLength(80);

        builder.Property(e => e.Slug)
            .IsRequired()
            .HasMaxLength(120);

        builder.Property(e => e.OwnerId)
            .IsRequired();

        builder.Property(e => e.PublishedAt)
            .IsRequired();

        // One collection cannot publish the same edition number twice.
        builder.HasIndex(e => new { e.CollectionId, e.EditionNumber }).IsUnique();

        // Slug is stable per collection across editions (see Edition.Slug),
        // so this is a lookup index, not a uniqueness constraint.
        builder.HasIndex(e => e.Slug);

        builder.OwnsMany(e => e.Items, item =>
        {
            item.ToTable("EditionItems");
            item.WithOwner().HasForeignKey("EditionId");

            item.Property(i => i.Position).IsRequired().ValueGeneratedNever();
            item.Property(i => i.QuoteId).IsRequired();
            item.Property(i => i.Author).IsRequired().HasMaxLength(200);
            item.Property(i => i.Text).IsRequired().HasMaxLength(1000);

            item.HasKey("EditionId", nameof(EditionItem.Position));
        });

        builder.Ignore(e => e.DomainEvents);
    }
}
