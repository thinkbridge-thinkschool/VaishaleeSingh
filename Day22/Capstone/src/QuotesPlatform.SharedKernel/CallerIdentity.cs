using System.Security.Claims;

namespace QuotesPlatform.SharedKernel;

/// <summary>
/// The single place the acting user's identity is derived, and the reason the
/// domain never had to learn that authentication exists.
///
/// WHAT CHANGED ON DAY 32. Every write endpoint used to take actorId, ownerId
/// or reviewerId as a plain string in the request body, and the aggregate
/// compared that string against the one it stored. Collection.RequireOwner is
/// an ownership check, and until today the caller supplied BOTH sides of the
/// comparison -- so anyone who knew a collection id and an owner id could act
/// as that owner, and anyone at all could approve a review under any
/// reviewer's name. See Day31/docs/day31-threat-model.md and ADR-0003.
///
/// The fix is deliberately narrow: the aggregates still take a string. Only
/// the SOURCE of that string changed, from the request body to a validated
/// token. Collection.RequireOwner is untouched and all 34 domain and
/// application tests still pass, because the domain is no more aware of
/// authentication than it was yesterday.
///
/// THIS LIVES IN SharedKernel ON PURPOSE. Four modules map their own endpoints
/// and all four need it; four private copies of a security-critical helper is
/// four chances to fix a bug in three places. It depends only on
/// System.Security.Claims from the base library -- not on ASP.NET Core -- so
/// the shared kernel does not become a web library to get it.
/// </summary>
public static class CallerIdentity
{
    /// <summary>Microsoft Entra's stable per-user, per-tenant object id.</summary>
    public const string ObjectIdClaim = "oid";

    /// <summary>The OIDC subject, used when a token carries no <c>oid</c>.</summary>
    public const string SubjectClaim = "sub";

    /// <summary>
    /// The acting user's id, taken from the validated token and nowhere else.
    ///
    /// FAILS CLOSED, AND THAT IS THE WHOLE POINT. There is no fallback to a
    /// body field, a header or a query parameter. A fallback would leave
    /// yesterday's hole open while making it look closed, which is worse than
    /// leaving it open honestly: a reviewer reading `RequireAuthorization` would
    /// stop looking.
    ///
    /// `oid` is preferred over `sub` because it is stable for the same user
    /// across every application in the tenant, while `sub` is pairwise --
    /// different per application for the same person. An ownership check built
    /// on `sub` would silently stop matching the day a second client app is
    /// registered, and the symptom would be "the owner can no longer edit their
    /// own collection", which reads like a domain bug and is not one.
    ///
    /// Throwing here rather than returning null is intentional. The Host sets an
    /// authorization fallback policy, so an ANONYMOUS request never reaches a
    /// handler -- it is refused with 401 before this is called. Reaching this
    /// line without a claim therefore means an authenticated token of a shape
    /// the API did not expect, which is a configuration fault rather than a
    /// caller error, and a 500 is the honest answer to it.
    /// </summary>
    public static string ActorId(this ClaimsPrincipal? principal)
    {
        var id = principal?.FindFirst(ObjectIdClaim)?.Value
                 ?? principal?.FindFirst(SubjectClaim)?.Value;

        if (string.IsNullOrWhiteSpace(id))
            throw new InvalidOperationException(
                $"The authenticated token carries neither a '{ObjectIdClaim}' nor a '{SubjectClaim}' claim, " +
                "so the acting user cannot be identified. Refusing rather than falling back to a " +
                "caller-supplied value.");

        return id;
    }
}
