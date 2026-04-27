namespace VpnClientWindows.Models;

public enum VpnProtocolType
{
    WindowsNative,
    VlessReality,
    WireGuard,
    AmneziaWireGuard
}

public static class VpnProtocolTypeExtensions
{
    public static string ToDisplayName(this VpnProtocolType protocolType)
    {
        return protocolType switch
        {
            VpnProtocolType.WindowsNative => "Windows VPN",
            VpnProtocolType.VlessReality => "VLESS TCP Reality",
            VpnProtocolType.WireGuard => "WireGuard",
            VpnProtocolType.AmneziaWireGuard => "AmneziaWG",
            _ => protocolType.ToString()
        };
    }
}
