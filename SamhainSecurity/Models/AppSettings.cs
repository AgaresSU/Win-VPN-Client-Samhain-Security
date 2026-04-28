namespace SamhainSecurity.Models;

public sealed class AppSettings
{
    public bool LaunchAtStartup { get; set; }

    public bool AutoConnectLastProfile { get; set; }

    public bool AutoReconnectOnSystemChange { get; set; } = true;

    public bool AutoFailoverOnConnectFailure { get; set; } = true;

    public bool ConnectBestServerAutomatically { get; set; }

    public bool AutoRefreshSubscriptions { get; set; } = true;

    public bool EnableConnectionWatchdog { get; set; } = true;

    public bool FirstRunDismissed { get; set; }

    public string LastProfileId { get; set; } = string.Empty;

    public string LastSubscriptionSourceId { get; set; } = string.Empty;

    public bool AdvancedSettingsExpanded { get; set; }
}
