namespace SamhainSecurity.Models;

public sealed class EngineCatalogEntry
{
    public string Name { get; set; } = string.Empty;

    public VpnProtocolType Protocol { get; set; }

    public bool IsAvailable { get; set; }

    public string Status { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    public string Path { get; set; } = string.Empty;

    public string PortableFolder { get; set; } = string.Empty;

    public string Hint { get; set; } = string.Empty;
}
