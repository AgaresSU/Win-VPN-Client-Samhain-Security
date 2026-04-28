using System.IO;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class ConnectionHistoryStore
{
    private const int MaxEntries = 200;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public ConnectionHistoryStore()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var directory = Path.Combine(appData, "SamhainSecurity");
        Directory.CreateDirectory(directory);

        _filePath = Path.Combine(directory, "connection-history.json");
    }

    public string FilePath => _filePath;

    public async Task<IReadOnlyList<ConnectionHistoryEntry>> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_filePath))
        {
            return [];
        }

        await using var stream = File.OpenRead(_filePath);
        var entries = await JsonSerializer.DeserializeAsync<List<ConnectionHistoryEntry>>(stream, JsonOptions, cancellationToken);

        return entries ?? [];
    }

    public async Task AppendAsync(ConnectionHistoryEntry entry, CancellationToken cancellationToken = default)
    {
        var entries = (await LoadAsync(cancellationToken)).ToList();
        entry.Message = SecretRedactor.Redact(entry.Message);
        entries.Insert(0, entry);

        if (entries.Count > MaxEntries)
        {
            entries.RemoveRange(MaxEntries, entries.Count - MaxEntries);
        }

        var tempPath = _filePath + ".tmp";
        await using (var stream = File.Create(tempPath))
        {
            await JsonSerializer.SerializeAsync(stream, entries, JsonOptions, cancellationToken);
        }

        File.Move(tempPath, _filePath, overwrite: true);
    }
}
