using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;
using CatalogHandler = QuotesPlatform.Modules.Catalog.Infrastructure.IIntegrationEventHandler;
using CurationHandler = QuotesPlatform.Modules.Curation.Infrastructure.IIntegrationEventHandler;
using ModerationHandler = QuotesPlatform.Modules.Moderation.Infrastructure.IIntegrationEventHandler;
using PublishingHandler = QuotesPlatform.Modules.Publishing.Infrastructure.IIntegrationEventHandler;

// The four namespace imports above bring in AddCatalogModule and friends.
// The three aliases stay because each module declares its OWN
// IIntegrationEventHandler in its own namespace, so the bare name is ambiguous
// the moment more than one of those namespaces is imported -- which is the
// module boundary working exactly as intended, and the reason a test spanning
// all four modules has to name them apart.

namespace QuotesPlatform.CompositionTests;

/// <summary>
/// A HANDLER NOBODY HAS RUN IS A HANDLER NOBODY HAS RUN, and until there are
/// integration tests against a real database that is exactly what every
/// consumer in this solution is. These are the cheapest possible substitute:
/// they prove each handler is registered, that its key is a real event name,
/// and that it can actually be constructed.
///
/// The key is the part worth testing and the part that looks least like it
/// needs testing. ServiceBusConsumerHost dispatches on the "eventType"
/// application property, which the outbox publisher stamps with the event's
/// CLR type name. A handler registered under a key that does not match one --
/// a typo, a renamed contract, a copied registration line -- is not a
/// compile error and not a runtime error. The message arrives, no handler is
/// found, the host completes it as a no-op, and the ProcessedMessages row
/// records that it was handled. The fact is lost and everything reports
/// success. That is the same failure shape as Day 29's publisher collision and
/// as the subscription filter that did not match, which is three times one
/// mistake has cost a day in two days of building.
/// </summary>
public class IntegrationEventHandlerCompositionTests
{
    private const string ConnectionString =
        "Server=(local);Database=QuotesPlatform.Composition;Trusted_Connection=True;TrustServerCertificate=True;";

    private const string ServiceBusNamespace = "composition-tests.servicebus.windows.net";

    /// <summary>
    /// Four, as of flow 3. Catalog was the last publish-only module: it
    /// announced QuoteSubmitted and QuoteRevised and listened for nothing,
    /// because the one event it cares about (QuoteApproved) had no producer
    /// until today.
    ///
    /// This array was three entries an hour ago and the comment above it said
    /// Day 31 would add the fourth. Flow 3 landed instead, so it did.
    /// </summary>
    private static readonly Type[] HandlerInterfaces =
    [
        typeof(CatalogHandler), typeof(CurationHandler),
        typeof(ModerationHandler), typeof(PublishingHandler)
    ];

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

    /// <summary>Every integration event type the contracts define, by name.</summary>
    private static readonly HashSet<string> KnownEventNames =
        typeof(IIntegrationEvent).Assembly.GetTypes()
            .Where(type => type.IsClass && !type.IsAbstract && typeof(IIntegrationEvent).IsAssignableFrom(type))
            .Select(type => type.Name)
            .ToHashSet(StringComparer.Ordinal);

    [Fact]
    public void Every_handler_is_keyed_to_an_event_the_contracts_actually_define()
    {
        var unknown = Compose()
            .Where(descriptor => descriptor.IsKeyedService && HandlerInterfaces.Contains(descriptor.ServiceType))
            .Select(descriptor => new
            {
                Key = descriptor.ServiceKey as string,
                Handler = descriptor.KeyedImplementationType?.Name
            })
            .Where(entry => entry.Key is null || !KnownEventNames.Contains(entry.Key))
            .Select(entry => $"{entry.Handler} keyed '{entry.Key}'")
            .ToList();

        // If this fails, the handler will never run and nothing will say so:
        // the consumer host finds no handler for the eventType, completes the
        // message, and writes the ProcessedMessages row anyway.
        unknown.Should().BeEmpty(
            "a handler's key must equal the CLR type name the outbox publisher stamps as eventType");
    }

    [Fact]
    public async Task Every_registered_handler_can_be_constructed()
    {
        await using var provider = Compose().BuildServiceProvider(validateScopes: true);
        await using var scope = provider.CreateAsyncScope();

        var keyed = Compose()
            .Where(descriptor => descriptor.IsKeyedService && HandlerInterfaces.Contains(descriptor.ServiceType))
            .Select(descriptor => (descriptor.ServiceType, Key: descriptor.ServiceKey!))
            .ToList();

        keyed.Should().NotBeEmpty("the modules register consumers, and a test that asserts over nothing passes");

        foreach (var (serviceType, key) in keyed)
        {
            // Resolving CONSTRUCTS it, which is what catches a handler whose
            // constructor asks for something no module registered -- the
            // failure mode that took the whole Host down on Day 29 when a
            // hosted service threw in a field initializer.
            var act = () => scope.ServiceProvider.GetRequiredKeyedService(serviceType, key);

            act.Should().NotThrow($"{key} is registered and must be constructible");
        }
    }

    /// <summary>
    /// EVERY integration event now has a consumer, which is what "feature
    /// complete" means concretely: there is no contract declared in this
    /// solution that nobody listens to.
    ///
    /// This started the day as an inventory of the three events flow 3 would
    /// add, precisely because a test that fails for a deliberate, dated
    /// omission is a test people learn to ignore. Flow 3 landed, the list
    /// emptied, and the assertion inverted into something much stronger: an
    /// event appearing here now means a contract was declared without a
    /// consumer, or a consumer lost its registration.
    /// </summary>
    [Fact]
    public void Every_integration_event_has_a_consumer()
    {
        var handled = Compose()
            .Where(descriptor => descriptor.IsKeyedService && HandlerInterfaces.Contains(descriptor.ServiceType))
            .Select(descriptor => (string)descriptor.ServiceKey!)
            .ToHashSet(StringComparer.Ordinal);

        var unhandled = KnownEventNames.Except(handled).OrderBy(name => name, StringComparer.Ordinal);

        unhandled.Should().BeEmpty(
            "every contract in QuotesPlatform.Contracts is consumed by some module; an event listed here "
            + "was either declared without a consumer or lost its registration, and in both cases the "
            + "message is delivered, completed and silently dropped");
    }
}
