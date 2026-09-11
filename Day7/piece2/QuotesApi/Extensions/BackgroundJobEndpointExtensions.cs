using System.Security.Claims;
using QuotesApi.BackgroundJobs;

namespace QuotesApi.Extensions;

public static class BackgroundJobEndpointExtensions
{
    public static IEndpointRouteBuilder MapBackgroundJobEndpoints(
        this IEndpointRouteBuilder app, string prefix = "/api")
    {
        var group = app.MapGroup($"{prefix}/background-jobs")
            .RequireAuthorization("can-read-quotes");

        group.MapPost("/quote-author-reports", (
            CreateQuoteAuthorReportRequest request,
            ClaimsPrincipal user,
            HttpResponse response,
            IBackgroundJobQueue queue,
            IBackgroundJobStore store) =>
        {
            if (request.TopAuthors is < 1 or > 100)
            {
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["topAuthors"] = ["TopAuthors must be between 1 and 100."]
                });
            }

            var requestedBy = user.FindFirst(ClaimTypes.NameIdentifier)?.Value
                ?? user.FindFirst("sub")?.Value
                ?? throw new InvalidOperationException(
                    "Authenticated request had no caller id claim.");

            var job = new QuoteAuthorReportJob(
                Guid.NewGuid(),
                request.TopAuthors,
                requestedBy);

            if (!store.TryCreate(job))
                return Results.Conflict();

            if (!queue.TryEnqueue(job))
            {
                store.TryRemove(job.Id);
                response.Headers.RetryAfter = "5";

                return Results.Problem(
                    title: "Background job queue is full.",
                    detail: "Retry the request after the interval in the Retry-After header.",
                    statusCode: StatusCodes.Status503ServiceUnavailable);
            }

            var statusUrl = $"/api/background-jobs/{job.Id}";
            return Results.Accepted(
                statusUrl,
                new
                {
                    jobId = job.Id,
                    status = BackgroundJobStatus.Queued.ToString(),
                    statusUrl
                });
        });

        group.MapGet("/{id:guid}", (
            Guid id,
            ClaimsPrincipal user,
            IBackgroundJobStore store) =>
        {
            var requestedBy = user.FindFirst(ClaimTypes.NameIdentifier)?.Value
                ?? user.FindFirst("sub")?.Value;

            if (!store.TryGet(id, out var job)
                || job is null
                || !string.Equals(job.RequestedBy, requestedBy, StringComparison.Ordinal))
            {
                return Results.NotFound();
            }

            return Results.Ok(new
            {
                jobId = job.Id,
                jobType = job.JobType,
                status = job.Status.ToString(),
                job.QueuedAt,
                job.StartedAt,
                job.CompletedAt,
                job.Result,
                job.Error
            });
        });

        return app;
    }
}

public sealed record CreateQuoteAuthorReportRequest(int TopAuthors = 10);
