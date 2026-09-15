using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Application;

/// <summary>
/// Domain events never leave this module; this is the seam that turns the one
/// worth announcing into the integration event Contracts already defines for
/// it. Lives in Application, not Domain, because Domain must not reference
/// Contracts (ArchitectureTests) -- see Collection's own comment on why.
///
/// Only CollectionSubmittedForReview is translated today. Approve/Reject
/// raise events too, but nothing publishes them until commit 11 wires the
/// consumer that reacts to Moderation's decision.
/// </summary>
public static class CurationIntegrationEventTranslator
{
    public static IEnumerable<IIntegrationEvent> Translate(IReadOnlyList<IDomainEvent> domainEvents)
    {
        foreach (var domainEvent in domainEvents)
        {
            if (domainEvent is CollectionSubmittedForReview submitted)
            {
                yield return new CollectionSubmittedForPublication(
                    Guid.NewGuid(),
                    submitted.OccurredAt,
                    submitted.CollectionId,
                    submitted.OwnerId,
                    submitted.Name,
                    submitted.ItemCount);
            }
        }
    }
}
