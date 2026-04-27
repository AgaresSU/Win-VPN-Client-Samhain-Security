using System.IO;
using System.Text.RegularExpressions;

namespace SamhainSecurity.Services;

public sealed class RuntimePathService
{
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

    public static string SanitizeName(string value)
    {
        var sanitized = Regex.Replace(value.Trim(), @"[^A-Za-z0-9_.-]+", "-").Trim('-', '.', '_');

        return string.IsNullOrWhiteSpace(sanitized)
            ? "samhain-security-profile"
            : sanitized;
    }
}
