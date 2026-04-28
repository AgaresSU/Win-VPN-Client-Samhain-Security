using System.IO;
using System.Text.RegularExpressions;

namespace SamhainSecurity.Services;

public sealed class RuntimePathService
{
    private static readonly TimeSpan DefaultRetention = TimeSpan.FromHours(24);
    private readonly string _runtimeDirectory;

    public RuntimePathService()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _runtimeDirectory = Path.Combine(appData, "SamhainSecurity", "runtime");
        Directory.CreateDirectory(_runtimeDirectory);
    }

    public string GetProfileDirectory(string profileId)
    {
        var directory = Path.Combine(_runtimeDirectory, SanitizeName(profileId));
        Directory.CreateDirectory(directory);

        return directory;
    }

    public string RuntimeDirectory => _runtimeDirectory;

    public async Task<string> WriteProfileTextAsync(
        string profileId,
        string fileName,
        string content,
        CancellationToken cancellationToken = default)
    {
        var directory = GetProfileDirectory(profileId);
        var path = Path.Combine(directory, SanitizeName(fileName));
        await File.WriteAllTextAsync(path, content, cancellationToken);

        return path;
    }

    public void CleanupProfileDirectory(string profileId)
    {
        var directory = Path.Combine(_runtimeDirectory, SanitizeName(profileId));
        SafeDeleteDirectory(directory);
    }

    public void CleanupExpired()
    {
        CleanupExpired(DefaultRetention);
    }

    public void CleanupExpired(TimeSpan retention)
    {
        if (!Directory.Exists(_runtimeDirectory))
        {
            return;
        }

        foreach (var directory in Directory.GetDirectories(_runtimeDirectory))
        {
            try
            {
                var lastWrite = Directory.GetLastWriteTimeUtc(directory);
                if (DateTime.UtcNow - lastWrite > retention)
                {
                    SafeDeleteDirectory(directory);
                }
            }
            catch
            {
                // Runtime cleanup should never block app startup or disconnect.
            }
        }
    }

    public static string SanitizeName(string value)
    {
        var sanitized = Regex.Replace(value.Trim(), @"[^A-Za-z0-9_.-]+", "-").Trim('-', '.', '_');

        return string.IsNullOrWhiteSpace(sanitized)
            ? "samhain-security-profile"
            : sanitized;
    }

    private void SafeDeleteDirectory(string directory)
    {
        try
        {
            if (!Directory.Exists(directory) || !IsUnderRuntimeDirectory(directory))
            {
                return;
            }

            Directory.Delete(directory, recursive: true);
        }
        catch
        {
            // Best-effort cleanup. Engines may still hold files briefly during shutdown.
        }
    }

    private bool IsUnderRuntimeDirectory(string path)
    {
        var runtimeRoot = Path.GetFullPath(_runtimeDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        return target.StartsWith(runtimeRoot, StringComparison.OrdinalIgnoreCase);
    }
}
