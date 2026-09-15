namespace QuotesApi.Models;

public class Quote
{
    private static readonly string[] DefaultBackgroundImageUrls =
    {
        "/quote-backgrounds/mountain-1.jpg",
        "/quote-backgrounds/mountain-2.jpg",
        "/quote-backgrounds/mountain-3.jpg",
        "/quote-backgrounds/mountain-4.jpg",
        "/quote-backgrounds/mountain-5.jpg",
        "/quote-backgrounds/mountain-6.jpg"
    };

    public int Id { get; set; }
    public string Author { get; set; } = "";
    public string Text { get; set; } = "";

    private string _backgroundImageUrl = DefaultBackgroundImageUrls[0];

    public string BackgroundImageUrl
    {
        get => NormalizeBackgroundImageUrl(_backgroundImageUrl);
        set => _backgroundImageUrl = value;
    }

    /// <summary>
    /// Id of the user who created this quote — taken from their token's
    /// "sub" (custom JWT) or "oid"/"sub" (Entra ID) claim at the moment the
    /// quote was created. See QuoteEndpointExtensions.MapQuoteEndpoints,
    /// the POST handler.
    ///
    /// Null has a specific meaning here: it means either this quote existed
    /// before this column was added (a "legacy" quote — this project chose
    /// NOT to backfill those), or it was created by a caller with no
    /// identifiable user id. Either way, MustOwnQuoteHandler treats a null
    /// owner as "no ownership rule applies" rather than "nobody can touch
    /// this" — only quotes created after Day 3's ownership rules exist
    /// actually enforce them.
    /// </summary>
    public string? CreatedByUserId { get; set; }

    /// <summary>
    /// The one place that decides whether an author/text pair is even
    /// allowed to become a Quote. Before this factory existed, these same
    /// rules were checked by hand inside QuoteEndpointExtensions' POST
    /// handler, and nowhere else — meaning nothing stopped some OTHER
    /// caller (a background import job, a future admin tool) from building
    /// an invalid Quote just by using the object initializer directly.
    /// Putting the rule here, on the model itself, means it can never be
    /// bypassed no matter who's constructing a Quote — the same reasoning
    /// Collection already follows in its constructor.
    ///
    /// Throws <see cref="ArgumentException"/> naming the offending
    /// parameter for every failure mode, so callers (and tests) can assert
    /// exactly which field was invalid.
    /// </summary>
    public static Quote Create(
        string author,
        string text,
        string? createdByUserId = null,
        string? backgroundImageUrl = null)
    {
        if (string.IsNullOrWhiteSpace(author))
            throw new ArgumentException("Author is required.", nameof(author));

        if (author.Length > 200)
            throw new ArgumentException("Author must be 200 characters or less.", nameof(author));

        if (string.IsNullOrWhiteSpace(text))
            throw new ArgumentException("Text is required.", nameof(text));

        if (text.Length > 1000)
            throw new ArgumentException("Text must be 1000 characters or less.", nameof(text));

        var resolvedBackground = ResolveBackgroundImageUrl(backgroundImageUrl, $"{author}|{text}");

        return new Quote
        {
            Author = author,
            Text = text,
            CreatedByUserId = createdByUserId,
            BackgroundImageUrl = resolvedBackground
        };
    }

    public static string ResolveBackgroundImageUrl(string? backgroundImageUrl, string? seedText = null)
    {
        if (string.IsNullOrWhiteSpace(backgroundImageUrl))
        {
            return SelectDefaultBackground(seedText);
        }

        var trimmed = backgroundImageUrl.Trim();

        if (trimmed.Length > 500)
            throw new ArgumentException("Background image URL must be 500 characters or less.", nameof(backgroundImageUrl));

        if (!trimmed.StartsWith("/quote-backgrounds/", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Background image URL must point to a backend-hosted /quote-backgrounds file.", nameof(backgroundImageUrl));
        }

        return trimmed;
    }

    private static string NormalizeBackgroundImageUrl(string url)
    {
        return url.StartsWith("/quote-backgrounds/", StringComparison.OrdinalIgnoreCase)
            ? url.Replace(".webp", ".jpg", StringComparison.OrdinalIgnoreCase)
            : url;
    }

    public static string SelectDefaultBackground(string? seedText)
    {
        if (string.IsNullOrWhiteSpace(seedText))
            return DefaultBackgroundImageUrls[0];

        var hash = 0;
        foreach (var ch in seedText)
        {
            hash = unchecked((hash * 31) + ch);
        }

        var index = Math.Abs(hash % DefaultBackgroundImageUrls.Length);
        return DefaultBackgroundImageUrls[index];
    }
}
