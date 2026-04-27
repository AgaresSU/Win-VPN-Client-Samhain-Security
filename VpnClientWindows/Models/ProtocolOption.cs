namespace VpnClientWindows.Models;

public sealed class ProtocolOption
{
    public ProtocolOption(VpnProtocolType value)
    {
        Value = value;
        DisplayName = value.ToDisplayName();
    }

    public VpnProtocolType Value { get; }

    public string DisplayName { get; }
}
