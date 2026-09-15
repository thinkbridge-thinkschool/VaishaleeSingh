using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using QuotesPlatform.Modules.Curation.Domain;

namespace QuotesPlatform.Modules.Curation.Infrastructure.Configurations;

/// <summary>
/// Collection is the aggregate; Items and Members are owned collections with
/// no existence or repository of their own -- the same shape the domain
/// already enforces via their `internal` constructors, reachable only through
/// Collection's own methods.
/// </summary>
public sealed class CollectionConfiguration : IEntityTypeConfiguration<Collection>
{
    public void Configure(EntityTypeBuilder<Collection> builder)
    {
        builder.ToTable("Collections");
        builder.HasKey(c => c.Id);

        builder.Property(c => c.Name)
            .IsRequired()
            .HasMaxLength(Collection.MaxNameLength);

        builder.Property(c => c.OwnerId)
            .IsRequired();

        // Stored as text, not the enum's int, so a row read in SSMS says
        // "Published" rather than a number that only means something with
        // CollectionState open next to it.
        builder.Property(c => c.State)
            .IsRequired()
            .HasConversion<string>()
            .HasMaxLength(20);

        builder.Property(c => c.EditionNumber)
            .IsRequired();

        builder.Property(c => c.CreatedAt)
            .IsRequired();

        builder.OwnsMany(c => c.Items, item =>
        {
            item.ToTable("CollectionItems");
            item.WithOwner().HasForeignKey("CollectionId");
            item.HasKey(i => i.Id);

            item.Property(i => i.QuoteId).IsRequired();
            item.Property(i => i.Author).IsRequired().HasMaxLength(200);
            item.Property(i => i.Text).IsRequired().HasMaxLength(1000);
            item.Property(i => i.IsPublishable).IsRequired();
            item.Property(i => i.Position).IsRequired();
            item.Property(i => i.AddedAt).IsRequired();

            // Second line of defence behind Collection.AddItem's own check --
            // a direct insert against this table still can't duplicate a quote.
            item.HasIndex("CollectionId", nameof(CollectionItem.QuoteId)).IsUnique();
        });

        builder.OwnsMany(c => c.Members, member =>
        {
            member.ToTable("CollectionMembers");
            member.WithOwner().HasForeignKey("CollectionId");
            member.HasKey(m => m.Id);

            member.Property(m => m.UserId).IsRequired();
            member.Property(m => m.Role).IsRequired().HasConversion<string>().HasMaxLength(20);

            member.HasIndex("CollectionId", nameof(CollectionMember.UserId)).IsUnique();
        });

        // In-memory only (AggregateRoot<TId>.DomainEvents) -- mapping it would
        // make EF try to persist a column for something that is cleared after
        // every dispatch and never meant to survive a load.
        builder.Ignore(c => c.DomainEvents);
    }
}
