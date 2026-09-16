using System.Text.Json;
using FluentAssertions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Application;
using QuotesPlatform.Modules.Catalog.Domain;
using QuotesPlatform.Modules.Curation.Application;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.Modules.Moderation.Application;
using QuotesPlatform.Modules.Moderation.Domain;
using CatalogCtx = QuotesPlatform.Modules.Catalog.Infrastructure.CatalogDbContext;
using CatalogHandler = QuotesPlatform.Modules.Catalog.Infrastructure.IIntegrationEventHandler;
using CurationCtx = QuotesPlatform.Modules.Curation.Infrastructure.CurationDbContext;
using CurationHandler = QuotesPlatform.Modules.Curation.Infrastructure.IIntegrationEventHandler;
using ModerationCtx = QuotesPlatform.Modules.Moderation.Infrastructure.ModerationDbContext;
using ModerationHandler = QuotesPlatform.Modules.Moderation.Infrastructure.IIntegrationEventHandler;

namespace QuotesPlatform.IntegrationTests;

/// <summary>
/// The first tests in this solution that RUN a handler.
///
/// Each one drives a handler exactly as its consumer host does: resolve it
/// keyed by event name, hand it the serialized payload, then SaveChangesAsync
/// on the module's own DbContext -- the handler never saves, by design, so a
/// test that forgot the save would assert on changes that were never written.
/// </summary>
[Collection(CapstoneCollection.Name)]
public sealed class FlowTests(CapstoneFixture fixture)
{
    // ---- flow 1: the reject / revise loop -----------------------------------

    [Fact]
    public async Task Rejecting_an_unpublished_collection_returns_it_to_draft()
    {
        var collection = await GivenSubmittedCollectionAsync();

        await HandleCurationAsync(new CollectionRejected(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1", "Item 2 is misattributed."));

        var reloaded = await LoadCollectionAsync(collection.Id);
        reloaded.State.Should().Be(CollectionState.Draft);
        reloaded.EditionNumber.Should().Be(0);
    }

    [Fact]
    public async Task Rejecting_a_published_collection_returns_it_to_revising_not_draft()
    {
        var collection = await GivenPublishedCollectionAsync();

        await MutateCollectionAsync(collection.Id, c => c.BeginRevision("curator-1"));
        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));

        await HandleCurationAsync(new CollectionRejected(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1", "Needs a stronger closing quote."));

        var reloaded = await LoadCollectionAsync(collection.Id);

        // The distinction the whole rejection path exists for: a rejected
        // REVISION must not lose the fact that edition 1 is still serving.
        reloaded.State.Should().Be(CollectionState.Revising);
        reloaded.EditionNumber.Should().Be(1);
    }

    [Fact]
    public async Task A_rejected_collection_can_be_edited_resubmitted_and_published()
    {
        var collection = await GivenSubmittedCollectionAsync();

        await HandleCurationAsync(new CollectionRejected(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1", "Drop the third one."));

        // Editable again, which is the entire point of returning to Draft.
        var extraQuote = await GivenPublishableQuoteAsync();
        await MutateCollectionAsync(collection.Id, c => c.AddItem(
            extraQuote, "Author 4", "Quote text number 4.", true, "curator-1", DateTimeOffset.UtcNow));
        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));

        await HandleCurationAsync(new CollectionApproved(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1"));

        var reloaded = await LoadCollectionAsync(collection.Id);
        reloaded.State.Should().Be(CollectionState.Published);
        reloaded.EditionNumber.Should().Be(1);
        reloaded.Items.Should().HaveCount(4);
    }

    [Fact]
    public async Task A_revision_publishes_edition_two_rather_than_replacing_edition_one()
    {
        var collection = await GivenPublishedCollectionAsync();

        await MutateCollectionAsync(collection.Id, c => c.BeginRevision("curator-1"));
        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));
        await HandleCurationAsync(new CollectionApproved(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1"));

        var reloaded = await LoadCollectionAsync(collection.Id);
        reloaded.EditionNumber.Should().Be(2);
        reloaded.State.Should().Be(CollectionState.Published);
    }

    // ---- flow 2: a correction reaches drafts and stops at editions ----------

    [Fact]
    public async Task A_quote_revision_refreshes_a_draft_snapshot()
    {
        var quoteId = await GivenPublishableQuoteAsync();
        var collection = await GivenCollectionHoldingAsync(quoteId, "Original Author", "Original text.");

        await HandleCurationAsync(new QuoteRevised(
            Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId, "Corrected Author", "Corrected text."));

        var item = (await LoadCollectionAsync(collection.Id)).Items.Single(i => i.QuoteId == quoteId);
        item.Author.Should().Be("Corrected Author");
        item.Text.Should().Be("Corrected text.");
    }

    /// <summary>
    /// The promise Publishing's whole existence rests on. If this ever fails,
    /// a published edition changed under a reader.
    /// </summary>
    [Fact]
    public async Task A_quote_revision_does_not_touch_a_published_collection()
    {
        var quoteId = await GivenPublishableQuoteAsync();
        var collection = await GivenPublishedCollectionAsync(extraQuoteId: quoteId);

        await HandleCurationAsync(new QuoteRevised(
            Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId, "Corrected Author", "Corrected text."));

        var item = (await LoadCollectionAsync(collection.Id)).Items.Single(i => i.QuoteId == quoteId);
        item.Author.Should().NotBe("Corrected Author");
        item.Text.Should().NotBe("Corrected text.");
    }

    // ---- flow 3: quote moderation ------------------------------------------

    [Fact]
    public async Task A_submitted_quote_opens_exactly_one_review_however_often_it_is_announced()
    {
        var quoteId = await GivenQuoteAsync(publishable: false);

        // Two DIFFERENT MessageIds, so ProcessedMessages cannot be what saves
        // this -- it has to be the handler's own pending check.
        await HandleModerationAsync(new QuoteSubmitted(Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId, "curator-1"));
        await HandleModerationAsync(new QuoteSubmitted(Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId, "curator-1"));

        await using var scope = fixture.Services.CreateAsyncScope();
        var reviews = await scope.ServiceProvider.GetRequiredService<ModerationCtx>()
            .Set<Review>().Where(r => r.SubjectId == quoteId).ToListAsync();

        reviews.Should().ContainSingle();
        reviews[0].Subject.Should().Be(ReviewSubject.Quote);
    }

    [Fact]
    public async Task Approving_a_quote_marks_it_publishable_and_announces_that_separately()
    {
        var quoteId = await GivenQuoteAsync(publishable: false);

        await HandleCatalogAsync(new QuoteApproved(
            Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId, "reviewer-1"));

        await using var scope = fixture.Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<CatalogCtx>();

        (await db.Quotes.SingleAsync(q => q.Id == quoteId)).IsPublishable.Should().BeTrue();

        // The outbox row is the part that matters: marking it publishable
        // without announcing it leaves Curation's snapshots stale forever, and
        // nothing would ever report an error.
        var outbox = await db.OutboxMessages
            .Where(m => m.EventType == nameof(QuotePublishable)).ToListAsync();
        outbox.Should().ContainSingle();
        outbox[0].Payload.Should().Contain(quoteId.ToString());
    }

    [Fact]
    public async Task A_publishable_quote_updates_the_flag_on_every_editable_collection_holding_it()
    {
        var quoteId = await GivenQuoteAsync(publishable: false);
        var first = await GivenCollectionHoldingAsync(quoteId, "Author", "Text.", publishable: false);
        var second = await GivenCollectionHoldingAsync(quoteId, "Author", "Text.", publishable: false);

        await HandleCurationAsync(new QuotePublishable(Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId));

        foreach (var id in new[] { first.Id, second.Id })
        {
            (await LoadCollectionAsync(id)).Items.Single(i => i.QuoteId == quoteId)
                .IsPublishable.Should().BeTrue($"collection {id} holds the quote and is editable");
        }
    }

    [Fact]
    public async Task A_collection_holding_an_unreviewed_quote_cannot_be_submitted_until_it_clears()
    {
        var quoteId = await GivenQuoteAsync(publishable: false);
        var collection = await GivenCollectionHoldingAsync(quoteId, "Author", "Text.", publishable: false, fillToMinimum: true);

        var submitTooEarly = async () =>
            await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));

        await submitTooEarly.Should().ThrowAsync<QuotesPlatform.SharedKernel.DomainException>();

        await HandleCurationAsync(new QuotePublishable(Guid.NewGuid(), DateTimeOffset.UtcNow, quoteId));

        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));
        (await LoadCollectionAsync(collection.Id)).State.Should().Be(CollectionState.InReview);
    }

    // ---- driving the handlers the way their consumer hosts do ---------------

    private Task HandleCurationAsync(IIntegrationEvent evt) =>
        HandleAsync<CurationHandler, CurationCtx>(evt);

    private Task HandleModerationAsync(IIntegrationEvent evt) =>
        HandleAsync<ModerationHandler, ModerationCtx>(evt);

    private Task HandleCatalogAsync(IIntegrationEvent evt) =>
        HandleAsync<CatalogHandler, CatalogCtx>(evt);

    private async Task HandleAsync<THandler, TContext>(IIntegrationEvent evt)
        where THandler : class
        where TContext : DbContext
    {
        await using var scope = fixture.Services.CreateAsyncScope();
        var handler = scope.ServiceProvider.GetRequiredKeyedService<THandler>(evt.GetType().Name);
        var db = scope.ServiceProvider.GetRequiredService<TContext>();

        var handle = (Task)typeof(THandler).GetMethod("HandleAsync")!
            .Invoke(handler, [JsonSerializer.Serialize(evt, evt.GetType()), CancellationToken.None])!;
        await handle;

        // The handler never saves -- its consumer host does, together with the
        // ProcessedMessages row. A test that skipped this would assert on
        // changes that were only ever tracked.
        await db.SaveChangesAsync();
    }

    // ---- arrangement --------------------------------------------------------

    private async Task<Guid> GivenQuoteAsync(bool publishable)
    {
        await using var scope = fixture.Services.CreateAsyncScope();
        var repository = scope.ServiceProvider.GetRequiredService<IQuoteRepository>();
        var quote = Quote.Submit("Author", "Some quote text.", "curator-1", DateTimeOffset.UtcNow);

        if (publishable)
            quote.MarkPublishable();

        await repository.AddAsync(quote);
        await repository.SaveChangesAsync();
        return quote.Id;
    }

    private Task<Guid> GivenPublishableQuoteAsync() => GivenQuoteAsync(publishable: true);

    private async Task<Collection> GivenCollectionHoldingAsync(
        Guid quoteId, string author, string text, bool publishable = true, bool fillToMinimum = false)
    {
        await using var scope = fixture.Services.CreateAsyncScope();
        var repository = scope.ServiceProvider.GetRequiredService<ICollectionRepository>();

        var collection = Collection.Create($"Collection {Guid.NewGuid():N}"[..40], "curator-1", DateTimeOffset.UtcNow);
        collection.AddItem(quoteId, author, text, publishable, "curator-1", DateTimeOffset.UtcNow);

        if (fillToMinimum)
        {
            for (var i = 2; i <= Collection.MinItemsToPublish; i++)
                collection.AddItem(Guid.NewGuid(), $"Author {i}", $"Text {i}.", true, "curator-1", DateTimeOffset.UtcNow);
        }

        await repository.AddAsync(collection);
        await repository.SaveChangesAsync();
        return collection;
    }

    private async Task<Collection> GivenSubmittedCollectionAsync()
    {
        var collection = await GivenCollectionHoldingAsync(
            await GivenPublishableQuoteAsync(), "Author 1", "Quote text number 1.", fillToMinimum: true);

        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));
        return collection;
    }

    private async Task<Collection> GivenPublishedCollectionAsync(Guid? extraQuoteId = null)
    {
        var collection = await GivenCollectionHoldingAsync(
            extraQuoteId ?? await GivenPublishableQuoteAsync(),
            "Original Author", "Original text.", fillToMinimum: true);

        await MutateCollectionAsync(collection.Id, c => c.SubmitForPublication("curator-1", DateTimeOffset.UtcNow));
        await HandleCurationAsync(new CollectionApproved(
            Guid.NewGuid(), DateTimeOffset.UtcNow, collection.Id, "reviewer-1"));

        return collection;
    }

    private async Task MutateCollectionAsync(Guid id, Action<Collection> mutate)
    {
        await using var scope = fixture.Services.CreateAsyncScope();
        var repository = scope.ServiceProvider.GetRequiredService<ICollectionRepository>();
        var collection = await repository.GetAsync(id) ?? throw new InvalidOperationException($"Collection {id} missing.");

        mutate(collection);
        collection.ClearDomainEvents();
        await repository.SaveChangesAsync();
    }

    private async Task<Collection> LoadCollectionAsync(Guid id)
    {
        await using var scope = fixture.Services.CreateAsyncScope();
        return await scope.ServiceProvider.GetRequiredService<ICollectionRepository>().GetAsync(id)
            ?? throw new InvalidOperationException($"Collection {id} missing.");
    }
}
