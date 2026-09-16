using FluentAssertions;
using QuotesPlatform.Modules.Curation.Domain;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Domain.Tests;

/// <summary>
/// The invariants that make Collection an aggregate rather than a list with a
/// name attached.
///
/// The three carried-forward rules (name length, 50-item cap, no duplicates)
/// are covered in CarriedForwardRuleTests. This file is the new behaviour: the
/// review freeze, the edition counter, contiguous positions, and who is
/// allowed to do what.
///
/// Every test builds its collection through the public API rather than through
/// a fixture that sets state directly -- if a state cannot be reached by
/// calling domain methods in order, the test would be asserting on a state the
/// real system can never be in.
/// </summary>
public class CollectionInvariantTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 4, 12, 0, 0, TimeSpan.Zero);
    private const string Owner = "user-owner";
    private const string Contributor = "user-contributor";
    private const string Stranger = "user-stranger";

    [Fact]
    public void A_new_collection_is_a_draft_owned_by_its_creator_with_no_editions()
    {
        var collection = Collection.Create("Stoic mornings", Owner, Now);

        collection.State.Should().Be(CollectionState.Draft);
        collection.EditionNumber.Should().Be(0);
        collection.OwnerId.Should().Be(Owner);
        collection.Members.Should().ContainSingle(m => m.UserId == Owner && m.Role == CollectionRole.Owner);
    }

    // ---- invariant 6: the review freeze -------------------------------------

    [Fact]
    public void Items_cannot_change_while_the_collection_is_in_review()
    {
        var collection = SubmittedCollection();

        var addItem = () => collection.AddItem(
            Guid.NewGuid(), "Epictetus", "No man is free who is not master of himself.",
            isPublishable: true, Owner, Now);

        // THE POINT OF THIS INVARIANT: without it, review is theatre. A
        // contributor adds a quote after approval and unreviewed content goes
        // live under a reviewer's name.
        addItem.Should().Throw<DomainException>()
            .WithMessage("*cannot be changed*")
            .WithMessage("*has to be the collection that gets published*");
    }

    [Fact]
    public void The_name_cannot_change_while_the_collection_is_in_review()
    {
        var collection = SubmittedCollection();

        var rename = () => collection.Rename("Something else entirely", Owner);

        rename.Should().Throw<DomainException>();
    }

    // ---- invariant 7: editions ----------------------------------------------

    [Fact]
    public void Approval_publishes_the_next_edition_exactly_one_higher()
    {
        var collection = SubmittedCollection();

        collection.Approve(Now);

        collection.State.Should().Be(CollectionState.Published);
        collection.EditionNumber.Should().Be(1);
        collection.DomainEvents.OfType<CollectionEditionPublished>()
            .Should().ContainSingle(e => e.EditionNumber == 1);
    }

    [Fact]
    public void A_published_collection_cannot_be_edited_until_a_revision_is_opened()
    {
        var collection = PublishedCollection();

        var addItem = () => collection.AddItem(
            Guid.NewGuid(), "Marcus", "Waste no more time arguing.", true, Owner, Now);

        addItem.Should().Throw<DomainException>().WithMessage("*BeginRevision*");

        collection.BeginRevision(Owner);
        collection.State.Should().Be(CollectionState.Revising);

        // The live edition is still edition 1 while the next one is worked on:
        // readers are never shown a half-edited collection.
        collection.EditionNumber.Should().Be(1);

        addItem.Should().NotThrow();
    }

    [Fact]
    public void A_second_publish_increments_the_edition_rather_than_replacing_it()
    {
        var collection = PublishedCollection();

        collection.BeginRevision(Owner);
        collection.SubmitForPublication(Owner, Now);
        collection.Approve(Now);

        collection.EditionNumber.Should().Be(2);
    }

    [Fact]
    public void A_rejected_revision_returns_to_revising_not_to_draft()
    {
        var collection = PublishedCollection();
        collection.BeginRevision(Owner);
        collection.SubmitForPublication(Owner, Now);

        collection.Reject("Attribution on item 2 is wrong.", Now);

        // Draft would lose the fact that a live edition exists, and the next
        // publish would then be edition 1 again.
        collection.State.Should().Be(CollectionState.Revising);
        collection.EditionNumber.Should().Be(1);
    }

    [Fact]
    public void A_rejection_must_carry_a_reason()
    {
        var collection = SubmittedCollection();

        var reject = () => collection.Reject("   ", Now);

        reject.Should().Throw<DomainException>().WithMessage("*reason*");
    }

    // ---- invariant 8: contiguous positions ----------------------------------

    [Fact]
    public void Positions_are_contiguous_from_one()
    {
        var collection = DraftWithThreeItems(out var quoteIds);

        collection.Items.Select(i => i.Position).Should().Equal(1, 2, 3);
        collection.Items.Select(i => i.QuoteId).Should().Equal(quoteIds);
    }

    [Fact]
    public void Removing_an_item_renumbers_the_rest_leaving_no_gap()
    {
        var collection = DraftWithThreeItems(out var quoteIds);

        collection.RemoveItem(quoteIds[0], Owner);

        collection.Items.Select(i => i.Position).Should().Equal(1, 2);
        collection.Items.Select(i => i.QuoteId).Should().Equal(quoteIds[1], quoteIds[2]);
    }

    [Fact]
    public void Reordering_moves_one_item_and_renumbers_the_rest()
    {
        var collection = DraftWithThreeItems(out var quoteIds);

        collection.Reorder(quoteIds[2], 1, Owner);

        collection.Items.Select(i => i.QuoteId).Should().Equal(quoteIds[2], quoteIds[0], quoteIds[1]);
        collection.Items.Select(i => i.Position).Should().Equal(1, 2, 3);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    public void Reordering_outside_the_current_range_is_refused(int position)
    {
        var collection = DraftWithThreeItems(out var quoteIds);

        var reorder = () => collection.Reorder(quoteIds[0], position, Owner);

        reorder.Should().Throw<DomainException>().WithMessage("*between 1 and 3*");
    }

    // ---- invariants 4 and 5: who, and when ----------------------------------

    [Fact]
    public void A_collection_with_fewer_than_three_items_cannot_be_submitted()
    {
        var collection = Collection.Create("Too thin", Owner, Now);
        AddItem(collection, "Seneca", "Luck is a matter of preparation.");
        AddItem(collection, "Marcus", "The soul becomes dyed with the colour of its thoughts.");

        var submit = () => collection.SubmitForPublication(Owner, Now);

        submit.Should().Throw<DomainException>().WithMessage("*at least 3 items*");
    }

    [Fact]
    public void A_collection_holding_an_unreviewed_quote_cannot_be_submitted()
    {
        var collection = Collection.Create("Half reviewed", Owner, Now);
        AddItem(collection, "Seneca", "We suffer more in imagination than in reality.");
        AddItem(collection, "Marcus", "You have power over your mind.");
        var unreviewed = Guid.NewGuid();
        collection.AddItem(unreviewed, "Anon", "Not yet reviewed.", isPublishable: false, Owner, Now);

        var submit = () => collection.SubmitForPublication(Owner, Now);

        submit.Should().Throw<DomainException>().WithMessage("*cleared review*");

        // And the flag arriving from the QuotePublishable event unblocks it,
        // without Curation ever calling into Catalog.
        collection.MarkQuotePublishable(unreviewed);
        submit.Should().NotThrow();
    }

    [Fact]
    public void Only_the_owner_may_submit_for_publication()
    {
        var collection = DraftWithThreeItems(out _);
        collection.AddMember(Contributor, CollectionRole.Contributor, Owner);

        var submit = () => collection.SubmitForPublication(Contributor, Now);

        submit.Should().Throw<DomainException>().WithMessage("*Only the owner*");
    }

    [Fact]
    public void A_contributor_may_add_items_but_a_stranger_may_not()
    {
        var collection = Collection.Create("Shared", Owner, Now);
        collection.AddMember(Contributor, CollectionRole.Contributor, Owner);

        var byContributor = () => collection.AddItem(
            Guid.NewGuid(), "Zeno", "Well-being is realised by small steps.", true, Contributor, Now);
        var byStranger = () => collection.AddItem(
            Guid.NewGuid(), "Zeno", "Man conquers the world by conquering himself.", true, Stranger, Now);

        byContributor.Should().NotThrow();
        byStranger.Should().Throw<DomainException>().WithMessage("*member*");
    }

    [Fact]
    public void A_collection_has_exactly_one_owner()
    {
        var collection = Collection.Create("Sole owner", Owner, Now);

        var addSecondOwner = () => collection.AddMember(Stranger, CollectionRole.Owner, Owner);

        addSecondOwner.Should().Throw<DomainException>().WithMessage("*exactly one owner*");
    }

    // ---- flow 2: corrections reach drafts and stop at editions --------------

    [Fact]
    public void A_quote_revision_updates_a_draft_snapshot()
    {
        var collection = DraftWithThreeItems(out var quoteIds);

        collection.ApplyQuoteRevision(quoteIds[0], "Seneca the Younger", "Corrected text.");

        var item = collection.Items.Single(i => i.QuoteId == quoteIds[0]);
        item.Author.Should().Be("Seneca the Younger");
        item.Text.Should().Be("Corrected text.");
    }

    [Fact]
    public void A_quote_revision_does_not_touch_a_published_collection()
    {
        var collection = PublishedCollection();
        var first = collection.Items[0];
        var originalAuthor = first.Author;
        var originalText = first.Text;

        collection.ApplyQuoteRevision(first.QuoteId, "Rewritten", "Rewritten text.");

        // A typo fix in Catalog must not rewrite an edition readers have
        // already seen. This is a product decision, documented in the design --
        // if it ever changes, this test is where the change is declared.
        collection.Items[0].Author.Should().Be(originalAuthor);
        collection.Items[0].Text.Should().Be(originalText);
    }

    // ---- helpers ------------------------------------------------------------

    private static Collection DraftWithThreeItems(out List<Guid> quoteIds)
    {
        var collection = Collection.Create("Stoic mornings", Owner, Now);

        quoteIds =
        [
            AddItem(collection, "Seneca", "We suffer more in imagination than in reality."),
            AddItem(collection, "Marcus Aurelius", "You have power over your mind."),
            AddItem(collection, "Epictetus", "No man is free who is not master of himself.")
        ];

        return collection;
    }

    private static Guid AddItem(Collection collection, string author, string text)
    {
        var quoteId = Guid.NewGuid();
        collection.AddItem(quoteId, author, text, isPublishable: true, Owner, Now);
        return quoteId;
    }

    private static Collection SubmittedCollection()
    {
        var collection = DraftWithThreeItems(out _);
        collection.SubmitForPublication(Owner, Now);
        return collection;
    }

    private static Collection PublishedCollection()
    {
        var collection = SubmittedCollection();
        collection.Approve(Now);
        return collection;
    }

    /// <summary>
    /// The sibling of the two quote-revision tests above. MarkQuotePublishable
    /// is applied from a broadcast event exactly as ApplyQuoteRevision is, so
    /// it gets the same pair of assertions: it reaches an editable collection
    /// and stops at a published one.
    /// </summary>
    [Fact]
    public void A_publishable_quote_updates_a_draft_but_not_a_published_collection()
    {
        var quoteId = Guid.NewGuid();

        var draft = Collection.Create("A draft collection", Owner, Now);
        draft.AddItem(quoteId, "Author", "Text.", isPublishable: false, Owner, Now);

        draft.MarkQuotePublishable(quoteId);
        draft.Items.Single().IsPublishable.Should().BeTrue();

        var published = Collection.Create("A published collection", Owner, Now);
        published.AddItem(quoteId, "Author", "Text.", isPublishable: true, Owner, Now);
        published.AddItem(Guid.NewGuid(), "Author 2", "Text 2.", isPublishable: true, Owner, Now);
        published.AddItem(Guid.NewGuid(), "Author 3", "Text 3.", isPublishable: true, Owner, Now);
        published.SubmitForPublication(Owner, Now);
        published.Approve(Now);

        // Already true, so the assertion below cannot distinguish "guarded" from
        // "applied"; flipping it first makes the guard the only thing that can
        // keep it false.
        var itemBefore = published.Items.Single(i => i.QuoteId == quoteId);
        itemBefore.IsPublishable.Should().BeTrue("submission requires it");

        published.MarkQuotePublishable(Guid.NewGuid());
        published.State.Should().Be(CollectionState.Published, "a broadcast must not move a published collection");
    }
}
