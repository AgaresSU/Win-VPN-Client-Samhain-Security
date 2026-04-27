using System.IO;

namespace VpnClientWindows.Services;

public static class EnginePathResolver
{
    public static string Resolve(string? configuredPath, params string[] candidatePaths)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return configuredPath.Trim().Trim('"');
        }

        foreach (var candidatePath in candidatePaths)
        {
            var expanded = Environment.ExpandEnvironmentVariables(candidatePath);
            if (File.Exists(expanded))
            {
                return expanded;
            }
        }

        return candidatePaths.LastOrDefault() ?? string.Empty;
    }

    public static string ResolveSingBox(string? configuredPath)
    {
        return Resolve(
            configuredPath,
            @".\engines\sing-box\sing-box.exe",
            @"%ProgramFiles%\sing-box\sing-box.exe",
            @"%ProgramFiles(x86)%\sing-box\sing-box.exe",
            "sing-box.exe");
    }

    public static string ResolveWireGuard(string? configuredPath)
    {
        return Resolve(
            configuredPath,
            @"%ProgramFiles%\WireGuard\wireguard.exe",
            @"%ProgramFiles(x86)%\WireGuard\wireguard.exe",
            "wireguard.exe");
    }

    public static string ResolveAmneziaWireGuard(string? configuredPath)
    {
        return Resolve(
            configuredPath,
            @".\engines\amneziawg\awg-quick.exe",
            @"%ProgramFiles%\AmneziaWG\awg-quick.exe",
            @"%ProgramFiles(x86)%\AmneziaWG\awg-quick.exe",
            "awg-quick.exe");
    }
}
