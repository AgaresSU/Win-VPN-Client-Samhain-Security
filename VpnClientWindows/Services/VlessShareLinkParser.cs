using VpnClientWindows.Models;

namespace VpnClientWindows.Services;

public static class VlessShareLinkParser
{
    public static bool TryApply(string value, VpnProfile profile, out string error)
    {
        error = string.Empty;

        if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri)
            || !string.Equals(uri.Scheme, "vless", StringComparison.OrdinalIgnoreCase))
        {
            error = "Некорректная VLESS-ссылка";
            return false;
        }

        var query = ParseQuery(uri.Query);

        profile.Protocol = VpnProtocolType.VlessReality;
        profile.VlessUuid = Uri.UnescapeDataString(uri.UserInfo);
        profile.ServerAddress = uri.Host;
        profile.ServerPort = uri.Port > 0 ? uri.Port : 443;
        profile.VlessFlow = Get(query, "flow", "xtls-rprx-vision");
        profile.RealityServerName = Get(query, "sni", Get(query, "servername", uri.Host));
        profile.RealityPublicKey = Get(query, "pbk", Get(query, "publickey", string.Empty));
        profile.RealityShortId = Get(query, "sid", Get(query, "shortid", string.Empty));
        profile.RealityFingerprint = Get(query, "fp", "chrome");

        if (!string.IsNullOrWhiteSpace(uri.Fragment))
        {
            profile.Name = Uri.UnescapeDataString(uri.Fragment.TrimStart('#'));
        }

        if (string.IsNullOrWhiteSpace(profile.VlessUuid)
            || string.IsNullOrWhiteSpace(profile.ServerAddress)
            || string.IsNullOrWhiteSpace(profile.RealityPublicKey))
        {
            error = "В ссылке не хватает UUID, сервера или Reality public key";
            return false;
        }

        return true;
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

    private static string Get(IReadOnlyDictionary<string, string> query, string key, string fallback)
    {
        return query.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : fallback;
    }
}
