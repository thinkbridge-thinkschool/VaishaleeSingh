using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using QuotesApi.Extensions;
using QuotesApi.Models;
using QuotesApi.Services;

namespace Quotes.Tests.Integration;

/// <summary>
/// Day 27. Proves that one user cannot reach another user's collections.
///
/// WHY THIS FILE EXISTS, STATED PLAINLY: the security pass found that three of
/// the five collection endpoints had no ownership check at all. Any
/// authenticated caller could read another user's collection, add a quote to
/// it, or remove one from it, simply by using its id — and integer ids make
/// that a loop rather than an attack. The whole suite passed while that was
/// true, because every existing test acts as a single user. A rule that no
/// test exercises is a rule that survives until somebody deletes it.
///
/// Each test here fails against the code as it stood before the fix. That is
/// the property that makes them worth having: they are not describing what the
/// code does, they are describing what an attacker must not be able to do.
///
/// The positive control at the bottom matters as much as the rest. Without it,
/// a change that broke collections for their OWNER would leave every test in
/// this file green — denying everybody is not security, it is an outage.
/// </summary>
public class CollectionOwnershipTests : IAsyncLifetime
{
    private QuotesApiFactory _factory = null!;
    private HttpClient _client = null!;

    public async Task InitializeAsync()
    {
        _factory = new QuotesApiFactory();
        _client = _factory.CreateClient();
        await Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        _client?.Dispose();
        await _factory.DisposeAsync();
    }

    private async Task<string> CreateUserAsync()
    {
        using var scope = _factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<QuotesApi.Data.QuotesDbContext>();
        var authService = scope.ServiceProvider.GetRequiredService<IAuthService>();

        var user = new User
        {
            Email = $"owner-{Guid.NewGuid():N}@example.com",
            PasswordHash = "unused-in-these-tests",
            CreatedAt = _factory.Clock.UtcNow.UtcDateTime
        };
        db.Users.Add(user);
        await db.SaveChangesAsync();

        return authService.GenerateAccessToken(user);
    }

    private static HttpRequestMessage Authed(HttpMethod method, string url, string token)
    {
        var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return request;
    }

    private async Task<int> CreateCollectionAsync(string token)
    {
        var request = Authed(HttpMethod.Post, "/api/collections", token);
        request.Content = JsonContent.Create(new CreateCollectionRequest("Owner's collection"));
        var response = await _client.SendAsync(request);
        response.StatusCode.Should().Be(HttpStatusCode.Created);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        return json.GetProperty("id").GetInt32();
    }

    private async Task<int> CreateQuoteAsync(string token)
    {
        var request = Authed(HttpMethod.Post, "/api/quotes", token);
        request.Content = JsonContent.Create(new CreateQuoteRequest("Ada Lovelace", "That brain of mine is something more than merely mortal."));
        var response = await _client.SendAsync(request);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        return json.GetProperty("id").GetInt32();
    }

    // -----------------------------------------------------------------------
    // A stranger must not be able to read
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Reading_another_users_collection_returns_404()
    {
        var owner = await CreateUserAsync();
        var stranger = await CreateUserAsync();
        var collectionId = await CreateCollectionAsync(owner);

        var response = await _client.SendAsync(
            Authed(HttpMethod.Get, $"/api/collections/{collectionId}", stranger));

        // 404 rather than 403, and the choice is deliberate: a read is the
        // operation an attacker uses to enumerate, and distinguishing "exists,
        // not yours" from "does not exist" hands them a map of which ids are
        // real. The whole-collection delete below answers 403 instead, because
        // there the caller supplied an id they already believe is theirs.
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);
    }

    // -----------------------------------------------------------------------
    // A stranger must not be able to write
    // -----------------------------------------------------------------------

    [Fact]
    public async Task Adding_an_item_to_another_users_collection_is_forbidden()
    {
        var owner = await CreateUserAsync();
        var stranger = await CreateUserAsync();
        var collectionId = await CreateCollectionAsync(owner);
        var quoteId = await CreateQuoteAsync(stranger);

        var request = Authed(HttpMethod.Post, $"/api/collections/{collectionId}/items", stranger);
        request.Content = JsonContent.Create(new AddCollectionItemRequest(quoteId));
        var response = await _client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Removing_an_item_from_another_users_collection_is_forbidden()
    {
        var owner = await CreateUserAsync();
        var stranger = await CreateUserAsync();
        var collectionId = await CreateCollectionAsync(owner);
        var quoteId = await CreateQuoteAsync(owner);

        // The owner puts a quote in, as they are entitled to.
        var add = Authed(HttpMethod.Post, $"/api/collections/{collectionId}/items", owner);
        add.Content = JsonContent.Create(new AddCollectionItemRequest(quoteId));
        (await _client.SendAsync(add)).IsSuccessStatusCode.Should().BeTrue();

        var response = await _client.SendAsync(
            Authed(HttpMethod.Delete, $"/api/collections/{collectionId}/items/{quoteId}", stranger));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Deleting_another_users_collection_is_forbidden()
    {
        var owner = await CreateUserAsync();
        var stranger = await CreateUserAsync();
        var collectionId = await CreateCollectionAsync(owner);

        var response = await _client.SendAsync(
            Authed(HttpMethod.Delete, $"/api/collections/{collectionId}", stranger));

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
    }

    [Fact]
    public async Task Another_users_collection_does_not_appear_in_the_list()
    {
        var owner = await CreateUserAsync();
        var stranger = await CreateUserAsync();
        await CreateCollectionAsync(owner);

        var response = await _client.SendAsync(
            Authed(HttpMethod.Get, "/api/collections", stranger));

        response.StatusCode.Should().Be(HttpStatusCode.OK);
        var json = await response.Content.ReadFromJsonAsync<JsonElement>();
        json.GetArrayLength().Should().Be(0);
    }

    // -----------------------------------------------------------------------
    // The positive control: the owner must still be able to do all of it
    // -----------------------------------------------------------------------

    [Fact]
    public async Task The_owner_can_read_add_remove_and_delete_their_own_collection()
    {
        var owner = await CreateUserAsync();
        var collectionId = await CreateCollectionAsync(owner);
        var quoteId = await CreateQuoteAsync(owner);

        var read = await _client.SendAsync(
            Authed(HttpMethod.Get, $"/api/collections/{collectionId}", owner));
        read.StatusCode.Should().Be(HttpStatusCode.OK);

        var add = Authed(HttpMethod.Post, $"/api/collections/{collectionId}/items", owner);
        add.Content = JsonContent.Create(new AddCollectionItemRequest(quoteId));
        (await _client.SendAsync(add)).StatusCode.Should().Be(HttpStatusCode.OK);

        var remove = await _client.SendAsync(
            Authed(HttpMethod.Delete, $"/api/collections/{collectionId}/items/{quoteId}", owner));
        remove.StatusCode.Should().Be(HttpStatusCode.NoContent);

        var delete = await _client.SendAsync(
            Authed(HttpMethod.Delete, $"/api/collections/{collectionId}", owner));
        delete.StatusCode.Should().Be(HttpStatusCode.NoContent);
    }
}
