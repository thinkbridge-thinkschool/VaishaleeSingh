using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;

namespace QuotesPlatform.CompositionTests;

/// <summary>
/// THE CONTAINER IS A PLACE TWO MODULES CAN COLLIDE WITHOUT THE COMPILER
/// NOTICING, so it gets tests of its own.
///
/// Day 29 shipped two defects that a build and every existing test were blind
/// to, and both of them are the same shape: something that only goes wrong
/// once the modules are composed together.
///
///   * Every module registered its own implementation against the ONE shared
///     IIntegrationEventPublisher. The container keeps the last registration,
///     so three modules silently wrote their outbox rows into a fourth
///     module's DbContext -- which their own SaveChangesAsync never saved.
///     No exception, no failing test, a 200 response, and no event.
///   * Every outbox relay built its LockOwner with `[..64]`, which throws when
///     the string is shorter than 64 -- always. As a hosted service that threw
///     while the host was starting, so the process never listened.
///
/// Neither is catchable by reading a diff, and neither is catchable by testing
/// a module on its own. Both are caught below.
/// </summary>
public class ModuleCompositionTests
{
    // Never opened: these tests compose and construct, they do not connect.
    private const string ConnectionString =
        "Server=(local);Database=QuotesPlatform.Composition;Trusted_Connection=True;TrustServerCertificate=True;";

    private const string ServiceBusNamespace = "composition-tests.servicebus.windows.net";

    /// <summary>The same four calls, in the same order, that Program.cs makes.</summary>
    private static ServiceCollection Compose()
    {
        var services = new ServiceCollection();
        services.AddLogging();

        services.AddCatalogModule(ConnectionString, ServiceBusNamespace);
        services.AddCurationModule(ConnectionString, ServiceBusNamespace);
        services.AddPublishingModule(ConnectionString, ServiceBusNamespace);
        services.AddModerationModule(ConnectionString, ServiceBusNamespace);

        return services;
    }

    [Fact]
    public void No_service_type_is_registered_by_more_than_one_module()
    {
        var violations = Compose()
            // Keyed descriptors throw on ImplementationType, and they cannot
            // collide anyway: each module keys against its own handler type.
            .Where(descriptor => !descriptor.IsKeyedService && descriptor.ImplementationType is not null)
            .GroupBy(descriptor => descriptor.ServiceType)
            // IHostedService is the one service type that is MEANT to carry an
            // implementation from every module: it is resolved as a collection,
            // so nothing is dropped. Every other shared service type is
            // resolved singly, and a second registration silently wins.
            .Where(group => group.Key != typeof(IHostedService))
            .Select(group => new
            {
                ServiceType = group.Key,
                Modules = group
                    .Select(descriptor => ModuleOf(descriptor.ImplementationType!))
                    .Where(module => module is not null)
                    .Distinct()
                    .ToList()
            })
            .Where(entry => entry.Modules.Count > 1)
            .Select(entry => $"{entry.ServiceType.Name} <- {string.Join(", ", entry.Modules)}")
            .ToList();

        violations.Should().BeEmpty(
            "a service type two modules both implement resolves to whichever module the Host registered last");
    }

    [Fact]
    public async Task Every_hosted_service_can_be_constructed()
    {
        // `await using`, not `using`, and the difference is not cosmetic: the
        // container holds a ServiceBusClient, which implements IAsyncDisposable
        // and NOT IDisposable. Disposing a provider that holds one synchronously
        // throws -- "type only implements IAsyncDisposable. Use DisposeAsync to
        // dispose the container." The Host never meets this because
        // WebApplication disposes asynchronously; a test reaching for `using`
        // out of habit does, and it fails AFTER every assertion has passed,
        // which reads like a broken assertion and is not one.
        await using var provider = Compose().BuildServiceProvider(validateScopes: true);

        // Resolving the collection CONSTRUCTS each one, which is the whole
        // point: this is the assertion the `[..64]` crash failed.
        var hostedServiceNames = provider.GetServices<IHostedService>()
            .Select(service => service.GetType().Name)
            .ToList();

        hostedServiceNames.Should().Contain(new[]
        {
            nameof(CatalogOutboxRelayService),
            nameof(CurationOutboxRelayService),
            nameof(ModerationOutboxRelayService),
            nameof(PublishingOutboxRelayService),
            nameof(CurationServiceBusConsumerHost),
            nameof(ModerationServiceBusConsumerHost),
            nameof(PublishingServiceBusConsumerHost)
        });
    }

    [Fact]
    public async Task Each_module_resolves_its_own_outbox_publisher()
    {
        // Async here too, though this test passed while the one above did not:
        // it resolves only scoped publishers, so the singleton ServiceBusClient
        // was never constructed and never registered for disposal. That is luck,
        // not a property -- one added assertion that touches a hosted service
        // and this fails the same way.
        await using var provider = Compose().BuildServiceProvider(validateScopes: true);
        await using var scope = provider.CreateAsyncScope();
        var services = scope.ServiceProvider;

        ModuleOf(services.GetRequiredService<ICatalogIntegrationEventPublisher>().GetType())
            .Should().Be("Catalog");
        ModuleOf(services.GetRequiredService<ICurationIntegrationEventPublisher>().GetType())
            .Should().Be("Curation");
        ModuleOf(services.GetRequiredService<IModerationIntegrationEventPublisher>().GetType())
            .Should().Be("Moderation");
        ModuleOf(services.GetRequiredService<IPublishingIntegrationEventPublisher>().GetType())
            .Should().Be("Publishing");
    }

    /// <summary>"Curation" for QuotesPlatform.Modules.Curation.Infrastructure; null for anything else.</summary>
    private static string? ModuleOf(Type type)
    {
        const string prefix = "QuotesPlatform.Modules.";

        var candidate = type.Namespace;
        if (candidate is null || !candidate.StartsWith(prefix, StringComparison.Ordinal))
            return null;

        var rest = candidate[prefix.Length..];
        var dot = rest.IndexOf('.');

        return dot < 0 ? rest : rest[..dot];
    }
}
