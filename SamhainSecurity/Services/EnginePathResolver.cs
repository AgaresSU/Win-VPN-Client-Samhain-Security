using System.IO;

namespace VpnClientWindows.Services;

public static class EnginePathResolver
{
    private static readonly string BaseDirectory = AppContext.BaseDirectory;

    public static string Resolve(string? configuredPath, params string[] candidatePaths)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return NormalizeCandidate(configuredPath.Trim().Trim('"')).First();
        }

        foreach (var candidatePath in candidatePaths)
        {
            foreach (var normalizedPath in NormalizeCandidate(candidatePath))
            {
                if (File.Exists(normalizedPath))
                {
                    return normalizedPath;
                }
            }
        }

        return candidatePaths.LastOrDefault() ?? string.Empty;
    }

    public static IReadOnlyList<string> GetCandidates(string? configuredPath, params string[] candidatePaths)
    {
        var candidates = new List<string>();

        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            candidates.AddRange(NormalizeCandidate(configuredPath.Trim().Trim('"')));
        }

        foreach (var candidatePath in candidatePaths)
        {
            candidates.AddRange(NormalizeCandidate(candidatePath));
        }

        return candidates
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static bool IsPathAvailable(string path)
    {
        if (File.Exists(path))
        {
            return true;
        }

        if (Path.IsPathFullyQualified(path)
            || path.Contains(Path.DirectorySeparatorChar)
            || path.Contains(Path.AltDirectorySeparatorChar))
        {
            return false;
        }

        var pathVariable = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        return pathVariable
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(directory => Path.Combine(directory, path))
            .Any(File.Exists);
    }

    public static IReadOnlyList<string> GetSingBoxCandidates(string? configuredPath)
    {
        return GetCandidates(configuredPath, SingBoxCandidatePaths);
    }

    public static IReadOnlyList<string> GetWireGuardCandidates(string? configuredPath)
    {
        return GetCandidates(configuredPath, WireGuardCandidatePaths);
    }

    public static IReadOnlyList<string> GetAmneziaWireGuardCandidates(string? configuredPath)
    {
        return GetCandidates(configuredPath, AmneziaWireGuardCandidatePaths);
    }

    public static string ResolveSingBox(string? configuredPath)
    {
        return Resolve(configuredPath, SingBoxCandidatePaths);
    }

    public static string ResolveWireGuard(string? configuredPath)
    {
        return Resolve(configuredPath, WireGuardCandidatePaths);
    }

    public static string ResolveAmneziaWireGuard(string? configuredPath)
    {
        return Resolve(configuredPath, AmneziaWireGuardCandidatePaths);
    }

    private static IEnumerable<string> NormalizeCandidate(string candidatePath)
    {
        var expandedPath = Environment.ExpandEnvironmentVariables(candidatePath.Trim());

        if (string.IsNullOrWhiteSpace(expandedPath))
        {
            yield break;
        }

        if (Path.IsPathFullyQualified(expandedPath))
        {
            yield return expandedPath;
            yield break;
        }

        if (expandedPath.Contains(Path.DirectorySeparatorChar)
            || expandedPath.Contains(Path.AltDirectorySeparatorChar))
        {
            yield return Path.GetFullPath(expandedPath, BaseDirectory);
            yield return Path.GetFullPath(expandedPath, Environment.CurrentDirectory);
            yield break;
        }

        yield return expandedPath;
    }

    private static readonly string[] SingBoxCandidatePaths =
    [
        @".\engines\sing-box\sing-box.exe",
        @"%ProgramFiles%\sing-box\sing-box.exe",
        @"%ProgramFiles(x86)%\sing-box\sing-box.exe",
        "sing-box.exe"
    ];

    private static readonly string[] WireGuardCandidatePaths =
    [
        @"%ProgramFiles%\WireGuard\wireguard.exe",
        @"%ProgramFiles(x86)%\WireGuard\wireguard.exe",
        "wireguard.exe"
    ];

    private static readonly string[] AmneziaWireGuardCandidatePaths =
    [
        @".\engines\amneziawg\awg-quick.exe",
        @"%ProgramFiles%\AmneziaWG\awg-quick.exe",
        @"%ProgramFiles(x86)%\AmneziaWG\awg-quick.exe",
        "awg-quick.exe"
    ];
}
