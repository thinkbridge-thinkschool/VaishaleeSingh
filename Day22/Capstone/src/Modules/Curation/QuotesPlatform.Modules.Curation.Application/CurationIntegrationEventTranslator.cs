using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Application;

/// <summary>
/// Domain events never leave this module; this is the seam that turns the
/// ones worth announcing into the integration events Contracts already
/// defines for them. Lives in Application, not Domain, because Domain must
/// not reference Contracts (ArchitectureTests) -- see Collection's own
/// comment on why.
///
/// Takes the aggregate itself alongside its DomainEvents because
/// CollectionEditionPublished (domain) carries only CollectionId and
/// EditionNumber, while CollectionPublished (integration) must carry the FULL
/// item snapshot -- the fat-payload rule the design brief argues for, so
/// Publishing never calls back into Curation for "what does this edition
/// contain".
/// </summary>
public static class CurationIntegrationEventTranslator
{
    public static IEnumerable<IIntegrationEvent> Translate(Collection collection, IReadOnlyList<IDomainEvent> domainEvents)
    {
        foreach (var domainEvent in domainEvents)
        {
            switch (domainEvent)
            {
                case CollectionSubmittedForReview submitted:
                    yield return new CollectionSubmittedForPublication(
                        Guid.NewGuid(),
                        submitted.OccurredAt,
                        submitted.CollectionId,
                        submitted.OwnerId,
                        submitted.Name,
                        submitted.ItemCount);
                    break;

                case CollectionEditionPublished published:
                    yield return new CollectionPublished(
                        Guid.NewGuid(),
                        published.OccurredAt,
                        published.CollectionId,
                        published.EditionNumber,
                        collection.Name,
                        collection.OwnerId,
                        collection.Items
                            .OrderBy(i => i.Position)
                            .Select(i => new PublishedItem(i.Position, i.QuoteId, i.Author, i.Text))
                            .ToList());
                    break;
            }
        }
    }
}
