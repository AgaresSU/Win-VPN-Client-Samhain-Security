using System.IO;

namespace SamhainSecurity.Models;

public static class AppRoutingPathParser
{
    public static AppRoutingTargets Parse(string value)
    {
        var processPaths = new List<string>();
        var processNames = new List<string>();

        foreach (var item in Split(value))
        {
            var normalized = Normalize(item);
            if (string.IsNullOrWhiteSpace(normalized))
            {
                continue;
            }

            if (LooksLikePath(normalized))
            {
                processPaths.Add(Environment.ExpandEnvironmentVariables(normalized));
            }
            else
            {
                processNames.Add(Path.GetFileName(normalized));
            }
        }

        return new AppRoutingTargets(
            processPaths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            processNames.Distinct(StringComparer.OrdinalIgnoreCase).ToArray());
    }

    private static IEnumerable<string> Split(string value)
    {
        return value.Split(
            ['\r', '\n', ';'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    }

    private static string Normalize(string value)
    {
        return value.Trim().Trim('"', '\'');
    }

    private static bool LooksLikePath(string value)
    {
        return Path.IsPathRooted(value)
            || value.Contains(Path.DirectorySeparatorChar, StringComparison.Ordinal)
            || value.Contains(Path.AltDirectorySeparatorChar, StringComparison.Ordinal);
    }
}

public sealed record AppRoutingTargets(string[] ProcessPaths, string[] ProcessNames)
{
    public int Count => ProcessPaths.Length + ProcessNames.Length;

    public bool HasTargets => Count > 0;
}
