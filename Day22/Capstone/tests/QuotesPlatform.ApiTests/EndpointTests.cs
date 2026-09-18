using System.Net;
using System.Net.Http.Json;
using FluentAssertions;

namespace QuotesPlatform.ApiTests;

/// <summary>
/// The HTTP surface: status codes, the Location header, model binding, the
/// DomainException-to-400 mapping every endpoint relies on -- and, from Day 32,
/// that the acting user comes from the token rather than the request body.
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
///
/// NOR DO THEY VALIDATE A REAL TOKEN. The test host swaps JwtBearer for a
/// scheme that turns a header into a principal -- see TestAuthenticationHandler.
/// Whether a signature verifies is Microsoft's library's job; what is ours is
/// that the endpoints read the actor from the principal.
/// </summary>
[Collection(CapstoneApiCollection.Name)]
public sealed class EndpointTests(CapstoneApiFixture fixture) : IAsyncLifetime
{
    private const string Owner = "curator-1";
    private const string Stranger = "curator-2";

    private CapstoneApiFactory _host = null!;
    private HttpClient _client = null!;       // authenticated as Owner
    private HttpClient _anonymous = null!;    // no token at all

    public async Task InitializeAsync()
    {
        _host = await fixture.CreateHostAsync();
        _client = _host.CreateClientAs(Owner);
        _anonymous = _host.CreateClient();
    }

    public async Task DisposeAsync()
    {
        _client.Dispose();
        _anonymous.Dispose();
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

    // ---- authentication -----------------------------------------------------

    /// <summary>
    /// THE MOST IMPORTANT TEST ADDED ON DAY 32, and the one that makes every
    /// other authorisation assertion in this file mean something.
    ///
    /// A test authentication handler that always succeeds turns the whole suite
    /// green while proving nothing -- the middleware could be missing entirely.
    /// This test can only pass if an anonymous request is genuinely refused, so
    /// it fails the moment that handler starts issuing a principal for free.
    ///
    /// It also covers the fallback policy itself: 401 here means EVERY endpoint
    /// is protected by default, not only the ones somebody remembered.
    /// </summary>
    [Theory]
    [InlineData("POST", "/api/collections")]
    [InlineData("POST", "/api/quotes")]
    [InlineData("GET", "/api/collections/11111111-1111-1111-1111-111111111111")]
    public async Task Anonymous_requests_are_refused(string method, string path)
    {
        var request = new HttpRequestMessage(new HttpMethod(method), path);
        if (method == "POST")
            request.Content = JsonContent.Create(new { name = "Anything", author = "A", text = "T" });

        var response = await _anonymous.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized,
            "every endpoint but /health is covered by the authorization fallback policy");
    }

    [Fact]
    public async Task Health_answers_without_a_token()
    {
        // The single AllowAnonymous endpoint. Container Apps probes it before a
        // revision takes traffic, and a probe cannot carry a token, so this
        // failing would mean a deployment that never goes healthy.
        //
        // Also proves the request pipeline is actually running -- the thing
        // RemoveAll<IHostedService>() would have quietly broken.
        var response = await _anonymous.GetAsync("/health");

        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    /// <summary>
    /// The owner is whoever CALLED, not whoever the body named. Until Day 32
    /// the request carried an ownerId, so a caller could create a collection
    /// owned by somebody else -- and under the old rules anyone could then act
    /// as that owner.
    /// </summary>
    [Fact]
    public async Task The_owner_is_the_caller_and_the_body_cannot_say_otherwise()
    {
        // ownerId is sent deliberately. It is no longer part of the contract,
        // so it must be ignored rather than honoured -- this asserts that a
        // stale client cannot still choose an owner.
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = "A collection created over HTTP",
            ownerId = Stranger
        });

        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var created = await response.Content.ReadFromJsonAsync<CollectionResponse>();
        created!.OwnerId.Should().Be(Owner, "the owner comes from the token, not the payload");
    }

    // ---- created, and where it says it was created --------------------------

    [Fact]
    public async Task Creating_a_collection_returns_201_and_a_usable_Location()
    {
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = "A collection created over HTTP"
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
            text = "Quote text number 1."
        });

        response.StatusCode.Should().Be(HttpStatusCode.Created);

        var quote = await response.Content.ReadFromJsonAsync<QuoteResponse>();
        quote!.IsPublishable.Should().BeFalse(
            "only an approved review makes a quote publishable, and no consumer runs here");
        quote.SubmittedByUserId.Should().Be(Owner,
            "the submitter is the caller -- author is the person being quoted, which is different");
    }

    // ---- a domain failure is a 400, not a 500 -------------------------------

    /// <summary>
    /// Every endpoint catches DomainException and maps it to 400; nothing
    /// verified that the mapping works, and an unmapped domain rule surfaces to
    /// a caller as a 500 -- an outage-shaped response to an ordinary validation
    /// failure.
    /// </summary>
    [Fact]
    public async Task A_broken_domain_rule_is_a_400_with_a_reason()
    {
        var response = await _client.PostAsJsonAsync("/api/collections", new
        {
            name = "ab"              // Collection.MinNameLength is 3
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
            $"/api/collections/{collectionId}/submit", new { });

        response.StatusCode.Should().Be(HttpStatusCode.BadRequest,
            "Collection.MinItemsToPublish is 3 and this one has none");
    }

    /// <summary>
    /// This assertion changed meaning on Day 32 and is worth reading twice.
    ///
    /// Before: it proved the aggregate compared two strings, both of which the
    /// caller supplied -- anyone could pass the check by typing the owner's id.
    /// Now the two identities are two different authenticated callers, so it
    /// proves what it always looked like it proved.
    /// </summary>
    [Fact]
    public async Task Acting_on_a_collection_you_do_not_own_is_refused()
    {
        var collectionId = await CreateCollectionAsync();

        using var stranger = _host.CreateClientAs(Stranger);
        var response = await stranger.PatchAsJsonAsync(
            $"/api/collections/{collectionId}",
            new { name = "Renamed by a stranger" });

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
                isPublishable = true
            });

            add.StatusCode.Should().Be(HttpStatusCode.OK);
        }

        var submit = await _client.PostAsJsonAsync(
            $"/api/collections/{collectionId}/submit", new { });

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
                isPublishable = true
            });
        }

        await _client.PostAsJsonAsync($"/api/collections/{collectionId}/submit", new { });

        var late = await _client.PostAsJsonAsync($"/api/collections/{collectionId}/items", new
        {
            quoteId = Guid.NewGuid(),
            author = "Author 4",
            text = "Added after submission.",
            isPublishable = true
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
            name = $"Collection {Guid.NewGuid():N}"[..40]
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
        Guid Id, string Author, string Text, bool IsPublishable, string? SubmittedByUserId);
}
