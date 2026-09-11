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

        // Day 27, from the ZAP baseline:
        //   WARN-NEW: Cross-Origin-Resource-Policy Header Missing or Invalid
        //             [90004]
        // Without it, any other site can embed this API's responses as a
        // subresource and read what the browser fetched with the user's
        // cookies. `same-origin` refuses that. It costs nothing here because
        // the only browser client reaches this API through nginx on its own
        // origin, so no legitimate cross-origin embedding exists to break.
        //
        // Cross-Origin-Embedder-Policy, which ZAP also asks for on the front
        // end, is deliberately NOT set -- see nginx/security-headers.conf for
        // the reasoning. It is not a header to add because a scanner named it.
        ("Cross-Origin-Resource-Policy", "same-origin"),
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

            // HSTS only where the BROWSER's connection is HTTPS.
            //
            // Setting Strict-Transport-Security in local development is
            // actively harmful: the browser then refuses http://localhost for
            // the whole max-age, for every app on that port, and the developer
            // has to clear it by hand. One year, because a short max-age is a
            // window rather than protection.
            //
            // WHY THIS IS NOT `context.Request.IsHttps`, AND HOW WE FOUND OUT.
            // It was, and the header never shipped. Azure Container Apps
            // terminates TLS at its ingress and forwards plain HTTP to the
            // container, so IsHttps is false on every production request and
            // the condition was never true in the one place it mattered. The
            // code read correctly and did nothing -- no test could see it,
            // because in-process tests speak to Kestrel directly. The OWASP ZAP
            // baseline against dev is what found it:
            //
            //   WARN-NEW: Strict-Transport-Security Header Not Set [10035]
            //
            // X-Forwarded-Proto is the ingress's statement about the browser's
            // side of the connection. It is trusted here for the same reason
            // the rate limiter trusts X-Forwarded-For: nothing reaches this
            // container except through that ingress. The consequence of a
            // wrong answer is also small in this direction -- a spoofed
            // "https" adds a header a plain-HTTP browser ignores.
            var forwardedProto = context.Request.Headers["X-Forwarded-Proto"].FirstOrDefault();
            var clientUsedHttps = context.Request.IsHttps
                || string.Equals(forwardedProto, "https", StringComparison.OrdinalIgnoreCase);

            if (clientUsedHttps)
                context.Response.Headers["Strict-Transport-Security"] =
                    "max-age=31536000; includeSubDomains";

            return Task.CompletedTask;
        });

        await next(context);
    }
}
