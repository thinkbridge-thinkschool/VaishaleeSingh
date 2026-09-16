using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using QuotesPlatform.Contracts;
using QuotesPlatform.Modules.Catalog.Infrastructure;
using QuotesPlatform.Modules.Curation.Infrastructure;
using QuotesPlatform.Modules.Moderation.Infrastructure;
using QuotesPlatform.Modules.Publishing.Infrastructure;
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
    /// THREE, not four. Catalog is the only publish-only module: it has no
    /// consumer host and therefore no IIntegrationEventHandler at all. That is
    /// not an oversight, it is the shape of the design today -- Catalog
    /// announces QuoteSubmitted and QuoteRevised and listens for nothing,
    /// because the event it will need to consume (QuoteApproved) belongs to
    /// flow 3, which is not built.
    ///
    /// Day 31 adds Catalog's consumer host and this array grows a fourth
    /// entry. Writing it as four today is what made this file fail to compile
    /// the first time: symmetry is a bad reason to reference a type that does
    /// not exist.
    /// </summary>
    private static readonly Type[] HandlerInterfaces =
    [
        typeof(CurationHandler), typeof(ModerationHandler), typeof(PublishingHandler)
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
    /// The inverse, and the one that will fail next. Flow 3 is not built yet,
    /// so QuoteSubmitted, QuoteApproved and QuotePublishable are declared,
    /// publishable and consumed by nobody. Listing them here rather than
    /// asserting every contract has a handler, because the unhandled ones are
    /// a known gap with a dated plan behind them and a test that fails for a
    /// deliberate omission is a test people learn to ignore.
    /// </summary>
    [Fact]
    public void The_events_with_no_consumer_are_the_ones_flow_3_will_add()
    {
        var handled = Compose()
            .Where(descriptor => descriptor.IsKeyedService && HandlerInterfaces.Contains(descriptor.ServiceType))
            .Select(descriptor => (string)descriptor.ServiceKey!)
            .ToHashSet(StringComparer.Ordinal);

        var unhandled = KnownEventNames.Except(handled).OrderBy(name => name, StringComparer.Ordinal);

        unhandled.Should().BeEquivalentTo(
            new[] { "QuoteApproved", "QuotePublishable", "QuoteSubmitted" },
            "these three are flow 3, which is planned for Day 31; anything ELSE appearing here is an event "
            + "that lost its consumer, and this test is how that gets noticed");
    }
}
