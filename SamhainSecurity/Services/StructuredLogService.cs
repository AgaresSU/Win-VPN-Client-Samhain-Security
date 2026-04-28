using System.IO;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class StructuredLogService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false
    };

    private readonly string _logDirectory;

    public StructuredLogService()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        _logDirectory = Path.Combine(appData, "SamhainSecurity", "logs");
        Directory.CreateDirectory(_logDirectory);
    }

    public string LogDirectory => _logDirectory;

    public void WriteInfo(string eventName, string message)
    {
        Write(new StructuredLogEntry
        {
            Level = "info",
            Event = eventName,
            Message = SecretRedactor.Redact(message)
        });
    }

    public void WriteCommand(string eventName, VpnProfile profile, CommandResult result)
    {
        Write(new StructuredLogEntry
        {
            Level = result.IsSuccess ? "info" : "error",
            Event = eventName,
            Message = SecretRedactor.Redact(result.CombinedOutput),
            ProfileId = profile.Id,
            ProfileName = profile.Name,
            Protocol = profile.Protocol.ToDisplayName(),
            ExitCode = result.ExitCode
        });
    }

    private void Write(StructuredLogEntry entry)
    {
        var path = Path.Combine(_logDirectory, $"samhain-{DateTimeOffset.Now:yyyyMMdd}.jsonl");
        var line = JsonSerializer.Serialize(entry, JsonOptions);
        File.AppendAllText(path, line + Environment.NewLine);
    }
}
