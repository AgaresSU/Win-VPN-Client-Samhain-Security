namespace VpnClientWindows.Models;

public sealed class TunnelTypeOption
{
    public TunnelTypeOption(VpnTunnelType value)
    {
        Value = value;
        DisplayName = value.ToDisplayName();
    }

    public VpnTunnelType Value { get; }

    public string DisplayName { get; }
}
