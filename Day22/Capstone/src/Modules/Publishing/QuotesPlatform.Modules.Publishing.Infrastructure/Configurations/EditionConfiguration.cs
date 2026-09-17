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

        // Slug is stable per collection across editions (see Edition.Slug), so
        // this is a lookup index and not a uniqueness constraint.
        //
        // COMPOSITE, AND DESCENDING ON THE SECOND COLUMN, because the hot query
        // does both things: GetLatestBySlugAsync filters on Slug and then orders
        // by EditionNumber descending to take the newest. A Slug-only index lets
        // SQL Server seek the slug and then makes it sort the matches; ordering
        // the index the way the query reads it turns that into a seek plus a
        // top-1, with no sort operator in the plan at all.
        //
        // It also still serves any Slug-only lookup, since Slug is the leading
        // column -- which is why the standalone index it replaces is gone rather
        // than kept alongside. Two indexes where one suffices is write cost on
        // every publish for no read benefit.
        builder.HasIndex(e => new { e.Slug, e.EditionNumber })
            .IsDescending(false, true);

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
