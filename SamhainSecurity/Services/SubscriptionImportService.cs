using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed partial class SubscriptionImportService
{
    private const int MaxSubscriptionBytes = 1_048_576;
    private static readonly HttpClient HttpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(30)
    };

    public async Task<SubscriptionImportResult> ImportFromUrlAsync(
        string url,
        CancellationToken cancellationToken = default)
    {
        var normalizedUrl = SubscriptionUrlNormalizer.Normalize(url);
        using var request = new HttpRequestMessage(HttpMethod.Get, normalizedUrl);
        request.Headers.UserAgent.ParseAdd("SamhainSecurity/0.1");

        using var response = await HttpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);

        response.EnsureSuccessStatusCode();

        if (response.Content.Headers.ContentLength > MaxSubscriptionBytes)
        {
            throw new InvalidOperationException("Подписка слишком большая");
        }

        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (bytes.Length > MaxSubscriptionBytes)
        {
            throw new InvalidOperationException("Подписка слишком большая");
        }

        var content = Encoding.UTF8.GetString(bytes);
        var contentType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;

        return ImportFromContent(content, contentType);
    }

    public SubscriptionImportResult ImportFromContent(string content, string? contentType = null)
    {
        var candidate = DecodeIfBase64(content, out var wasBase64Decoded);
        var profiles = new List<VpnProfile>();
        var unsupportedLinks = 0;
        var vlessLinksSeen = 0;
        var jsonProfilesSeen = 0;
        var jsonDetected = IsJson(candidate, contentType);

        foreach (var link in ExtractShareLinks(candidate))
        {
            if (!link.StartsWith("vless://", StringComparison.OrdinalIgnoreCase))
            {
                unsupportedLinks++;
                continue;
            }

            vlessLinksSeen++;
            var profile = new VpnProfile();
            if (VlessShareLinkParser.TryApply(link, profile, out _))
            {
                EnsureProfileName(profile);
                profiles.Add(profile);
            }
        }

        if (jsonDetected)
        {
            var jsonProfiles = TryParseSingBoxProfiles(candidate);
            jsonProfilesSeen = jsonProfiles.Count;
            profiles.AddRange(jsonProfiles);
        }

        var distinctProfiles = Deduplicate(profiles);
        var format = jsonDetected
            ? "sing-box JSON"
            : wasBase64Decoded
                ? "base64 share links"
                : "share links";

        return new SubscriptionImportResult
        {
            Profiles = distinctProfiles,
            VlessLinksSeen = vlessLinksSeen,
            JsonProfilesSeen = jsonProfilesSeen,
            UnsupportedLinksSeen = unsupportedLinks,
            WasBase64Decoded = wasBase64Decoded,
            JsonDetected = jsonDetected,
            SourceFormat = format,
            Message = distinctProfiles.Count > 0
                ? $"Импортировано профилей: {distinctProfiles.Count}"
                : "В подписке не найдено поддерживаемых профилей"
        };
    }

    private static string DecodeIfBase64(string content, out bool wasBase64Decoded)
    {
        wasBase64Decoded = false;
        var trimmed = content.Trim();
        if (trimmed.Length < 16 || trimmed.Contains("://", StringComparison.Ordinal) || trimmed.StartsWith('{'))
        {
            return content;
        }

        try
        {
            var normalized = string.Concat(trimmed.Where(character => !char.IsWhiteSpace(character)))
                .Replace('-', '+')
                .Replace('_', '/');
            while (normalized.Length % 4 != 0)
            {
                normalized += "=";
            }

            var decoded = Encoding.UTF8.GetString(Convert.FromBase64String(normalized));
            if (decoded.Contains("://", StringComparison.Ordinal) || decoded.TrimStart().StartsWith('{'))
            {
                wasBase64Decoded = true;
                return decoded;
            }
        }
        catch
        {
            return content;
        }

        return content;
    }

    private static bool IsJson(string content, string? contentType)
    {
        return string.Equals(contentType, "application/json", StringComparison.OrdinalIgnoreCase)
            || content.TrimStart().StartsWith('{');
    }

    private static IEnumerable<string> ExtractShareLinks(string content)
    {
        return ShareLinkRegex()
            .Matches(content)
            .Select(match => match.Value.Trim().TrimEnd(',', ';', '"', '\''));
    }

    private static List<VpnProfile> TryParseSingBoxProfiles(string content)
    {
        try
        {
            using var document = JsonDocument.Parse(content);
            if (!document.RootElement.TryGetProperty("outbounds", out var outbounds)
                || outbounds.ValueKind != JsonValueKind.Array)
            {
                return [];
            }

            var profiles = new List<VpnProfile>();
            foreach (var outbound in outbounds.EnumerateArray())
            {
                if (!IsVlessOutbound(outbound))
                {
                    continue;
                }

                var profile = BuildProfileFromSingBoxOutbound(outbound);
                if (string.IsNullOrWhiteSpace(profile.ServerAddress)
                    || string.IsNullOrWhiteSpace(profile.VlessUuid)
                    || string.IsNullOrWhiteSpace(profile.RealityPublicKey))
                {
                    continue;
                }

                EnsureProfileName(profile);
                profiles.Add(profile);
            }

            return profiles;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static bool IsVlessOutbound(JsonElement outbound)
    {
        return TryGetString(outbound, "type", out var type)
            && string.Equals(type, "vless", StringComparison.OrdinalIgnoreCase);
    }

    private static VpnProfile BuildProfileFromSingBoxOutbound(JsonElement outbound)
    {
        TryGetString(outbound, "tag", out var tag);
        TryGetString(outbound, "server", out var server);
        TryGetInt(outbound, "server_port", out var serverPort);
        TryGetString(outbound, "uuid", out var uuid);
        TryGetString(outbound, "flow", out var flow);

        var tls = outbound.TryGetProperty("tls", out var tlsElement)
            ? tlsElement
            : default;
        var reality = tls.ValueKind == JsonValueKind.Object && tls.TryGetProperty("reality", out var realityElement)
            ? realityElement
            : default;
        var utls = tls.ValueKind == JsonValueKind.Object && tls.TryGetProperty("utls", out var utlsElement)
            ? utlsElement
            : default;

        TryGetString(tls, "server_name", out var serverName);
        TryGetString(reality, "public_key", out var publicKey);
        TryGetString(reality, "short_id", out var shortId);
        TryGetString(utls, "fingerprint", out var fingerprint);

        return new VpnProfile
        {
            Name = string.IsNullOrWhiteSpace(tag) ? server : tag,
            Protocol = VpnProtocolType.VlessReality,
            ServerAddress = server,
            ServerPort = serverPort > 0 ? serverPort : 443,
            VlessUuid = uuid,
            VlessFlow = string.IsNullOrWhiteSpace(flow) ? "xtls-rprx-vision" : flow,
            RealityServerName = string.IsNullOrWhiteSpace(serverName) ? server : serverName,
            RealityPublicKey = publicKey,
            RealityShortId = shortId,
            RealityFingerprint = string.IsNullOrWhiteSpace(fingerprint) ? "chrome" : fingerprint,
            UpdatedAt = DateTimeOffset.UtcNow
        };
    }

    private static bool TryGetString(JsonElement element, string propertyName, out string value)
    {
        value = string.Empty;
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryGetInt(JsonElement element, string propertyName, out int value)
    {
        value = 0;
        if (element.ValueKind != JsonValueKind.Object
            || !element.TryGetProperty(propertyName, out var property))
        {
            return false;
        }

        return property.ValueKind switch
        {
            JsonValueKind.Number => property.TryGetInt32(out value),
            JsonValueKind.String => int.TryParse(property.GetString(), out value),
            _ => false
        };
    }

    private static IReadOnlyList<VpnProfile> Deduplicate(IEnumerable<VpnProfile> profiles)
    {
        return profiles
            .GroupBy(GetProfileKey, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToList();
    }

    private static string GetProfileKey(VpnProfile profile)
    {
        return string.Join(
            '|',
            profile.Protocol,
            profile.ServerAddress,
            profile.ServerPort,
            profile.VlessUuid,
            profile.RealityPublicKey,
            profile.RealityShortId);
    }

    private static void EnsureProfileName(VpnProfile profile)
    {
        if (!string.IsNullOrWhiteSpace(profile.Name))
        {
            return;
        }

        profile.Name = string.IsNullOrWhiteSpace(profile.ServerAddress)
            ? "Samhain Security"
            : $"Samhain {profile.ServerAddress}:{profile.ServerPort}";
    }

    [GeneratedRegex(@"(?i)\b(?:vless|vmess|trojan|ss)://[^\s""'<>]+", RegexOptions.Compiled)]
    private static partial Regex ShareLinkRegex();
}
