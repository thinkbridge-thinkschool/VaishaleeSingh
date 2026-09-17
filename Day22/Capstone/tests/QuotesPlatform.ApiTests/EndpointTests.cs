using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace QuotesPlatform.ApiTests;

/// <summary>
/// The HTTP surface. Everything asserted here was untested until today: status
/// codes, the Location header, model binding, and the DomainException-to-400
/// mapping that every endpoint in the solution relies on.
///
/// WHAT THESE DELIBERATELY DO NOT COVER. The hosted services are removed, so
/// no outbox relay runs and no consumer runs. A collection can be submitted
/// here but it can never become Published, because that needs Moderation to
/// receive the event, open a review, and Curation to receive the approval --
/// three broker hops that have no HTTP surface at all.
///
/// That is the correct division rather than a shortcoming. The cross-module
/// continuation is covered by QuotesPlatform.IntegrationTests (handlers against
/// a real database) and by happy-path.ps1 (the whole thing against a real
/// broker). Trying to make one layer prove all three is how a test suite ends
/// up slow and still not trusted.
/// </summary>
[Collection(CapstoneApiCollection.Name)]
public sealed class EndpointTests(CapstoneApiFixture fixture) : IAsyncLifetime
{
    private CapstoneApiFactory _host = null!;
    private HttpClient _client = null!;

    public async Task InitializeAsync()
    {
        _host = await fixture.CreateHostAsync();
        _client = _host.CreateClient();
    }

    public async Task DisposeAsync()
    {
        _client.Dispose();
        await _host.DisposeAsync();
    }

    // ---- the factory itself -------------------------------------------------

    /// <summary>
    /// The guard on the guard. If a namespace is ever renamed, the filter in
    /// CapstoneApiFactory silently stops matching and eight background services
    /// come back -- each reaching for Azure from a test run. The symptom would
    /// be a slow, intermittently failing suite rather than an obvious error, so
    /// it is asserted rather than assumed.
    /// </summary>
    [Fact]
    public void No_module_background_service_runs_under_the_test_host()
    {
        _host.RunningHostedServices()
            .Should().NotContain(name => name.Contains("OutboxRelay", StringComparison.Ordinal))
            .And.NotContain(name => name.Contains("ServiceBusConsumerHost", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Health_answers()
    {
        // Also proves the request pipeline is actually running -- the thing
        // RemoveAll<IHostedService>() would have quietly broken.
        var response = await _client.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    // ---- created, and where it says it was created --------------------------

    [Fact]
    public async Task Creating_a_collection_returns_201_and_a_usable_Location()
    {
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = "A collection created over HTTP",
            ownerId = "curator-1"
        });

        response.StatusCode.Should().Be(HttpStatusCode.Created);
        response.Headers.Location.Should().NotBeNull();

        // A Location header nobody follows is a header nobody has checked.
        var followed = await _client.GetAsync(response.Headers.Location);
        followed.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task Submitting_a_quote_returns_201_and_it_is_not_publishable_yet()
    {
        var response = await _client.PostAsJsonAsync("/api/quotes", new
        {
            author = "Author 1",
            text = "Quote text number 1.",
            submittedByUserId = "curator-1"
        });

        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var quote = await response.Content.ReadFromJsonAsync<QuoteResponse>();
        quote!.IsPublishable.Should().BeFalse(
            "only an approved review makes a quote publishable, and no consumer runs here");
    }

    // ---- a domain failure is a 400, not a 500 -------------------------------

    /// <summary>
    /// The single most valuable assertion in this file. Every endpoint catches
    /// DomainException and maps it to 400; nothing verified that the mapping
    /// works, and an unmapped domain rule surfaces to a caller as a 500 -- an
    /// outage-shaped response to an ordinary validation failure.
    /// </summary>
    [Fact]
    public async Task A_broken_domain_rule_is_a_400_with_a_reason()
    {
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = "ab",              // Collection.MinNameLength is 3
            ownerId = "curator-1"
        });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var body = await response.Content.ReadAsStringAsync();
        body.Should().Contain("3", "the message should tell the caller what the rule is");
    }

    [Fact]
    public async Task Submitting_a_collection_with_too_few_items_is_a_400()
    {
        var collectionId = await CreateCollectionAsync();

        var response = await _client.PostAsJsonAsync(
            $"/api/collections/{collectionId}/submit", new { actorId = "curator-1" });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest,
            "Collection.MinItemsToPublish is 3 and this one has none");
    }

    [Fact]
    public async Task Acting_on_a_collection_you_do_not_own_is_refused()
    {
        var collectionId = await CreateCollectionAsync();

        var response = await _client.PatchAsJsonAsync(
            $"/api/collections/{collectionId}",
            new { name = "Renamed by a stranger", actorId = "not-the-owner" });

        // NOTE: this is the aggregate refusing, not authentication. Anyone can
        // still claim to BE curator-1 by putting that string in the body --
        // see Day31/docs/day31-threat-model.md and ADR-0003.
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // ---- not found, and bound correctly -------------------------------------

    [Fact]
    public async Task A_collection_that_does_not_exist_is_a_404()
    {
        var response = await _client.GetAsync($"/api/collections/{Guid.NewGuid()}");

        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    /// <summary>
    /// The subject query parameter was added on Day 30 because the lookup had
    /// hardcoded ReviewSubject.Collection and returned 404 for a quote review
    /// that was open. Nothing tested that it binds -- and an optional parameter
    /// that silently fails to bind reproduces the original bug exactly.
    /// </summary>
    [Theory]
    [InlineData("")]
    [InlineData("?subject=Collection")]
    [InlineData("?subject=quote")]          // case-insensitive by design
    public async Task The_review_lookup_binds_its_subject(string query)
    {
        var response = await _client.GetAsync($"/api/reviews/by-subject/{Guid.NewGuid()}{query}");

        // 404 because no review exists -- the point is that it is NOT a 400 or
        // a 500, so the value bound and the handler ran.
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    [Fact]
    public async Task An_unrecognised_review_subject_is_a_400_rather_than_a_silent_default()
    {
        var response = await _client.GetAsync(
            $"/api/reviews/by-subject/{Guid.NewGuid()}?subject=Sandwich");

        // Falling back to Collection would return 404 for a review that exists
        // under another subject, which is the most confusing answer available.
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // ---- the longest sequence HTTP alone can express ------------------------

    [Fact]
    public async Task A_collection_can_be_filled_and_submitted_over_HTTP()
    {
        var collectionId = await CreateCollectionAsync();

        for (var i = 1; i <= 3; i++)
        {
            var add = await _client.PostAsJsonAsync($"/api/collections/{collectionId}/items", new
            {
                quoteId = Guid.NewGuid(),
                author = $"Author {i}",
                text = $"Quote text number {i}.",
                isPublishable = true,
                actorId = "curator-1"
            });

            add.StatusCode.Should().Be(HttpStatusCode.OK);
        }

        var submit = await _client.PostAsJsonAsync(
            $"/api/collections/{collectionId}/submit", new { actorId = "curator-1" });

        submit.StatusCode.Should().Be(HttpStatusCode.OK);

        var collection = await submit.Content.ReadFromJsonAsync<CollectionResponse>();
        collection!.State.Should().Be("InReview");
        collection.Items.Should().HaveCount(3);

        // And it stops here. Publishing needs Moderation to open a review over
        // the broker, which no HTTP call can trigger.
    }

    [Fact]
    public async Task Items_cannot_be_added_once_the_collection_is_in_review()
    {
        var collectionId = await CreateCollectionAsync();

        for (var i = 1; i <= 3; i++)
        {
            await _client.PostAsJsonAsync($"/api/collections/{collectionId}/items", new
            {
                quoteId = Guid.NewGuid(),
                author = $"Author {i}",
                text = $"Quote text number {i}.",
                isPublishable = true,
                actorId = "curator-1"
            });
        }

        await _client.PostAsJsonAsync($"/api/collections/{collectionId}/submit", new { actorId = "curator-1" });

        var late = await _client.PostAsJsonAsync($"/api/collections/{collectionId}/items", new
        {
            quoteId = Guid.NewGuid(),
            author = "Author 4",
            text = "Added after submission.",
            isPublishable = true,
            actorId = "curator-1"
        });

        // The freeze, reaching a caller as a 400: the collection that was
        // submitted has to be the collection that gets published.
        late.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    // ---- helpers ------------------------------------------------------------

    private async Task<Guid> CreateCollectionAsync()
    {
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = $"Collection {Guid.NewGuid():N}"[..40],
            ownerId = "curator-1"
        });

        response.EnsureSuccessStatusCode();

        var created = await response.Content.ReadFromJsonAsync<CollectionResponse>();
        return created!.Id;
    }

    // Local mirrors of the response shapes. Deliberately NOT the production
    // records: a test that deserialises into the type the endpoint serialises
    // from cannot notice a renamed field, because both sides move together.
    private sealed record CollectionResponse(
        Guid Id, string Name, string OwnerId, string State, int EditionNumber,
        IReadOnlyList<CollectionItemResponse> Items);

    private sealed record CollectionItemResponse(
        int Position, Guid QuoteId, string Author, string Text, bool IsPublishable);

    private sealed record QuoteResponse(
        Guid Id, string Author, string Text, bool IsPublishable);
}
