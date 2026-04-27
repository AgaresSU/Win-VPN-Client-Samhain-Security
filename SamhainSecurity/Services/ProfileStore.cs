using System.IO;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class ProfileStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public ProfileStore()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var directory = Path.Combine(appData, "SamhainSecurity");
        Directory.CreateDirectory(directory);

        _filePath = Path.Combine(directory, "profiles.json");

        var legacyPath = Path.Combine(appData, "VpnClientWindows", "profiles.json");
        if (!File.Exists(_filePath) && File.Exists(legacyPath))
        {
            File.Copy(legacyPath, _filePath);
        }
    }

    public string FilePath => _filePath;

    public async Task<IReadOnlyList<VpnProfile>> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_filePath))
        {
            return [];
        }

        await using var stream = File.OpenRead(_filePath);
        var profiles = await JsonSerializer.DeserializeAsync<List<VpnProfile>>(stream, JsonOptions, cancellationToken);

        return profiles ?? [];
    }

    public async Task SaveAsync(IEnumerable<VpnProfile> profiles, CancellationToken cancellationToken = default)
    {
        var tempPath = _filePath + ".tmp";

        await using (var stream = File.Create(tempPath))
        {
            await JsonSerializer.SerializeAsync(stream, profiles, JsonOptions, cancellationToken);
        }

        File.Move(tempPath, _filePath, overwrite: true);
    }
}
