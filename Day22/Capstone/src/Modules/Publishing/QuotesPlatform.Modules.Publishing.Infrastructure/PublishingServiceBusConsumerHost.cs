using Azure.Messaging.ServiceBus;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using QuotesPlatform.Contracts;
using QuotesPlatform.SharedKernel;

namespace QuotesPlatform.Modules.Publishing.Infrastructure;

/// <summary>
/// Competing-consumer worker for ServiceBusTopology.Subscriptions.PublishingEditions.
///
/// AutoCompleteMessages = false, deliberately: it forces every outcome
/// (complete, abandon) to be a line of code someone chose, rather than
/// indistinguishable from "the handler quietly did nothing".
///
/// Idempotency is the ProcessedMessages composite key (MessageId,
/// SubscriptionName), not the pre-check -- see ProcessedMessage's own comment.
/// The pre-check here is only the cheap optimisation; the INSERT inside the
/// same transaction as the handler's side effect is the actual guarantee, and
/// a unique-constraint violation on that INSERT is what "a concurrent
/// delivery already won" looks like.
/// </summary>
public sealed class PublishingServiceBusConsumerHost(
    IServiceScopeFactory scopeFactory,
    ServiceBusClient serviceBusClient,
    ILogger<PublishingServiceBusConsumerHost> logger) : BackgroundService
{
    private const string SubscriptionName = ServiceBusTopology.Subscriptions.PublishingEditions;

    private ServiceBusProcessor? _processor;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _processor = serviceBusClient.CreateProcessor(
            ServiceBusTopology.TopicName,
            SubscriptionName,
            new ServiceBusProcessorOptions { AutoCompleteMessages = false, MaxConcurrentCalls = 4 });

        _processor.ProcessMessageAsync += OnMessageAsync;
        _processor.ProcessErrorAsync += OnErrorAsync;

        await _processor.StartProcessingAsync(stoppingToken);
        logger.LogInformation("Publishing Service Bus processor started on {Subscription}", SubscriptionName);

        try
        {
            await Task.Delay(Timeout.Infinite, stoppingToken);
        }
        catch (OperationCanceledException)
        {
            // Expected on shutdown -- StopAsync stops the processor below.
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_processor is not null)
            await _processor.StopProcessingAsync(cancellationToken);

        await base.StopAsync(cancellationToken);
    }

    private async Task OnMessageAsync(ProcessMessageEventArgs args)
    {
        var messageId = args.Message.MessageId;
        var eventType = args.Message.ApplicationProperties.TryGetValue("eventType", out var value)
            ? value?.ToString() ?? "unknown"
            : "unknown";

        try
        {
            await using var scope = scopeFactory.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<PublishingDbContext>();
            var handler = scope.ServiceProvider.GetKeyedService<IIntegrationEventHandler>(eventType);

            var alreadySeen = await db.ProcessedMessages
                .AsNoTracking()
                .AnyAsync(m => m.MessageId == messageId && m.SubscriptionName == SubscriptionName, args.CancellationToken);

            if (alreadySeen)
            {
                logger.LogInformation(
                    "Duplicate MessageId={MessageId} for {Subscription} -- completing without reprocessing",
                    messageId, SubscriptionName);
                await args.CompleteMessageAsync(args.Message, args.CancellationToken);
                return;
            }

            await using var transaction = await db.Database.BeginTransactionAsync(args.CancellationToken);

            try
            {
                if (handler is not null)
                {
                    await handler.HandleAsync(args.Message.Body.ToString(), args.CancellationToken);
                }
                else
                {
                    // Day 29 commit 7: the pipe exists, the handlers arrive in
                    // commit 12. Logged rather than silent, so a message that
                    // should have had a handler by now is visible.
                    logger.LogWarning(
                        "No handler registered for EventType={EventType} on {Subscription} -- completing as a no-op",
                        eventType, SubscriptionName);
                }

                db.ProcessedMessages.Add(new ProcessedMessage
                {
                    MessageId = messageId,
                    SubscriptionName = SubscriptionName,
                    ProcessedAtUtc = DateTime.UtcNow
                });

                await db.SaveChangesAsync(args.CancellationToken);
                await transaction.CommitAsync(args.CancellationToken);
            }
            catch (DbUpdateException)
            {
                // A concurrent delivery may have won the race and already
                // committed -- roll back OUR side effect so duplicate work
                // does not stay applied while only the dedupe row is
                // discarded, then confirm that is actually what happened
                // before treating this as a benign duplicate.
                await transaction.RollbackAsync(args.CancellationToken);

                if (!await IsDuplicateAsync(db, messageId, args.CancellationToken))
                    throw;

                logger.LogInformation(
                    "Concurrent duplicate detected for MessageId={MessageId} on {Subscription}", messageId, SubscriptionName);
            }

            await args.CompleteMessageAsync(args.Message, args.CancellationToken);
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Failed to process MessageId={MessageId} on {Subscription}", messageId, SubscriptionName);
            await args.AbandonMessageAsync(args.Message, cancellationToken: args.CancellationToken);
        }
    }

    private static async Task<bool> IsDuplicateAsync(PublishingDbContext db, string messageId, CancellationToken cancellationToken) =>
        await db.ProcessedMessages
            .AsNoTracking()
            .AnyAsync(m => m.MessageId == messageId && m.SubscriptionName == SubscriptionName, cancellationToken);

    private Task OnErrorAsync(ProcessErrorEventArgs args)
    {
        logger.LogError(args.Exception, "Publishing Service Bus processor error on {Subscription}", SubscriptionName);
        return Task.CompletedTask;
    }
}
