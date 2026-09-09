using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using QuotesApi.Caching;
using QuotesApi.Messaging.Outbox;
using QuotesApi.Observability;
using QuotesApi.Resilience;

namespace QuotesApi.Extensions;

/// <summary>
/// Distributed tracing, and shipping it somewhere. Kept separate from
/// InfrastructureExtensions, which is already long and is about what the app
/// needs in order to serve a request; this is about being able to see what
/// happened afterward.
///
/// There are two possible destinations, and they are independent:
///   - an OTLP collector (Jaeger / Aspire) for local development
///   - Azure Monitor / Application Insights for deployed environments
/// Both, either, or neither can be active. Spans are created regardless --
/// an exporter only decides where they are sent, so with neither configured
/// the app still runs and still correlates logs to trace IDs, it just keeps
/// the telemetry to itself.
/// </summary>
public static class ObservabilityExtensions
{
    public static IServiceCollection AddObservability(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        // WHY BOTH EXPORTERS ARE CONDITIONAL:
        //
        // AddOtlpExporter() with no collector listening does not fail
        // quietly -- it keeps retrying against localhost:4317 and logging
        // the failures. UseAzureMonitor() is worse: with no connection
        // string it THROWS at startup rather than degrading.
        //
        // Neither is configured in CI or in the test suite, and the
        // integration tests boot this app dozens of times per run. Wiring
        // either one unconditionally would mean a broken pipeline and 135
        // failing tests, not a slightly noisier log.
        var otlpEndpoint = configuration["OpenTelemetry:OtlpEndpoint"];
        var appInsightsConnectionString = configuration["ApplicationInsights:ConnectionString"];
        var azureMonitorEnabled = !string.IsNullOrWhiteSpace(appInsightsConnectionString);

        var openTelemetry = services
            .AddOpenTelemetry()
            .ConfigureResource(resource => resource.AddService(serviceName: "QuotesApi"));

        openTelemetry.WithTracing(tracing =>
        {
            // Neither of these is provided by the Azure Monitor distro, so
            // they are always ours to register.
            tracing
                .AddEntityFrameworkCoreInstrumentation()
                .AddSource(QuotesActivitySource.Name)
                // Day 19: Service Bus SDK emits producer and consumer spans.
                // These link when traceparent travels as a message property,
                // making the consumer span a child of the request that published.
                .AddSource("Azure.Messaging.ServiceBus");

            // ...whereas these two ARE part of the distro. Registering them
            // here as well when Azure Monitor is active would instrument the
            // same events twice: every request and every outbound call would
            // be recorded as two spans, which silently corrupts every
            // duration percentile and doubles the ingestion bill. So they
            // are added only when the distro is not doing it for us.
            if (!azureMonitorEnabled)
            {
                tracing
                    .AddAspNetCoreInstrumentation()
                    .AddHttpClientInstrumentation();
            }

            if (!string.IsNullOrWhiteSpace(otlpEndpoint))
                tracing.AddOtlpExporter(options => options.Endpoint = new Uri(otlpEndpoint));
        });

        // Day 20 -- the outbox relay's instruments.
        //
        // A Meter that is not registered by name here emits nothing, silently,
        // exactly like an unregistered ActivitySource. Registered
        // unconditionally: without an exporter the MeterProvider still
        // collects and discards, which costs almost nothing and means the
        // instruments are live the moment an exporter is configured, rather
        // than one config change plus one code change away.
        //
        // The gauge worth alerting on is outbox.oldest_pending.age. This
        // design removes "committed change, no message" and introduces "relay
        // is dead and every write still succeeds silently" -- and that second
        // failure mode is invisible without this metric.
        openTelemetry.WithMetrics(metrics => metrics
            .AddMeter(OutboxMetrics.MeterName)

            // Day 21 -- the cache's own counters, and the DB-command counter
            // they are compared against. Both, because neither answers the
            // other's question: a hit rate describes the cache, and only
            // db.commands describes the database.
            .AddMeter(CacheMetrics.MeterName)
            .AddMeter(DbCommandCounterInterceptor.MeterName)

            // Day 22 -- the resilience pipeline's own instruments. The one
            // that does not exist anywhere else is
            // resilience.retries.suppressed: a retry DECLINED because the
            // request was not idempotent is a non-event to Polly (no retry
            // occurred, so its own telemetry emits nothing), which would
            // leave a broken gate indistinguishable from a gate that is
            // never triggered.
            .AddMeter(ResilienceMetrics.MeterName));

        if (azureMonitorEnabled)
        {
            // Exports traces, metrics AND logs to Application Insights.
            // Logs arrive through the ILoggerProvider this registers, which
            // is why Program.cs passes writeToProviders: true to Serilog --
            // without it Serilog would swallow everything before it ever
            // reached this provider.
            openTelemetry.UseAzureMonitor(options =>
            {
                options.ConnectionString = appInsightsConnectionString;

                // Day 25. Authenticate ingestion with the app's managed
                // identity instead of the instrumentation key embedded in the
                // connection string.
                //
                // The component sets DisableLocalAuth (see
                // infra/modules/monitoring.bicep), so the key no longer
                // authenticates anything and this line is what keeps telemetry
                // flowing at all. Without it the exporter is refused, and the
                // symptom is not an exception — it is an empty Application
                // Insights, which is a considerably worse thing to debug.
                //
                // WHICH identity this resolves to depends on AZURE_CLIENT_ID
                // being set on the container app; main.bicep sets it, and the
                // comment there explains why the two changes are really one.
                //
                // Unconditional inside this block on purpose. The block only
                // runs when a connection string is configured, which is true
                // in deployed environments and false in CI and the test suite,
                // so nothing that runs without an Azure login reaches here. A
                // developer pointing at this component from a laptop needs
                // `az login`, which DefaultAzureCredential picks up.
                options.Credential = new DefaultAzureCredential();
            });
        }

        return services;
    }
}
