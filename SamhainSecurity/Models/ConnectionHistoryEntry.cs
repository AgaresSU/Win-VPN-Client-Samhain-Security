namespace SamhainSecurity.Models;

public sealed class ConnectionHistoryEntry
{
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    public string Action { get; set; } = string.Empty;

    public string ProfileId { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public VpnProtocolType Protocol { get; set; } = VpnProtocolType.WindowsNative;

    public string Server { get; set; } = string.Empty;

    public bool Success { get; set; }

    public string Message { get; set; } = string.Empty;
}
