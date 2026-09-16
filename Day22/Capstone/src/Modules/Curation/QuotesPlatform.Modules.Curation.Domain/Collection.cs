using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Curation.Domain;

/// <summary>
/// THE CORE AGGREGATE. The consistency boundary for curating and publishing a
/// collection of quotes.
///
/// Three of its invariants are carried forward unchanged from
/// Day7/piece2/QuotesApi/Models/Collection.cs -- the name length, the 50-item
/// cap, and no duplicate quote. That is deliberate: the capstone is a
/// continuation, and a rewrite that quietly drops rules the earlier days
/// argued for would be a regression dressed as progress.
///
/// What is new is the part that makes this an aggregate rather than a list with
/// a name attached:
///
///   - items are FROZEN while the collection is in review, so the thing that
///     was reviewed is the thing that gets published;
///   - EditionNumber increases by exactly one per publish and a published
///     edition is immutable, so readers never see a half-edited collection;
///   - positions are contiguous 1..n, so ordering is a domain operation rather
///     than a client-supplied integer that can collide or leave gaps.
/// </summary>
public sealed class Collection : AggregateRoot<Guid>
{
    public const int MinNameLength = 3;
    public const int MaxNameLength = 80;
    public const int MaxItems = 50;

    /// <summary>
    /// A collection of one quote is not a collection. The rule gives publishing
    /// a precondition instead of leaving it to the client to decide what is
    /// worth publishing.
    /// </summary>
    public const int MinItemsToPublish = 3;

    private readonly List<CollectionItem> _items = [];
    private readonly List<CollectionMember> _members = [];

    private Collection()
    {
        Name = null!;
        OwnerId = null!;
    }

    private Collection(string name, string ownerId, DateTimeOffset createdAt)
    {
        Id = Guid.NewGuid();
        Name = ValidateName(name);
        OwnerId = RequireUserId(ownerId, nameof(ownerId));
        State = CollectionState.Draft;
        EditionNumber = 0;
        CreatedAt = createdAt;

        _members.Add(new CollectionMember(OwnerId, CollectionRole.Owner));
    }

    public string Name { get; private set; }

    public string OwnerId { get; private set; }

    public CollectionState State { get; private set; }

    /// <summary>
    /// 0 until first publish, then the number of the live edition. Increases by
    /// exactly one per publish -- never recomputed from a count, because a
    /// deleted edition would then shift every later number.
    /// </summary>
    public int EditionNumber { get; private set; }

    public DateTimeOffset CreatedAt { get; private set; }

    public IReadOnlyList<CollectionItem> Items => _items;

    public IReadOnlyList<CollectionMember> Members => _members;

    public static Collection Create(string name, string ownerId, DateTimeOffset createdAt) =>
        new(name, ownerId, createdAt);

    public void Rename(string name, string actorId)
    {
        RequireOwner(actorId, "rename this collection");
        RequireEditable();

        Name = ValidateName(name);
    }

    public void AddMember(string userId, CollectionRole role, string actorId)
    {
        RequireOwner(actorId, "change membership");

        if (role == CollectionRole.Owner)
            throw new DomainException(
                "A collection has exactly one owner. Transfer ownership instead of adding a second one.");

        if (_members.Any(m => m.UserId == userId))
            throw new DomainException("That user is already a member of this collection.");

        _members.Add(new CollectionMember(userId, role));
    }

    /// <summary>
    /// Contributors may add items, and only while the collection is editable.
    /// Author and text are snapshotted here -- see CollectionItem for why.
    /// </summary>
    public void AddItem(
        Guid quoteId,
        string author,
        string text,
        bool isPublishable,
        string actorId,
        DateTimeOffset addedAt)
    {
        RequireMember(actorId);
        RequireEditable();

        if (_items.Count >= MaxItems)
            throw new DomainException($"A collection cannot contain more than {MaxItems} items.");

        if (_items.Any(i => i.QuoteId == quoteId))
            throw new DomainException("This quote is already in the collection.");

        if (string.IsNullOrWhiteSpace(author) || string.IsNullOrWhiteSpace(text))
            throw new DomainException("A collection item needs both an author and text.");

        _items.Add(new CollectionItem(
            quoteId, author, text, isPublishable, _items.Count + 1, addedAt));
    }

    public void RemoveItem(Guid quoteId, string actorId)
    {
        RequireMember(actorId);
        RequireEditable();

        var item = _items.FirstOrDefault(i => i.QuoteId == quoteId)
            ?? throw new DomainException("That quote is not in this collection.");

        _items.Remove(item);
        Renumber();
    }

    /// <summary>
    /// Moves an item to a 1-based position and renumbers everything else.
    ///
    /// Taking a target position and renumbering, rather than accepting a
    /// Position per item from the client, is what keeps positions contiguous:
    /// two concurrent clients each "setting position 3" cannot produce a
    /// collection with two items at 3 and nothing at 4.
    /// </summary>
    public void Reorder(Guid quoteId, int newPosition, string actorId)
    {
        RequireMember(actorId);
        RequireEditable();

        if (newPosition < 1 || newPosition > _items.Count)
            throw new DomainException(
                $"Position must be between 1 and {_items.Count}.");

        var item = _items.FirstOrDefault(i => i.QuoteId == quoteId)
            ?? throw new DomainException("That quote is not in this collection.");

        _items.Remove(item);
        _items.Insert(newPosition - 1, item);
        Renumber();
    }

    public void SubmitForPublication(string actorId, DateTimeOffset submittedAt)
    {
        RequireOwner(actorId, "submit this collection for publication");

        if (State is not (CollectionState.Draft or CollectionState.Revising))
            throw new DomainException(
                $"A collection in state {State} cannot be submitted for publication.");

        if (_items.Count < MinItemsToPublish)
            throw new DomainException(
                $"A collection needs at least {MinItemsToPublish} items before it can be published.");

        // The sibling of the publishable rule: nothing unreviewed goes out in
        // an edition. Checked here, from the locally-held flag, rather than by
        // calling into Catalog inside the transaction.
        if (_items.Any(i => !i.IsPublishable))
            throw new DomainException(
                "Every quote in the collection must have cleared review before it can be published.");

        State = CollectionState.InReview;

        Raise(new CollectionSubmittedForReview(Id, OwnerId, Name, _items.Count, submittedAt));
    }

    /// <summary>
    /// Called when Moderation approves. Publishes the next edition.
    /// </summary>
    public void Approve(DateTimeOffset approvedAt)
    {
        if (State != CollectionState.InReview)
            throw new DomainException(
                $"Only a collection in review can be approved; this one is {State}.");

        EditionNumber += 1;
        State = CollectionState.Published;

        Raise(new CollectionEditionPublished(Id, EditionNumber, approvedAt));
    }

    /// <summary>
    /// Called when Moderation rejects. Returns the collection to the state it
    /// can be edited in, so the curator can act on the reason.
    /// </summary>
    public void Reject(string reason, DateTimeOffset rejectedAt)
    {
        if (State != CollectionState.InReview)
            throw new DomainException(
                $"Only a collection in review can be rejected; this one is {State}.");

        if (string.IsNullOrWhiteSpace(reason))
            throw new DomainException("A rejection must carry a reason the curator can act on.");

        // Back to Draft if it has never been published, Revising if it has --
        // a rejected revision must not lose the fact that a live edition
        // exists.
        State = EditionNumber == 0 ? CollectionState.Draft : CollectionState.Revising;

        Raise(new CollectionReviewRejected(Id, reason, rejectedAt));
    }

    /// <summary>
    /// Opens a published collection for editing. The live edition keeps serving
    /// until the next one is approved.
    /// </summary>
    public void BeginRevision(string actorId)
    {
        RequireOwner(actorId, "revise this collection");

        if (State != CollectionState.Published)
            throw new DomainException(
                $"Only a published collection can be revised; this one is {State}.");

        State = CollectionState.Revising;
    }

    /// <summary>
    /// Applied from the QuoteRevised integration event.
    ///
    /// A no-op unless the collection is editable, which is the rule that makes
    /// a published edition immutable in practice rather than only in intent: a
    /// correction in Catalog reaches drafts and stops at anything published.
    /// Returning quietly rather than throwing is correct here -- the event is a
    /// broadcast, and "this collection is published" is not a consumer error.
    /// </summary>
    public void ApplyQuoteRevision(Guid quoteId, string author, string text)
    {
        if (State is not (CollectionState.Draft or CollectionState.Revising))
            return;

        _items.FirstOrDefault(i => i.QuoteId == quoteId)?.RefreshSnapshot(author, text);
    }

    /// <summary>
    /// Applied from the QuotePublishable integration event.
    ///
    /// Guarded on state for the same reason ApplyQuoteRevision is, and the
    /// symmetry is the point rather than the behaviour: both are applied by
    /// handlers sharing GetEditableByQuoteIdAsync, so both are already
    /// protected by that query. Protecting only one of them in the aggregate
    /// meant the pair relied on the query in one case and on the query AND the
    /// aggregate in the other, and the whole argument for the double guard is
    /// that a later widening of the query must not be able to break the rule.
    /// A guard on one sibling and not the other is an invitation to assume the
    /// query is enough.
    ///
    /// In practice this returns early for nothing today: a collection cannot
    /// reach InReview or Published holding a quote that has not cleared review,
    /// because SubmitForPublication refuses it. That is exactly why it is
    /// cheap to be consistent here.
    /// </summary>
    public void MarkQuotePublishable(Guid quoteId)
    {
        if (State is not (CollectionState.Draft or CollectionState.Revising))
            return;

        _items.FirstOrDefault(i => i.QuoteId == quoteId)?.MarkPublishable();
    }

    private void Renumber()
    {
        for (var i = 0; i < _items.Count; i++)
        {
            _items[i].MoveTo(i + 1);
        }
    }

    /// <summary>
    /// The freeze. Items and the name may only change while the collection is
    /// a draft or a revision -- never in review, where changing them would
    /// mean approving one thing and publishing another, and never once
    /// published, where the edition is immutable.
    /// </summary>
    private void RequireEditable()
    {
        if (State is CollectionState.Draft or CollectionState.Revising)
            return;

        var why = State switch
        {
            CollectionState.InReview =>
                "It is in review: the collection that was submitted has to be the collection that gets published.",
            CollectionState.Published =>
                "It is published: call BeginRevision to work on the next edition while this one keeps serving.",
            CollectionState.Archived => "It is archived.",
            _ => $"It is {State}."
        };

        throw new DomainException($"This collection cannot be changed. {why}");
    }

    private void RequireOwner(string actorId, string action)
    {
        if (RequireUserId(actorId, nameof(actorId)) != OwnerId)
            throw new DomainException($"Only the owner may {action}.");
    }

    private void RequireMember(string actorId)
    {
        if (!_members.Any(m => m.UserId == RequireUserId(actorId, nameof(actorId))))
            throw new DomainException("Only a member of this collection may change its items.");
    }

    private static string ValidateName(string name)
    {
        if (string.IsNullOrWhiteSpace(name)
            || name.Trim().Length < MinNameLength
            || name.Trim().Length > MaxNameLength)
        {
            throw new DomainException(
                $"Collection name must be between {MinNameLength} and {MaxNameLength} characters.");
        }

        return name.Trim();
    }

    private static string RequireUserId(string userId, string parameterName) =>
        string.IsNullOrWhiteSpace(userId)
            ? throw new DomainException($"A user id is required ({parameterName}).")
            : userId;
}
