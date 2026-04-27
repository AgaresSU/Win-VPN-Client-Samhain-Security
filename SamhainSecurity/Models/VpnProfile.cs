namespace SamhainSecurity.Models;

public sealed class VpnProfile
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    public string Name { get; set; } = string.Empty;

    public VpnProtocolType Protocol { get; set; } = VpnProtocolType.WindowsNative;

    public string ServerAddress { get; set; } = string.Empty;

    public int ServerPort { get; set; } = 443;

    public VpnTunnelType TunnelType { get; set; } = VpnTunnelType.Ikev2;

    public string UserName { get; set; } = string.Empty;

    public string EncryptedPassword { get; set; } = string.Empty;

    public string EncryptedL2tpPsk { get; set; } = string.Empty;

    public bool SplitTunneling { get; set; }

    public bool KillSwitchEnabled { get; set; }

    public bool DnsLeakProtectionEnabled { get; set; }

    public bool AllowLanTraffic { get; set; } = true;

    public string DnsServers { get; set; } = "1.1.1.1, 9.9.9.9";

    public string VlessUuid { get; set; } = string.Empty;

    public string VlessFlow { get; set; } = "xtls-rprx-vision";

    public string RealityServerName { get; set; } = string.Empty;

    public string RealityPublicKey { get; set; } = string.Empty;

    public string RealityShortId { get; set; } = string.Empty;

    public string RealityFingerprint { get; set; } = "chrome";

    public string EnginePath { get; set; } = string.Empty;

    public string EncryptedTunnelConfig { get; set; } = string.Empty;

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}
