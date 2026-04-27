namespace VpnClientWindows.Models;

public sealed class StructuredLogEntry
{
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    public string Level { get; set; } = "info";

    public string Event { get; set; } = string.Empty;

    public string Message { get; set; } = string.Empty;

    public string? ProfileId { get; set; }

    public string? ProfileName { get; set; }

    public string? Protocol { get; set; }

    public int? ExitCode { get; set; }
}
