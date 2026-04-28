using System.IO;
using System.IO.Compression;
using System.Text;

namespace SamhainSecurity.Services;

public sealed class DiagnosticsBundleService
{
    private readonly ProfileStore _profileStore;
    private readonly ConnectionStateStore _connectionStateStore;
    private readonly StructuredLogService _structuredLogService;
    private readonly ConnectionHistoryStore _connectionHistoryStore;

    public DiagnosticsBundleService(
        ProfileStore profileStore,
        ConnectionStateStore connectionStateStore,
        StructuredLogService structuredLogService,
        ConnectionHistoryStore connectionHistoryStore)
    {
        _profileStore = profileStore;
        _connectionStateStore = connectionStateStore;
        _structuredLogService = structuredLogService;
        _connectionHistoryStore = connectionHistoryStore;
    }

    public void Export(string destinationPath)
    {
        if (File.Exists(destinationPath))
        {
            File.Delete(destinationPath);
        }

        using var archive = ZipFile.Open(destinationPath, ZipArchiveMode.Create);

        AddText(archive, "README.txt", """
        Samhain Security diagnostics bundle.

        Included:
        - encrypted profiles file when present
        - connection state file when present
        - connection history when present
        - redacted structured JSONL logs
        - support-report.txt with local environment metadata

        Runtime engine configs are intentionally excluded because some external engines require plaintext config files.
        """);

        AddText(archive, "support-report.txt", BuildSupportReport());
        AddFileIfExists(archive, _profileStore.FilePath, "profiles.encrypted.json");
        AddFileIfExists(archive, _connectionStateStore.FilePath, "connection-state.json");
        AddFileIfExists(archive, _connectionHistoryStore.FilePath, "connection-history.json");

        if (Directory.Exists(_structuredLogService.LogDirectory))
        {
            foreach (var logFile in Directory.GetFiles(_structuredLogService.LogDirectory, "*.jsonl"))
            {
                AddRedactedFileIfExists(archive, logFile, "logs/" + Path.GetFileName(logFile));
            }
        }
    }

    private static string BuildSupportReport()
    {
        var builder = new StringBuilder();
        builder.AppendLine("Samhain Security support report");
        builder.AppendLine($"Created: {DateTimeOffset.Now:O}");
        builder.AppendLine($"Version: {typeof(DiagnosticsBundleService).Assembly.GetName().Version}");
        builder.AppendLine($"OS: {Environment.OSVersion}");
        builder.AppendLine($"Process: {(Environment.Is64BitProcess ? "x64" : "x86")}");
        builder.AppendLine($"Admin: {(AdminElevationService.IsAdministrator() ? "yes" : "no")}");
        builder.AppendLine($"App directory: {AppContext.BaseDirectory}");
        builder.AppendLine($"Current directory: {Environment.CurrentDirectory}");
        return builder.ToString();
    }

    private static void AddFileIfExists(ZipArchive archive, string sourcePath, string entryName)
    {
        if (File.Exists(sourcePath))
        {
            archive.CreateEntryFromFile(sourcePath, entryName, CompressionLevel.Optimal);
        }
    }

    private static void AddRedactedFileIfExists(ZipArchive archive, string sourcePath, string entryName)
    {
        if (!File.Exists(sourcePath))
        {
            return;
        }

        AddText(archive, entryName, SecretRedactor.Redact(File.ReadAllText(sourcePath, Encoding.UTF8)));
    }

    private static void AddText(ZipArchive archive, string entryName, string content)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var stream = entry.Open();
        using var writer = new StreamWriter(stream, Encoding.UTF8);
        writer.Write(content);
    }
}
