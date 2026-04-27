namespace VpnClientWindows.Models;

public sealed class ConnectionStateRecord
{
    public string ProfileId { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public VpnProtocolType Protocol { get; set; } = VpnProtocolType.WindowsNative;

    public string Status { get; set; } = "Unknown";

    public string LastCommand { get; set; } = string.Empty;

    public int LastExitCode { get; set; }

    public string LastMessage { get; set; } = string.Empty;

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}
