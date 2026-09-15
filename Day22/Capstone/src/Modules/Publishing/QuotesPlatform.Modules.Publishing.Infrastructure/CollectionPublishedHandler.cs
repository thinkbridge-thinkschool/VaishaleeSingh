using System.Text;
using System.Text.Json;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Publishing.Application;
using QuotesPlatform.Modules.Publishing.Domain;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Builds the Edition ENTIRELY from the event payload -- never a call back
/// into Curation for "what does this collection contain now", which would
/// make the edition reflect the present instead of what was approved. See
/// PublishedItem's own comment and the design's flow 1.
///
/// No SaveChangesAsync here -- the consumer host commits this add together
/// with its own ProcessedMessages row.
/// </summary>
public sealed class CollectionPublishedHandler(IEditionRepository repository) : IIntegrationEventHandler
{
    public async Task HandleAsync(string payload, CancellationToken cancellationToken)
    {
        var evt = JsonSerializer.Deserialize<CollectionPublished>(payload)
            ?? throw new InvalidOperationException("CollectionPublished payload deserialized to null.");

        var slug = Slugify(evt.Name, evt.CollectionId);

        var edition = Edition.FromSnapshot(
            evt.CollectionId,
            evt.EditionNumber,
            evt.Name,
            slug,
            evt.OwnerId,
            evt.OccurredAt,
            evt.Items.Select(i => new EditionItem(i.Position, i.QuoteId, i.Author, i.Text)));

        await repository.AddAsync(edition, cancellationToken);
    }

    /// <summary>
    /// Stable per collection, not per edition (see Edition.Slug): derived from
    /// the name at first publish, with the collection id suffixed so two
    /// differently-owned collections sharing a name do not collide.
    /// </summary>
    private static string Slugify(string name, Guid collectionId)
    {
        var builder = new StringBuilder();
        foreach (var c in name.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c))
                builder.Append(c);
            else if (builder.Length > 0 && builder[^1] != '-')
                builder.Append('-');
        }

        var slugified = builder.ToString().Trim('-');
        var shortId = collectionId.ToString("N")[..8];
        var combined = string.IsNullOrEmpty(slugified) ? shortId : $"{slugified}-{shortId}";

        return combined.Length > 120 ? combined[..120] : combined;
    }
}
