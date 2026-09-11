using System.Globalization;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.RateLimiting;

namespace QuotesApi.Extensions;

/// <summary>
/// Rate limiting. Day 27.
///
/// WHY THIS IS THE MOST IMPORTANT ITEM IN THE SECURITY PASS. Every other
/// control in this app answers "is this caller allowed?". None of them answers
/// "how many times may they ask?" -- so POST /api/auth/login could be called
/// without limit, and a password is only as strong as the number of guesses
/// somebody is allowed. The threat model calls this Spoofing via Denial of
/// service: the attack is cheap, needs no credential, and leaves the service
/// slower for everybody else while it runs.
///
/// NO PACKAGE. Rate limiting has been in the framework since .NET 7
/// (Microsoft.AspNetCore.RateLimiting). Adding a third-party limiter here
/// would be a dependency for something the runtime already does.
///
/// TWO POLICIES, BECAUSE THE ENDPOINTS ARE NOT ALIKE:
///
///   auth   -- strict. Credential endpoints are where guessing happens, and
///             a legitimate human logs in once or twice, not thirty times a
///             minute.
///   global -- loose. A ceiling that protects the database from one client
///             hammering reads, set well above anything the SPA does.
///
/// PARTITIONED BY IP, AND ITS LIMIT STATED. A caller behind a shared NAT
/// shares a bucket with everyone else behind it, and an attacker with many
/// addresses gets many buckets. Per-IP is therefore a speed bump, not a wall.
/// The wall would be per-account lockout, which introduces its own denial of
/// service (lock somebody out by guessing at their username) and is a
/// deliberate non-goal here. What this does buy is that a single host cannot
/// run an unbounded guessing loop, which is the actual exposure today.
/// </summary>
public static class RateLimitingExtensions
{
    public const string AuthPolicy = "auth";

    public static IServiceCollection AddQuotesRateLimiting(this IServiceCollection services)
    {
        services.AddRateLimiter(options =>
        {
            // 429, not 503. The client is being asked to slow down, not told
            // the server is broken -- and the distinction matters to anything
            // that retries on 5xx.
            options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

            // Retry-After, because a limiter that rejects without saying when
            // to come back invites an immediate retry, which is the behaviour
            // it was trying to prevent.
            options.OnRejected = async (context, cancellationToken) =>
            {
                if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
                {
                    context.HttpContext.Response.Headers.RetryAfter =
                        ((int)retryAfter.TotalSeconds).ToString(NumberFormatInfo.InvariantInfo);
                }

                context.HttpContext.Response.ContentType = "application/problem+json";
                await context.HttpContext.Response.WriteAsync(
                    """{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.29","title":"Too Many Requests","status":429}""",
                    cancellationToken);
            };

            // --- The strict one: credential endpoints -----------------------
            //
            // TEN PER MINUTE, AND THE NUMBER IS CHOSEN AGAINST A REAL CALLER.
            // Day 26's verification probe (02-verify-telemetry.ps1) registers,
            // logs in once, then writes 25 quotes and reads 10 pages. It hits
            // /api/auth twice. A human on the SPA hits it once, or a few times
            // if they mistype. Ten leaves both of those untouched and still
            // turns an unbounded guessing loop into 600 attempts an hour from
            // one address.
            //
            // A fixed window rather than a sliding one: at this size the
            // difference is a burst of at most 2x at a window boundary, and a
            // fixed window is the one whose behaviour is obvious to whoever
            // reads the 429 later.
            options.AddPolicy(AuthPolicy, httpContext =>
                RateLimitPartition.GetFixedWindowLimiter(
                    partitionKey: ClientKey(httpContext),
                    factory: _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = 10,
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0,          // reject immediately; queueing a login is pointless
                        AutoReplenishment = true
                    }));

            // --- The loose one: everything else -----------------------------
            //
            // 300 a minute per address. The probe's 25 writes plus 10 reads,
            // and any plausible SPA session, sit far below it. This is not
            // tuned traffic management; it is a ceiling so that one client
            // cannot saturate a database that auto-pauses and scales to zero.
            options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(httpContext =>
            {
                // Health and readiness are exempt. The platform probes them
                // every few seconds from addresses this app does not control,
                // and a throttled health check reads as an unhealthy app --
                // which would take the revision down to protect it from a
                // load that was never a threat.
                var path = httpContext.Request.Path;
                if (path.StartsWithSegments("/health") || path.StartsWithSegments("/ready"))
                    return RateLimitPartition.GetNoLimiter("probe");

                return RateLimitPartition.GetFixedWindowLimiter(
                    partitionKey: ClientKey(httpContext),
                    factory: _ => new FixedWindowRateLimiterOptions
                    {
                        PermitLimit = 300,
                        Window = TimeSpan.FromMinutes(1),
                        QueueLimit = 0,
                        AutoReplenishment = true
                    });
            });
        });

        return services;
    }

    /// <summary>
    /// The partition key: the caller's address.
    ///
    /// X-Forwarded-For is read FIRST and that is a decision with a sharp edge.
    /// This app sits behind Container Apps' ingress, so RemoteIpAddress is the
    /// ingress, not the client -- partitioning on it would put every caller in
    /// the world into one bucket and the limits above would throttle everybody
    /// at once. But X-Forwarded-For is a header, and headers can be sent by
    /// anyone: a caller who sets their own gets a fresh bucket per value and
    /// the limit becomes decorative.
    ///
    /// Which risk is worse depends on the deployment, and here the ingress
    /// overwrites X-Forwarded-For rather than appending to it, so the value is
    /// the ingress's own observation and not the client's claim. That is the
    /// property this relies on; if this app were ever put behind a proxy that
    /// appends, this function is where that assumption breaks.
    /// </summary>
    private static string ClientKey(HttpContext httpContext)
    {
        var forwarded = httpContext.Request.Headers["X-Forwarded-For"].FirstOrDefault();

        if (!string.IsNullOrWhiteSpace(forwarded))
        {
            // First entry is the original client when the header is a chain.
            var first = forwarded.Split(',')[0].Trim();
            if (!string.IsNullOrWhiteSpace(first))
                return first;
        }

        return httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";
    }
}
