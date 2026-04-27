using System.IO;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class ConnectionStateStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public ConnectionStateStore()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var directory = Path.Combine(appData, "SamhainSecurity");
        Directory.CreateDirectory(directory);

        _filePath = Path.Combine(directory, "connection-state.json");
    }

    public string FilePath => _filePath;

    public async Task<IReadOnlyList<ConnectionStateRecord>> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_filePath))
        {
            return [];
        }

        await using var stream = File.OpenRead(_filePath);
        var records = await JsonSerializer.DeserializeAsync<List<ConnectionStateRecord>>(stream, JsonOptions, cancellationToken);

        return records ?? [];
    }

    public async Task UpdateAsync(
        VpnProfile profile,
        string command,
        string status,
        CommandResult result,
        CancellationToken cancellationToken = default)
    {
        var records = (await LoadAsync(cancellationToken)).ToList();
        var existing = records.FirstOrDefault(record => record.ProfileId == profile.Id);

        if (existing is null)
        {
            existing = new ConnectionStateRecord { ProfileId = profile.Id };
            records.Add(existing);
        }

        existing.ProfileName = profile.Name;
        existing.Protocol = profile.Protocol;
        existing.Status = status;
        existing.LastCommand = command;
        existing.LastExitCode = result.ExitCode;
        existing.LastMessage = result.CombinedOutput;
        existing.UpdatedAt = DateTimeOffset.UtcNow;

        await using var stream = File.Create(_filePath);
        await JsonSerializer.SerializeAsync(stream, records, JsonOptions, cancellationToken);
    }
}
