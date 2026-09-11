namespace QuotesApi.Middleware;

/// <summary>
/// Sets the response headers a browser uses to limit what a page is allowed
/// to do. Day 27.
///
/// WHY MIDDLEWARE AND NOT A PACKAGE. There is nothing here a package would do
/// better: five headers, set unconditionally, on every response. A dependency
/// would add a version to track and a configuration surface to learn for the
/// sake of five string assignments.
///
/// WHY IT RUNS EARLY. Headers must be on the response BEFORE anything starts
/// writing a body -- once the first byte goes out the headers are sent and
/// further changes are silently ignored (or throw). This is registered above
/// the static file middleware for that reason, so the SPA's own HTML and
/// assets carry the headers too, not only API responses.
///
/// THE ONE THAT CAN BREAK THINGS IS CSP. Content-Security-Policy tells the
/// browser which sources of script, style and images to trust, and a policy
/// that is too strict makes a front end fail with a blank page and a console
/// error rather than an HTTP error -- so nothing in a health check or a smoke
/// test notices. The policy below is written against what this app actually
/// serves and is verified by opening the SPA, not by assuming.
/// </summary>
public class SecurityHeadersMiddleware(RequestDelegate next)
{
    // Built once. These never vary per request, and rebuilding a
    // dictionary per response for values that cannot change is waste in the
    // one code path every single request goes through.
    private static readonly (string Name, string Value)[] Headers =
    [
        // Stops the browser guessing a content type when the server sent one.
        // Without it, a response declared text/plain that happens to contain
        // HTML can be rendered as HTML -- which turns a stored string into a
        // script execution.
        ("X-Content-Type-Options", "nosniff"),

        // No framing at all. This API's front end is not designed to be
        // embedded, so the strictest value is also the correct one: it removes
        // clickjacking as a category rather than restricting it.
        ("X-Frame-Options", "DENY"),

        // Do not send the Referer header off-site. Quote and collection ids
        // travel in URLs, and a Referer leaks the URL a user came from to
        // every external resource the page loads.
        ("Referrer-Policy", "no-referrer"),

        // Browser features this app does not use, switched off explicitly.
        // An XSS that did get through cannot then ask for the camera.
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=()"),

        // CSP. 'self' for scripts and styles because the SPA's bundle is
        // served from this origin; 'unsafe-inline' for styles ONLY, because
        // the Angular build emits inline style attributes and removing that
        // is a front-end change rather than a header change -- stated here
        // rather than quietly widened. No 'unsafe-inline' for scripts, which
        // is the half that actually stops injected code from running.
        // connect-src 'self' keeps a compromised page from posting the
        // user's data to somebody else's server.
        ("Content-Security-Policy",
            "default-src 'self'; " +
            "script-src 'self'; " +
            "style-src 'self' 'unsafe-inline'; " +
            "img-src 'self' data:; " +
            "font-src 'self'; " +
            "connect-src 'self'; " +
            "frame-ancestors 'none'; " +
            "base-uri 'self'; " +
            "form-action 'self'"),
    ];

    public async Task InvokeAsync(HttpContext context)
    {
        // OnStarting, not a plain assignment before next(). An endpoint or a
        // later middleware can start the response itself, and a header set
        // after that point is lost without an error. This callback runs at
        // the moment the response is being sent, whoever sends it.
        context.Response.OnStarting(() =>
        {
            foreach (var (name, value) in Headers)
            {
                // Append only when absent: a response that deliberately set
                // its own value keeps it. Assigning would let this middleware
                // silently overrule an endpoint that knew better.
                if (!context.Response.Headers.ContainsKey(name))
                    context.Response.Headers[name] = value;
            }

            // HSTS only over HTTPS, and only for real requests.
            //
            // Sending Strict-Transport-Security over plain HTTP is ignored by
            // browsers, so it is not harmful -- but setting it in local
            // development IS harmful: the browser then refuses http://localhost
            // for the max-age, for every app on that port, and the developer
            // has to clear it by hand. One year, because a short max-age
            // provides a window rather than protection.
            if (context.Request.IsHttps)
                context.Response.Headers["Strict-Transport-Security"] =
                    "max-age=31536000; includeSubDomains";

            return Task.CompletedTask;
        });

        await next(context);
    }
}
