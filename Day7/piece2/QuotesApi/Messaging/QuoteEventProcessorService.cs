using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using QuotesApi.Data;
using QuotesApi.Observability;
using System.Diagnostics;
using System.Text.Json;

namespace QuotesApi.Messaging;

/// <summary>
/// Competing-consumer worker: wraps a <see cref="ServiceBusProcessor"/> for one
/// subscription and drains it with multiple concurrent calls.
///
/// Key design decisions:
///
/// AutoCompleteMessages = false
///   This is the decision the whole exercise turns on. With auto-complete, an
///   idempotency check that swallows a duplicate and a handler that quietly did
///   nothing are indistinguishable. Completing explicitly makes every outcome —
///   complete, abandon, dead-letter — a line of code someone chose.
///
/// ReceiveMode = PeekLock (default, but stated)
///   ReceiveAndDelete loses the message on any handler failure, making the retry
///   story and the DLQ story impossible.
///
/// MaxConcurrentCalls > 1
///   A single instance with MaxConcurrentCalls=4 is already a competing consumer
///   over the subscription. Two instances running simultaneously are competing
///   consumers in the fuller "distributed" sense — the broker assigns each message
///   to exactly one locked receiver.
///
/// ProcessErrorAsync is not optional
///   It is the only place SDK-level faults (link failures, credential expiry,
///   entity-not-found) surface. Omitting it means those faults are silently
///   swallowed with no log.
///
/// Shutdown
///   StopProcessingAsync(stoppingToken) lets in-flight handlers finish within the
///   host's shutdown timeout rather than being cut off mid-transaction. The
///   ShutdownTimeout Day 18 already configured is the bound.
///
/// Idempotency
///   1. Check HasSeenAsync as a cheap pre-screen (optimisation only).
///   2. Apply the side effect.
///   3. Record the MessageId in ProcessedMessages inside the same EF transaction.
///   4. On DbUpdateException with unique-violation code: already processed —
///      complete without repeating work. (The unique PK is the actual guarantee.)
///   5. CompleteMessageAsync.
///
/// Dead-lettering — two routes
///   a. Exhaust MaxDeliveryCount: handler throws/abandons on every attempt.
///      Right for transient failures that might resolve.
///   b. Immediate dead-letter: handler classifies the exception as poison
///      (MessageFailureClassifier.IsPoison). Right for malformed JSON, unknown
///      schema version — no point burning the delivery budget on these.
/// </summary>
/// ONE INSTANCE PER SUBSCRIPTION. The subscription name is a constructor
/// argument rather than a lookup on the options, because the app runs this
/// service twice: once for "audit" and once for "search-index". Each instance
/// owns its own ServiceBusProcessor (and disposes it), resolves the handler
/// registered under its own subscription key, and writes dedupe rows keyed by
/// its own name -- which is exactly what the composite key on
/// ProcessedMessages exists to keep separate.
public sealed class QuoteEventProcessorService(
    string subscriptionName,
    ServiceBusProcessor processor,
    IServiceScopeFactory scopeFactory,
    IOptions<ServiceBusOptions> options,
    ILogger<QuoteEventProcessorService> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        processor.ProcessMessageAsync += OnMessageAsync;
        processor.ProcessErrorAsync += OnErrorAsync;

        await processor.StartProcessingAsync(stoppingToken);
        logger.LogInformation(
            "Service Bus processor started. Subscription={Subscription}, MaxConcurrentCalls={MaxConcurrentCalls}",
            subscriptionName,
            options.Value.MaxConcurrentCalls);

        // Block until the host signals cancellation (shutdown).
        // StopAsync (overridden below) will then stop the processor cleanly.
        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // Expected on shutdown — StopAsync will stop the processor.
        }
    }

    private async Task OnMessageAsync(ProcessMessageEventArgs args)
    {
        var messageId = args.Message.MessageId;
        var deliveryCount = args.Message.DeliveryCount;

        // Restore trace context so consumer spans are children of the
        // request that published the message.
        using var activity = RestoreTraceContext(args.Message, messageId);

        var sw = Stopwatch.StartNew();
        logger.LogInformation(
            "Processing MessageId={MessageId} DeliveryCount={DeliveryCount} Subscription={Subscription}",
            messageId, deliveryCount, subscriptionName);

        QuoteChangedEvent? evt = null;
        try
        {
            // --- Parse & schema check (poison if fails) ---
            evt = JsonSerializer.Deserialize<QuoteChangedEvent>(
                args.Message.Body.ToArray());

            if (evt is null)
                throw new JsonException("Deserialized event was null");

            if (evt.SchemaVersion != QuoteChangedEvent.CurrentSchemaVersion)
                throw new UnknownSchemaVersionException(evt.SchemaVersion);

            // --- Handle with idempotency ---
            await using var scope = scopeFactory.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<QuotesDbContext>();
            var store = scope.ServiceProvider.GetRequiredService<IProcessedMessageStore>();
            var handler = scope.ServiceProvider
                .GetRequiredKeyedService<IQuoteEventHandler>(subscriptionName);

            // Cheap pre-screen: skip the handler body if already recorded.
            // NOT the actual guarantee — two concurrent arrivals can both
            // pass this check. The unique PK on the RecordAsync INSERT is.
            if (await store.HasSeenAsync(messageId, subscriptionName, args.CancellationToken))
            {
                logger.LogInformation(
                    "Duplicate MessageId={MessageId} for Subscription={Subscription} — completing without side effect",
                    messageId, subscriptionName);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken);
                return;
            }

            // ONE transaction around the side effect AND the dedupe row.
            //
            // This is the whole guarantee. Two separate SaveChanges calls —
            // the handler's own, then the store's — are two transactions: a
            // crash between them, or a lost race on the dedupe INSERT, leaves
            // the side effect committed with nothing recording that it
            // happened, and the next delivery repeats it. The handler and the
            // store share this scope's DbContext, so both enlist here and
            // either both land or neither does.
            //
            // The scope's DbContext is the unit of work; the transaction is
            // what makes "did the work" and "wrote it down" a single fact.
            await using var transaction = await db.Database
                .BeginTransactionAsync(args.CancellationToken);

            try
            {
                // Apply the actual handler side-effect.
                await handler.HandleAsync(evt, args.CancellationToken);

                // Record the message id in the same transaction.
                await store.RecordAsync(messageId, subscriptionName, "Completed", args.CancellationToken);

                await transaction.CommitAsync(args.CancellationToken);
            }
            catch (DbUpdateException ex) when (IsUniqueConstraintViolation(ex))
            {
                // Race: another competing consumer processed the same message
                // and committed first. Roll back OUR side effect — otherwise
                // the duplicate work stays committed and the dedupe row is the
                // only thing that was discarded, which is precisely backwards.
                await transaction.RollbackAsync(args.CancellationToken);

                logger.LogInformation(
                    "Concurrent duplicate detected for MessageId={MessageId} — rolled back and completing",
                    messageId);
            }

            await args.CompleteMessageAsync(args.Message, args.CancellationToken);

            logger.LogInformation(
                "Completed MessageId={MessageId} EventType={EventType} in {ElapsedMs}ms",
                messageId, evt?.EventType, sw.ElapsedMilliseconds);
        }
        catch (OperationCanceledException) when (args.CancellationToken.IsCancellationRequested)
        {
            // Shutdown: let the lock expire so the broker redelivers.
            logger.LogInformation("Cancelled processing MessageId={MessageId} during shutdown", messageId);
            // Do NOT complete or abandon — let lock expire.
        }
        catch (Exception ex)
        {
            if (MessageFailureClassifier.IsPoison(ex))
            {
                // Dead-letter immediately — retrying cannot fix this.
                var reason = MessageFailureClassifier.PoisonReason(ex);
                var description = MessageFailureClassifier.PoisonDescription(ex);

                logger.LogWarning(
                    ex,
                    "Poison message detected MessageId={MessageId} Reason={Reason}. Dead-lettering immediately.",
                    messageId, reason);

                await args.DeadLetterMessageAsync(
                    args.Message,
                    deadLetterReason: reason,
                    deadLetterErrorDescription: description,
                    args.CancellationToken);
            }
            else
            {
                // Transient failure: abandon so the broker redelivers.
                // After MaxDeliveryCount attempts the broker moves it to the DLQ.
                logger.LogWarning(
                    ex,
                    "Transient failure on MessageId={MessageId} DeliveryCount={DeliveryCount}. Abandoning.",
                    messageId, deliveryCount);

                await args.AbandonMessageAsync(args.Message, cancellationToken: args.CancellationToken);
            }
        }
    }

    private Task OnErrorAsync(ProcessErrorEventArgs args)
    {
        // SDK-level faults: link failure, credential expiry, entity-not-found.
        // Must not throw from this handler.
        logger.LogError(
            args.Exception,
            "Service Bus processor error. EntityPath={EntityPath} ErrorSource={ErrorSource} Namespace={Namespace}",
            args.EntityPath,
            args.ErrorSource,
            args.FullyQualifiedNamespace);

        return Task.CompletedTask;
    }

    /// <summary>
    /// Rebuilds the publishing request's trace context on the consumer side and
    /// opens the worker's own span inside it.
    ///
    /// WHY THIS GOES THROUGH THE ActivitySource AND NOT `new Activity(...)`.
    /// The previous version did the latter, and it is the reason no worker span
    /// ever reached App Insights. `new Activity(name).Start()` produces a
    /// perfectly valid Activity that OpenTelemetry never sees: the exporter is
    /// driven by an ActivityListener which samples activities BY SOURCE, and an
    /// Activity constructed directly belongs to no source. So it starts, it
    /// becomes Activity.Current, its children inherit its ids -- and it is then
    /// dropped with no error logged anywhere.
    ///
    /// The symptom is not a missing span, which would have been obvious. It is a
    /// BROKEN trace: the EF Core spans raised inside the handler DO come from a
    /// registered source, so they are exported carrying a ParentSpanId that
    /// points at a span nothing ever sent. The result reads as database calls
    /// with no parent, and an API -> worker -> DB trace that stops at the message.
    ///
    /// ActivityKind.Consumer is what makes App Insights render this as the
    /// receiving end of a message rather than as an internal step, which is the
    /// difference between a trace that shows the hand-off and one that does not.
    ///
    /// The Azure SDK's own processor spans are deliberately still NOT registered
    /// in ObservabilityExtensions. Their source names are suffixed per client
    /// type, so collecting them needs a wildcard, and the wildcard also brings a
    /// second consumer span for every message -- the same double-instrumentation
    /// that already inflates the SQL dependency counts. One consumer span that
    /// this code owns is worth more than two it does not.
    /// </summary>
    private static Activity? RestoreTraceContext(ServiceBusReceivedMessage message, string messageId)
    {
        if (!message.ApplicationProperties.TryGetValue("traceparent", out var traceparentObj)
            || traceparentObj is not string traceparent
            || string.IsNullOrWhiteSpace(traceparent))
        {
            return null;
        }

        // Parsed rather than assigned. SetParentId accepts any string and fails
        // silently on a malformed one; TryParse rejects it here, so a bad header
        // costs the link and not the span.
        if (!ActivityContext.TryParse(traceparent, null, out var parentContext))
        {
            return null;
        }

        var activity = QuotesActivitySource.Instance.StartActivity(
            "QuoteEventProcessor.ProcessMessage",
            ActivityKind.Consumer,
            parentContext);

        activity?.SetTag("messaging.system", "servicebus");
        activity?.SetTag("messaging.operation", "process");
        activity?.SetTag("messaging.message_id", messageId);
        activity?.SetTag("messaging.source.name", message.Subject ?? string.Empty);

        return activity;
    }

    /// <summary>
    /// Returns true when the exception is a unique/primary-key violation.
    ///
    /// Matched on the provider's own error code, not on the exception text:
    /// message strings are localised, change between provider versions, and
    /// a substring search for "2627" matches any message that happens to
    /// contain those four digits. A dedupe guarantee that turns on string
    /// matching is not a guarantee.
    ///
    /// SQLite: SQLITE_CONSTRAINT (19), covering the extended primary-key and
    /// unique variants (1555 / 2067). SQL Server: 2627 (unique constraint)
    /// and 2601 (duplicate key in a unique index).
    /// </summary>
    private static bool IsUniqueConstraintViolation(DbUpdateException ex) => ex.InnerException switch
    {
        Microsoft.Data.Sqlite.SqliteException sqlite => sqlite.SqliteErrorCode == 19,
        Microsoft.Data.SqlClient.SqlException sql => sql.Number is 2627 or 2601,
        _ => false
    };

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        // This instance created its processor (see MessagingExtensions), so it
        // owns it and disposes it. Stop first: StopProcessingAsync lets
        // in-flight handlers finish inside the host's shutdown timeout rather
        // than being cut off mid-transaction.
        await processor.StopProcessingAsync(cancellationToken);
        await processor.DisposeAsync();
        await base.StopAsync(cancellationToken);
    }
}
