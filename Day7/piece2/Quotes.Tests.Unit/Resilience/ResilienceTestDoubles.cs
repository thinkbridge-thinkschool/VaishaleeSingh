using System.Net;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using QuotesApi.Extensions;

namespace Quotes.Tests.Unit.Resilience;

/// <summary>
/// Shared doubles for the Day 22 resilience tests.
///
/// Day 5's equivalents are private nested classes inside
/// ResilienceExtensionsTests. They are deliberately left there, untouched: the
/// contract on the Day 22 options refactor is that the Day 5 tests keep passing
/// WITHOUT modification, and that check is worth more than removing a few
/// duplicated lines.
/// </summary>
internal static class ResilienceTestHost
{
    /// <summary>
    /// Builds a provider with the resilience pipeline registered, the primary
    /// handler swapped for a stub, and the policy driven from an in-memory
    /// configuration.
    ///
    /// The settings dictionary is what makes the circuit breaker testable at
    /// all. With Day 5's inline constants, opening it needed ten failures
    /// inside a thirty second window and a fifteen second wait to see it
    /// recover -- which is why Day 5 declined to test it and called it "a
    /// configured constant rather than logic". Bound to configuration, the
    /// same strategy proves itself in about two seconds.
    /// </summary>
    internal static ServiceProvider Build(
        HttpMessageHandler handler,
        out CapturingLoggerProvider logs,
        IDictionary<string, string?>? settings = null)
    {
        logs = new CapturingLoggerProvider();
        var captured = logs;

        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(settings ?? new Dictionary<string, string?>())
            .Build();

        var services = new ServiceCollection();

        services.AddLogging(builder =>
        {
            builder.SetMinimumLevel(LogLevel.Trace);
            builder.AddProvider(captured);
        });

        services.AddResilientHttpClients(configuration);

        // Calling AddHttpClient again with the same name adds to the existing
        // registration rather than replacing it, so the resilience handler
        // stays in place and only the innermost handler is swapped.
        services
            .AddHttpClient(ResilienceExtensions.EntraIdClientName)
            .ConfigurePrimaryHttpMessageHandler(() => handler);

        return services.BuildServiceProvider();
    }

    internal static HttpClient Client(this ServiceProvider provider) =>
        provider.GetRequiredService<IHttpClientFactory>()
            .CreateClient(ResilienceExtensions.EntraIdClientName);

    internal const string Url =
        "https://login.microsoftonline.test/common/v2.0/.well-known/openid-configuration";

    /// <summary>
    /// A fast-BREAKING policy. Every number here is small for one reason: the
    /// wall clock is the only thing that made Day 5 skip these tests, and the
    /// policy's behaviour does not depend on the magnitudes.
    ///
    /// The values respect Polly's own lower bounds (500ms on SamplingDuration
    /// and BreakDuration), which is why SamplingDuration is 2s rather than
    /// microseconds.
    ///
    /// BUT BreakDuration DEFAULTS TO THIRTY SECONDS, NOT ONE, AND THAT IS THE
    /// FIX FOR A REAL FLAKE. It was one second, and
    /// Circuit_UnderSustainedFailure_Opens failed in CI with
    ///
    ///     Expected metrics.CircuitOpened to be 1L, but found 2L.
    ///
    /// after passing locally every time. That test drives six sequential
    /// failing calls and expects the last two to bounce off an open circuit.
    /// On a loaded runner those six calls take longer than a second, so the
    /// break EXPIRES mid-test: the circuit goes half-open, the next failure
    /// re-opens it, and the counter reads 2. The breaker was behaving
    /// perfectly. The test was racing the clock it had set itself.
    ///
    /// The tempting fix is to relax the assertion to "at least once". That
    /// would be worse than the flake: opening exactly once is the property
    /// under test, and a breaker that opens repeatedly under one sustained
    /// outage is a genuine defect this suite would then no longer catch. So
    /// the timing dependency is removed instead — thirty seconds cannot
    /// elapse inside a test that runs in two.
    ///
    /// The three tests that actually exercise recovery already pass
    /// breakDuration: "00:00:01" explicitly, because a short break is the
    /// point for them. They are unaffected, and the explicit argument now
    /// reads as the deliberate choice it always was rather than as a
    /// restatement of the default.
    /// </summary>
    internal static Dictionary<string, string?> FastBreaker(
        int minimumThroughput = 4,
        string breakDuration = "00:00:30") => new()
    {
        ["Resilience:TotalTimeout"] = "00:00:05",
        ["Resilience:AttemptTimeout"] = "00:00:01",
        ["Resilience:Retry:BaseDelay"] = "00:00:00",
        ["Resilience:CircuitBreaker:FailureRatio"] = "0.5",
        ["Resilience:CircuitBreaker:MinimumThroughput"] = minimumThroughput.ToString(),
        ["Resilience:CircuitBreaker:SamplingDuration"] = "00:00:02",
        ["Resilience:CircuitBreaker:BreakDuration"] = breakDuration
    };
}

/// <summary>
/// Returns whatever status code it is currently told to, and counts calls.
/// Unlike Day 5's SequencedHandler, the outcome is SWITCHABLE mid-test, which
/// is what a recovery test needs: the same breaker has to see a failing
/// dependency and then a healthy one.
/// </summary>
internal sealed class SwitchableHandler : HttpMessageHandler
{
    private int _attempts;
    private volatile HttpStatusCode _status;

    public SwitchableHandler(HttpStatusCode status = HttpStatusCode.ServiceUnavailable) =>
        _status = status;

    public int Attempts => Volatile.Read(ref _attempts);

    public void Returns(HttpStatusCode status) => _status = status;

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _attempts);
        return Task.FromResult(new HttpResponseMessage(_status));
    }
}

/// <summary>
/// Blocks every request until released. For the bulkhead: a permit is only
/// observable as scarce while something is holding it.
/// </summary>
internal sealed class BlockingHandler : HttpMessageHandler
{
    private readonly TaskCompletionSource _release =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private readonly TaskCompletionSource _entered =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private int _attempts;

    public int Attempts => Volatile.Read(ref _attempts);

    /// <summary>Completes once a request has actually reached the handler.</summary>
    public Task Entered => _entered.Task;

    public void Release() => _release.TrySetResult();

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref _attempts);
        _entered.TrySetResult();

        await _release.Task.WaitAsync(cancellationToken);

        return new HttpResponseMessage(HttpStatusCode.OK);
    }
}

internal sealed record LogLine(LogLevel Level, string Message);

internal sealed class CapturingLoggerProvider : ILoggerProvider
{
    private readonly List<LogLine> _lines = new();
    private readonly object _gate = new();

    public IReadOnlyList<LogLine> Lines
    {
        get { lock (_gate) { return _lines.ToList(); } }
    }

    public ILogger CreateLogger(string categoryName) => new CapturingLogger(this);

    public void Dispose() { }

    private void Add(LogLine line)
    {
        lock (_gate) { _lines.Add(line); }
    }

    private sealed class CapturingLogger(CapturingLoggerProvider owner) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => true;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
            => owner.Add(new LogLine(logLevel, formatter(state, exception)));
    }
}
