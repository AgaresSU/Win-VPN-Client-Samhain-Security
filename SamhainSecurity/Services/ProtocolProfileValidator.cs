using System.Text.RegularExpressions;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public static partial class ProtocolProfileValidator
{
    private const int MaxTunnelConfigLength = 512 * 1024;

    public static string Validate(VpnProfile profile, string tunnelConfig)
    {
        if (string.IsNullOrWhiteSpace(profile.Name))
        {
            return "Введите название профиля";
        }

        return profile.Protocol switch
        {
            VpnProtocolType.WindowsNative => ValidateWindowsNative(profile),
            VpnProtocolType.VlessReality => ValidateVlessReality(profile),
            VpnProtocolType.WireGuard => ValidateWireGuardStyleConfig(tunnelConfig, "WireGuard"),
            VpnProtocolType.AmneziaWireGuard => ValidateWireGuardStyleConfig(tunnelConfig, "AmneziaWG"),
            _ => "Неизвестный протокол"
        };
    }

    private static string ValidateWindowsNative(VpnProfile profile)
    {
        if (string.IsNullOrWhiteSpace(profile.ServerAddress))
        {
            return "Введите адрес сервера";
        }

        return string.Empty;
    }

    private static string ValidateVlessReality(VpnProfile profile)
    {
        if (string.IsNullOrWhiteSpace(profile.ServerAddress))
        {
            return "Введите адрес сервера";
        }

        if (profile.ServerPort <= 0 || profile.ServerPort > 65535)
        {
            return "Введите корректный порт VLESS";
        }

        if (!Guid.TryParse(profile.VlessUuid, out _))
        {
            return "VLESS UUID выглядит некорректно";
        }

        if (string.IsNullOrWhiteSpace(profile.RealityServerName))
        {
            return "Введите Reality SNI";
        }

        if (string.IsNullOrWhiteSpace(profile.RealityPublicKey)
            || profile.RealityPublicKey.Length < 16
            || profile.RealityPublicKey.Any(char.IsWhiteSpace))
        {
            return "Reality public key выглядит некорректно";
        }

        if (!string.IsNullOrWhiteSpace(profile.RealityShortId)
            && !HexRegex().IsMatch(profile.RealityShortId))
        {
            return "Reality Short ID должен быть hex-строкой";
        }

        return string.Empty;
    }

    private static string ValidateWireGuardStyleConfig(string config, string protocolName)
    {
        if (string.IsNullOrWhiteSpace(config))
        {
            return $"Вставьте {protocolName} .conf";
        }

        if (config.Length > MaxTunnelConfigLength)
        {
            return $"{protocolName} .conf слишком большой";
        }

        if (config.Contains('\0'))
        {
            return $"{protocolName} .conf содержит недопустимые символы";
        }

        if (!HasSection(config, "Interface") || !HasSection(config, "Peer"))
        {
            return $"{protocolName} .conf должен содержать [Interface] и [Peer]";
        }

        if (!TryGetConfigValue(config, "PrivateKey", out var privateKey) || !LooksLikeKey(privateKey))
        {
            return $"{protocolName} .conf: PrivateKey выглядит некорректно";
        }

        if (!TryGetConfigValue(config, "PublicKey", out var publicKey) || !LooksLikeKey(publicKey))
        {
            return $"{protocolName} .conf: PublicKey выглядит некорректно";
        }

        if (!TryGetConfigValue(config, "Endpoint", out var endpoint)
            || !TryParseEndpoint(endpoint, out _, out _))
        {
            return $"{protocolName} .conf: Endpoint выглядит некорректно";
        }

        return string.Empty;
    }

    private static bool HasSection(string config, string section)
    {
        return config
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(line => string.Equals(line, $"[{section}]", StringComparison.OrdinalIgnoreCase));
    }

    private static bool TryGetConfigValue(string config, string key, out string value)
    {
        value = string.Empty;
        var line = config
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(item => item.StartsWith(key + " ", StringComparison.OrdinalIgnoreCase)
                || item.StartsWith(key + "=", StringComparison.OrdinalIgnoreCase));

        if (string.IsNullOrWhiteSpace(line))
        {
            return false;
        }

        var parts = line.Split('=', 2, StringSplitOptions.TrimEntries);
        if (parts.Length != 2 || string.IsNullOrWhiteSpace(parts[1]))
        {
            return false;
        }

        value = parts[1];
        return true;
    }

    private static bool LooksLikeKey(string value)
    {
        return value.Length >= 32
            && value.Length <= 64
            && !value.Any(char.IsWhiteSpace)
            && Base64LikeRegex().IsMatch(value);
    }

    private static bool TryParseEndpoint(string value, out string host, out int port)
    {
        host = string.Empty;
        port = 0;

        var separatorIndex = value.LastIndexOf(':');
        if (separatorIndex <= 0 || separatorIndex >= value.Length - 1)
        {
            return false;
        }

        host = value[..separatorIndex].Trim('[', ']', ' ');
        return !string.IsNullOrWhiteSpace(host)
            && int.TryParse(value[(separatorIndex + 1)..], out port)
            && port is > 0 and <= 65535;
    }

    [GeneratedRegex("^[0-9a-fA-F]+$", RegexOptions.Compiled)]
    private static partial Regex HexRegex();

    [GeneratedRegex("^[A-Za-z0-9+/=_-]+$", RegexOptions.Compiled)]
    private static partial Regex Base64LikeRegex();
}
