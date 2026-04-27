using VpnClientWindows.Models;

namespace VpnClientWindows.Services;

public sealed record EngineAvailability(string Label, bool IsAvailable, bool NeedsAdmin);

public sealed class EngineAvailabilityService
{
    public EngineAvailability GetAvailability(VpnProtocolType protocol, string enginePath)
    {
        return protocol switch
        {
            VpnProtocolType.WindowsNative => new EngineAvailability(
                AdminElevationService.IsAdministrator()
                    ? "Windows Native ready"
                    : "Admin recommended",
                true,
                !AdminElevationService.IsAdministrator()),
            VpnProtocolType.VlessReality => ResolveExternal("sing-box", EnginePathResolver.ResolveSingBox(enginePath), needsAdmin: true),
            VpnProtocolType.WireGuard => ResolveExternal("WireGuard", EnginePathResolver.ResolveWireGuard(enginePath), needsAdmin: true),
            VpnProtocolType.AmneziaWireGuard => ResolveExternal("AmneziaWG", EnginePathResolver.ResolveAmneziaWireGuard(enginePath), needsAdmin: true),
            _ => new EngineAvailability("Unknown", false, false)
        };
    }

    private static EngineAvailability ResolveExternal(string label, string path, bool needsAdmin)
    {
        var isAvailable = EnginePathResolver.IsPathAvailable(path);
        var adminMissing = needsAdmin && !AdminElevationService.IsAdministrator();

        if (!isAvailable)
        {
            return new EngineAvailability($"{label} missing", false, adminMissing);
        }

        return new EngineAvailability(
            adminMissing ? $"{label} found, admin needed" : $"{label} ready",
            true,
            adminMissing);
    }
}
