using System.IO;
using System.IO.Compression;
using System.Text;

namespace SamhainSecurity.Services;

public sealed class DiagnosticsBundleService
{
    private readonly ProfileStore _profileStore;
    private readonly ConnectionStateStore _connectionStateStore;
    private readonly StructuredLogService _structuredLogService;

    public DiagnosticsBundleService(
        ProfileStore profileStore,
        ConnectionStateStore connectionStateStore,
        StructuredLogService structuredLogService)
    {
        _profileStore = profileStore;
        _connectionStateStore = connectionStateStore;
        _structuredLogService = structuredLogService;
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
        - structured JSONL logs

        Runtime engine configs are intentionally excluded because some external engines require plaintext config files.
        """);

        AddFileIfExists(archive, _profileStore.FilePath, "profiles.encrypted.json");
        AddFileIfExists(archive, _connectionStateStore.FilePath, "connection-state.json");

        if (Directory.Exists(_structuredLogService.LogDirectory))
        {
            foreach (var logFile in Directory.GetFiles(_structuredLogService.LogDirectory, "*.jsonl"))
            {
                AddFileIfExists(archive, logFile, "logs/" + Path.GetFileName(logFile));
            }
        }
    }

    private static void AddFileIfExists(ZipArchive archive, string sourcePath, string entryName)
    {
        if (File.Exists(sourcePath))
        {
            archive.CreateEntryFromFile(sourcePath, entryName, CompressionLevel.Optimal);
        }
    }

    private static void AddText(ZipArchive archive, string entryName, string content)
    {
        var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
        using var stream = entry.Open();
        using var writer = new StreamWriter(stream, Encoding.UTF8);
        writer.Write(content);
    }
}
