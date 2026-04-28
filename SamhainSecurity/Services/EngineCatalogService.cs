using System.IO;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class EngineCatalogService
{
    private readonly EngineVersionService _engineVersionService = new();

    public string PortableEngineRoot => EnginePathResolver.GetPortableEngineRoot();

    public void EnsurePortableFolders()
    {
        TryCreateDirectory(PortableEngineRoot);
        TryCreateDirectory(EnginePathResolver.GetPortableEngineFolder("sing-box"));
        TryCreateDirectory(EnginePathResolver.GetPortableEngineFolder("wireguard"));
        TryCreateDirectory(EnginePathResolver.GetPortableEngineFolder("amneziawg"));
    }

    public async Task<IReadOnlyList<EngineCatalogEntry>> BuildCatalogAsync(
        VpnProtocolType selectedProtocol,
        string configuredPath,
        CancellationToken cancellationToken = default)
    {
        EnsurePortableFolders();

        var entries = new List<EngineCatalogEntry>
        {
            await BuildEntryAsync(
                "sing-box",
                VpnProtocolType.VlessReality,
                selectedProtocol == VpnProtocolType.VlessReality ? configuredPath : string.Empty,
                EnginePathResolver.ResolveSingBox,
                "sing-box",
                "Положите sing-box.exe в portable-папку или выберите файл вручную.",
                cancellationToken),
            await BuildEntryAsync(
                "WireGuard",
                VpnProtocolType.WireGuard,
                selectedProtocol == VpnProtocolType.WireGuard ? configuredPath : string.Empty,
                EnginePathResolver.ResolveWireGuard,
                "wireguard",
                "Установите WireGuard for Windows или положите wireguard.exe в portable-папку.",
                cancellationToken),
            await BuildEntryAsync(
                "AmneziaWG",
                VpnProtocolType.AmneziaWireGuard,
                selectedProtocol == VpnProtocolType.AmneziaWireGuard ? configuredPath : string.Empty,
                EnginePathResolver.ResolveAmneziaWireGuard,
                "amneziawg",
                "Положите awg-quick.exe в portable-папку или выберите файл вручную.",
                cancellationToken)
        };

        return entries;
    }

    private async Task<EngineCatalogEntry> BuildEntryAsync(
        string name,
        VpnProtocolType protocol,
        string configuredPath,
        Func<string?, string> resolver,
        string portableFolderName,
        string hint,
        CancellationToken cancellationToken)
    {
        var resolvedPath = resolver(configuredPath);
        var isAvailable = EnginePathResolver.IsPathAvailable(resolvedPath);
        var version = isAvailable
            ? await _engineVersionService.DetectVersionAsync(protocol, configuredPath, cancellationToken)
            : "не найден";

        return new EngineCatalogEntry
        {
            Name = name,
            Protocol = protocol,
            IsAvailable = isAvailable,
            Status = isAvailable ? "готов" : "не найден",
            Version = version,
            Path = resolvedPath,
            PortableFolder = EnginePathResolver.GetPortableEngineFolder(portableFolderName),
            Hint = isAvailable ? "Можно использовать" : hint
        };
    }

    private static void TryCreateDirectory(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
        }
        catch
        {
            // Installed packages can live under Program Files. Existing packaged folders are enough for detection.
        }
    }
}
