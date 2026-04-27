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

    private readonly SecureDataProtector _protector;

    public SubscriptionImportService()
        : this(new SecureDataProtector())
    {
    }

    public SubscriptionImportService(SecureDataProtector protector)
    {
        _protector = protector;
    }

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
        var awgProfilesSeen = 0;
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

            var awgProfiles = TryParseAwgProfiles(candidate);
            awgProfilesSeen = awgProfiles.Count;
            profiles.AddRange(awgProfiles);
        }

        var distinctProfiles = Deduplicate(profiles);
        var format = awgProfilesSeen > 0
            ? "AWG JSON"
            : jsonDetected
            ? "sing-box JSON"
            : wasBase64Decoded
                ? "base64 share links"
                : "share links";

        return new SubscriptionImportResult
        {
            Profiles = distinctProfiles,
            VlessLinksSeen = vlessLinksSeen,
            JsonProfilesSeen = jsonProfilesSeen,
            AwgProfilesSeen = awgProfilesSeen,
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

    private List<VpnProfile> TryParseAwgProfiles(string content)
    {
        try
        {
            using var document = JsonDocument.Parse(content);
            if (!document.RootElement.TryGetProperty("items", out var items)
                || items.ValueKind != JsonValueKind.Array)
            {
                return [];
            }

            var locations = BuildLocationsMap(document.RootElement);
            var profiles = new List<VpnProfile>();
            foreach (var item in items.EnumerateArray())
            {
                if (!TryGetString(item, "config_text", out var configText)
                    || !LooksLikeTunnelConfig(configText))
                {
                    continue;
                }

                var profile = BuildAwgProfile(item, locations, configText);
                if (string.IsNullOrWhiteSpace(profile.Name)
                    || string.IsNullOrWhiteSpace(profile.EncryptedTunnelConfig))
                {
                    continue;
                }

                profiles.Add(profile);
            }

            return profiles;
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static Dictionary<int, JsonElement> BuildLocationsMap(JsonElement root)
    {
        if (!root.TryGetProperty("locations", out var locations)
            || locations.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        var map = new Dictionary<int, JsonElement>();
        foreach (var location in locations.EnumerateArray())
        {
            if (TryGetInt(location, "location_id", out var locationId) && locationId > 0)
            {
                map[locationId] = location.Clone();
            }
        }

        return map;
    }

    private VpnProfile BuildAwgProfile(
        JsonElement item,
        IReadOnlyDictionary<int, JsonElement> locations,
        string configText)
    {
        TryGetInt(item, "location_id", out var locationId);
        TryGetString(item, "title", out var itemTitle);
        TryGetString(item, "host", out var itemHost);

        var location = locations.TryGetValue(locationId, out var locationElement)
            ? locationElement
            : default;
        TryGetString(location, "title", out var locationTitle);
        TryGetString(location, "host", out var locationHost);

        var endpointHost = string.Empty;
        var endpointPort = 0;
        TryParseEndpointFromConfig(configText, out endpointHost, out endpointPort);

        var serverAddress = FirstNonEmpty(endpointHost, itemHost, locationHost);

        return new VpnProfile
        {
            Name = FirstNonEmpty(itemTitle, locationTitle, serverAddress, $"Samhain AWG {locationId}"),
            Protocol = VpnProtocolType.AmneziaWireGuard,
            ServerAddress = serverAddress,
            ServerPort = endpointPort > 0 ? endpointPort : 0,
            EncryptedTunnelConfig = _protector.Protect(configText.Trim()),
            UpdatedAt = DateTimeOffset.UtcNow
        };
    }

    private static bool LooksLikeTunnelConfig(string value)
    {
        return value.Contains("[Interface]", StringComparison.OrdinalIgnoreCase)
            && value.Contains("[Peer]", StringComparison.OrdinalIgnoreCase)
            && value.Contains("PrivateKey", StringComparison.OrdinalIgnoreCase)
            && value.Contains("PublicKey", StringComparison.OrdinalIgnoreCase);
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
        if (profile.Protocol == VpnProtocolType.VlessReality)
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

        return string.Join(
            '|',
            profile.Protocol,
            profile.Name,
            profile.ServerAddress,
            profile.ServerPort);
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

    private static string FirstNonEmpty(params string[] values)
    {
        return values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim()
            ?? string.Empty;
    }

    private static bool TryParseEndpointFromConfig(string config, out string host, out int port)
    {
        host = string.Empty;
        port = 0;

        var endpointLine = config
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(line => line.StartsWith("Endpoint", StringComparison.OrdinalIgnoreCase));

        if (string.IsNullOrWhiteSpace(endpointLine))
        {
            return false;
        }

        var value = endpointLine.Split('=', 2, StringSplitOptions.TrimEntries).LastOrDefault();
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var separatorIndex = value.LastIndexOf(':');
        if (separatorIndex <= 0 || separatorIndex >= value.Length - 1)
        {
            return false;
        }

        host = value[..separatorIndex].Trim('[', ']', ' ');
        return int.TryParse(value[(separatorIndex + 1)..], out port)
            && !string.IsNullOrWhiteSpace(host);
    }

    [GeneratedRegex(@"(?i)\b(?:vless|vmess|trojan|ss)://[^\s""'<>]+", RegexOptions.Compiled)]
    private static partial Regex ShareLinkRegex();
}
