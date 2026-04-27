namespace SamhainSecurity.Models;

public sealed class AppSettings
{
    public bool LaunchAtStartup { get; set; }

    public bool AutoConnectLastProfile { get; set; }

    public string LastProfileId { get; set; } = string.Empty;

    public bool AdvancedSettingsExpanded { get; set; }
}
