namespace SamhainSecurity.Models;

public enum VpnTunnelType
{
    Automatic,
    Ikev2,
    Sstp,
    L2tp,
    Pptp
}

public static class VpnTunnelTypeExtensions
{
    public static string ToPowerShellValue(this VpnTunnelType tunnelType)
    {
        return tunnelType switch
        {
            VpnTunnelType.Automatic => "Automatic",
            VpnTunnelType.Ikev2 => "Ikev2",
            VpnTunnelType.Sstp => "Sstp",
            VpnTunnelType.L2tp => "L2tp",
            VpnTunnelType.Pptp => "Pptp",
            _ => "Automatic"
        };
    }

    public static string ToDisplayName(this VpnTunnelType tunnelType)
    {
        return tunnelType switch
        {
            VpnTunnelType.Automatic => "Automatic",
            VpnTunnelType.Ikev2 => "IKEv2",
            VpnTunnelType.Sstp => "SSTP",
            VpnTunnelType.L2tp => "L2TP",
            VpnTunnelType.Pptp => "PPTP",
            _ => tunnelType.ToString()
        };
    }
}
