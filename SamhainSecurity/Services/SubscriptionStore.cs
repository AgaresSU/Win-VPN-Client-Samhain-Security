using System.IO;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class SubscriptionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly SecureDataProtector _protector;
    private readonly string _filePath;

    public SubscriptionStore(SecureDataProtector protector)
    {
        _protector = protector;

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var directory = Path.Combine(appData, "SamhainSecurity");
        Directory.CreateDirectory(directory);

        _filePath = Path.Combine(directory, "subscriptions.json");
    }

    public string FilePath => _filePath;

    public async Task<IReadOnlyList<SubscriptionSource>> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_filePath))
        {
            return [];
        }

        await using var stream = File.OpenRead(_filePath);
        var sources = await JsonSerializer.DeserializeAsync<List<SubscriptionSource>>(stream, JsonOptions, cancellationToken);

        return sources ?? [];
    }

    public async Task SaveAsync(IEnumerable<SubscriptionSource> sources, CancellationToken cancellationToken = default)
    {
        var tempPath = _filePath + ".tmp";

        await using (var stream = File.Create(tempPath))
        {
            await JsonSerializer.SerializeAsync(stream, sources, JsonOptions, cancellationToken);
        }

        File.Move(tempPath, _filePath, overwrite: true);
    }

    public string ProtectUrl(string url)
    {
        return _protector.Protect(url);
    }

    public string UnprotectUrl(SubscriptionSource source)
    {
        return _protector.Unprotect(source.EncryptedUrl);
    }
}
