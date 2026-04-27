namespace SamhainSecurity.Models;

public sealed class AppSettings
{
    public bool LaunchAtStartup { get; set; }

    public bool AutoConnectLastProfile { get; set; }

    public bool AutoReconnectOnSystemChange { get; set; } = true;

    public string LastProfileId { get; set; } = string.Empty;

    public string LastSubscriptionSourceId { get; set; } = string.Empty;

    public bool AdvancedSettingsExpanded { get; set; }
}
