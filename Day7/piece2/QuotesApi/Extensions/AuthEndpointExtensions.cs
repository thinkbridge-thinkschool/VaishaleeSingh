using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using QuotesApi.Configuration;
using QuotesApi.Data;
using QuotesApi.Models;
using QuotesApi.Services;

namespace QuotesApi.Extensions;

/// <summary>
/// /api/auth/register, /login, /refresh, and /logout -- the endpoints that
/// hand out and manage our own self-issued JWTs (the "CustomJwt" scheme).
///
/// Day 13 added /register. Until then this API could verify a password but
/// had no way to set one: every user row in every environment had to be
/// inserted by hand, which is workable for a CLI client and impossible for a
/// sign-up screen. The Angular SPA added on Day 13 is the first client that
/// needs an account it did not already have.
///
/// These endpoints are deliberately NOT behind .RequireAuthorization():
/// you can't be asked to prove who you are with a token in order to get
/// your very first token. (Entra ID users skip this file entirely --
/// Microsoft authenticates them directly and hands back its own token.)
/// </summary>
public static class AuthEndpointExtensions
{
    public static IEndpointRouteBuilder MapAuthEndpoints(
        this IEndpointRouteBuilder app, string prefix = "/api")
    {
        // Day 27 -- the strict rate-limit policy, on the whole group.
        //
        // THESE ARE THE ENDPOINTS AN ATTACKER CAN REACH WITHOUT A TOKEN, which
        // is exactly why they are the ones that need a ceiling. Everything
        // else in this API requires a credential before it does any work; here
        // the work IS deciding whether a credential is right, and without a
        // limit that decision can be requested indefinitely. A password is
        // only as strong as the number of guesses allowed against it.
        //
        // Applied to the group rather than per route so /refresh and /logout
        // are covered too: a refresh token is a credential like any other and
        // guessing one is the same attack.
        var group = app.MapGroup($"{prefix}/auth")
            .RequireRateLimiting(RateLimitingExtensions.AuthPolicy);

        // POST /api/auth/register -- create an account and return the same
        // token pair a login would, so a new user is signed in immediately
        // rather than being bounced to a login screen to retype what they
        // just typed.
        //
        // Not behind .RequireAuthorization() for the same reason /login is
        // not: the caller has no token yet, and getting one is the point.
        group.MapPost("/register", async (
            RegisterRequest request,
            IAuthService authService,
            IRefreshTokenService refreshTokenService,
            QuotesDbContext db,
            IClock clock,
            IOptions<JwtOptions> jwtOptions,
            CancellationToken cancellationToken) =>
        {
            var errors = new Dictionary<string, string[]>();
            var email = request.Email?.Trim() ?? string.Empty;

            // Deliberately not a full RFC 5322 regex. The only thing this
            // check can honestly establish is that the value is shaped like
            // an address; whether it exists is a question only sending mail
            // to it can answer, and this API does not send mail.
            if (string.IsNullOrWhiteSpace(email) || !email.Contains('@') || email.StartsWith('@') || email.EndsWith('@'))
                errors["email"] = new[] { "A valid email address is required." };
            else if (email.Length > 256)
                errors["email"] = new[] { "Email must be 256 characters or less." };

            // A floor, not a policy. Length is the one password rule with
            // evidence behind it; composition rules ("one capital, one
            // symbol") mainly push people towards predictable substitutions.
            if (string.IsNullOrEmpty(request.Password) || request.Password.Length < 8)
                errors["password"] = new[] { "Password must be at least 8 characters." };
            else if (request.Password.Length > 128)
                errors["password"] = new[] { "Password must be 128 characters or less." };

            if (errors.Count > 0)
                return Results.ValidationProblem(errors);

            // Checked here so the common case gets a clear 409 rather than a
            // unique-index violation surfacing as a 500. The index on
            // User.Email (see QuotesDbContext) is still what actually
            // guarantees uniqueness -- two simultaneous registrations of the
            // same address can both pass this check, and one of them must
            // still fail.
            //
            // This does confirm to an anonymous caller that an address is
            // registered. The alternative -- accepting the registration and
            // saying nothing -- is worse here: it leaves a real user unable
            // to sign in or to find out why. /login stays deliberately
            // silent about which half of the pair was wrong.
            var alreadyRegistered = await db.Users
                .AnyAsync(u => u.Email == email, cancellationToken);

            if (alreadyRegistered)
            {
                return Results.Problem(
                    statusCode: StatusCodes.Status409Conflict,
                    title: "Email already registered",
                    detail: "An account already exists for that email address.");
            }

            var user = new User
            {
                Email = email,

                // The raw password never reaches the database, and is never
                // logged. HashPassword is PasswordHasher<User> -- PBKDF2,
                // salted, deliberately slow. See AuthService.
                PasswordHash = authService.HashPassword(request.Password!),

                // IClock rather than DateTime.UtcNow, so a test can pin the
                // value instead of asserting something fuzzy about "now".
                // .UtcDateTime because IClock speaks DateTimeOffset while
                // User.CreatedAt is a DateTime -- the same conversion
                // RefreshTokenService and AuthService already do.
                CreatedAt = clock.UtcNow.UtcDateTime,
            };

            db.Users.Add(user);
            await db.SaveChangesAsync(cancellationToken);

            var accessToken = authService.GenerateAccessToken(user);
            var refreshToken = await refreshTokenService.GenerateTokenAsync(
                user.Id,
                cancellationToken);

            // Same source as /login and /refresh use, rather than a
            // hand-copied constant -- see JwtOptions for what drifted the
            // last time this number was written twice.
            var expiresIn = (int)jwtOptions.Value.AccessTokenLifetime.TotalSeconds;

            return Results.Json(
                new LoginResponse(accessToken, refreshToken, expiresIn, "Bearer"),
                statusCode: StatusCodes.Status201Created);
        });

        // POST /api/auth/login -- trade an email + password for an access
        // token (short-lived, 15 min) and a refresh token (long-lived, 7
        // days).
        group.MapPost("/login", async (
            LoginRequest request,
            IAuthService authService,
            CancellationToken cancellationToken) =>
        {
            if (string.IsNullOrWhiteSpace(request.Email) || string.IsNullOrWhiteSpace(request.Password))
            {
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["credentials"] = new[] { "Email and password are required." }
                });
            }

            var result = await authService.LoginAsync(
                request.Email,
                request.Password,
                cancellationToken);

            if (result is null)
                return Results.Unauthorized();

            var (accessToken, refreshToken, expiresIn) = result.Value;

            return Results.Ok(new LoginResponse(
                accessToken,
                refreshToken,
                expiresIn,
                "Bearer"));
        });

        // POST /api/auth/refresh -- trade a still-valid refresh token for a
        // brand new access token + refresh token pair. The old refresh
        // token is immediately marked as replaced (see
        // RefreshTokenService.ValidateTokenAsync) so it can never be used
        // again -- presenting it a second time is treated as theft, not a
        // retry, and revokes the whole token family (see
        // RefreshTokenService.DetectAndRevokeReuseAsync).
        //
        // QuotesDbContext is injected directly as a Minimal API parameter
        // here (ASP.NET Core resolves it from the request's own DI scope)
        // instead of manually building a second scope with
        // app.ServiceProvider.CreateScope() the way Day 1's version did --
        // that manual approach created a disconnected second DbContext
        // just to save a parameter, which is unnecessary and easy to get
        // subtly wrong.
        group.MapPost("/refresh", async (
            RefreshRequest request,
            IRefreshTokenService refreshTokenService,
            IAuthService authService,
            QuotesDbContext db,
            IOptions<JwtOptions> jwtOptions,
            CancellationToken cancellationToken) =>
        {
            if (string.IsNullOrWhiteSpace(request.RefreshToken))
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["refreshToken"] = new[] { "Refresh token is required." }
                });

            var storedToken = await refreshTokenService.ValidateTokenAsync(
                request.RefreshToken,
                cancellationToken);

            if (storedToken is null)
                return Results.Unauthorized();

            var user = await db.Users.FindAsync(
                new object[] { storedToken.UserId },
                cancellationToken);

            if (user is null)
                return Results.Unauthorized();

            // Generate the new pair. The new refresh token carries forward
            // the SAME FamilyId as the one being replaced, so the chain
            // stays intact -- this is what lets a reuse of the OLD token
            // later revoke this new one too, instead of the two being
            // unrelated.
            var newAccessToken = authService.GenerateAccessToken(user);
            var newRefreshToken = await refreshTokenService.GenerateTokenAsync(
                user.Id,
                cancellationToken,
                storedToken.FamilyId);

            // Mark the old token as replaced so it can't be used again.
            storedToken.ReplacedByToken = newRefreshToken;
            await db.SaveChangesAsync(cancellationToken);

            // Derived from the SAME configured lifetime the token was
            // actually minted with, rather than a hand-copied constant. It
            // was previously the literal 900 with a comment asking whoever
            // changed AuthService to remember to change this too. Nothing
            // enforced that; change one and the API keeps issuing valid
            // tokens while telling clients the wrong expiry, so they
            // refresh too late (users see spurious 401s) or too early
            // (needless load). No test would have caught it.
            var expiresIn = (int)jwtOptions.Value.AccessTokenLifetime.TotalSeconds;

            return Results.Ok(new LoginResponse(
                newAccessToken,
                newRefreshToken,
                expiresIn,
                "Bearer"));
        });

        // POST /api/auth/logout -- revoke a refresh token early (e.g. the
        // user clicked "sign out"), so it can't be used to get new access
        // tokens even though it hasn't expired yet.
        group.MapPost("/logout", async (
            LogoutRequest request,
            IRefreshTokenService refreshTokenService,
            QuotesDbContext db,
            CancellationToken cancellationToken) =>
        {
            if (string.IsNullOrWhiteSpace(request.RefreshToken))
                return Results.ValidationProblem(new Dictionary<string, string[]>
                {
                    ["refreshToken"] = new[] { "Refresh token is required." }
                });

            var token = await db.RefreshTokens
                .FirstOrDefaultAsync(rt => rt.TokenHash == HashToken(request.RefreshToken), cancellationToken);

            if (token is not null)
            {
                await refreshTokenService.RevokeTokenAsync(token.Id, cancellationToken);
            }

            return Results.NoContent();
        });

        return app;
    }

    private static string HashToken(string token)
    {
        using var sha256 = System.Security.Cryptography.SHA256.Create();
        var hash = sha256.ComputeHash(System.Text.Encoding.UTF8.GetBytes(token));
        return Convert.ToBase64String(hash);
    }
}

/// <summary>
/// Shape of the JSON body for POST /api/auth/register. Both nullable on
/// purpose: a client can omit either field, and "missing" has to reach the
/// endpoint as a validation failure naming the field rather than as a
/// deserialisation error naming nothing.
/// </summary>
public record RegisterRequest(string? Email, string? Password);

public record RefreshRequest(string RefreshToken);

public record LogoutRequest(string RefreshToken);

public record LoginRequest(string Email, string Password);

public record LoginResponse(
    string AccessToken,
    string RefreshToken,
    int ExpiresIn,
    string TokenType);
