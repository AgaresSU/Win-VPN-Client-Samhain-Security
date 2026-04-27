namespace SamhainSecurity.Services;

public static class SubscriptionUrlNormalizer
{
    public static string Normalize(string value)
    {
        var trimmed = value.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri))
        {
            return trimmed;
        }

        if (uri.AbsolutePath.EndsWith("/subscription.html", StringComparison.OrdinalIgnoreCase)
            || uri.AbsolutePath.EndsWith("/subscription-awg.html", StringComparison.OrdinalIgnoreCase))
        {
            var query = ParseQuery(uri.Query);
            if (query.TryGetValue("token", out var token) && !string.IsNullOrWhiteSpace(token))
            {
                var path = uri.AbsolutePath.EndsWith("/subscription-awg.html", StringComparison.OrdinalIgnoreCase)
                    ? $"api/sub/{Uri.EscapeDataString(token)}/awg"
                    : $"api/sub/{Uri.EscapeDataString(token)}";

                var builder = new UriBuilder(uri.Scheme, uri.Host, uri.IsDefaultPort ? -1 : uri.Port)
                {
                    Path = path,
                    Query = string.Empty
                };

                return builder.Uri.ToString();
            }
        }

        return trimmed;
    }

    private static IReadOnlyDictionary<string, string> ParseQuery(string query)
    {
        return query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(part => part.Split('=', 2))
            .Where(parts => parts.Length == 2)
            .ToDictionary(
                parts => Uri.UnescapeDataString(parts[0]).ToLowerInvariant(),
                parts => Uri.UnescapeDataString(parts[1]),
                StringComparer.OrdinalIgnoreCase);
    }
}
