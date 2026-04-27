using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class MultiProtocolVpnService
{
    private readonly SamhainServiceClient _serviceClient = new();
    private readonly PowerShellVpnService _windowsNativeService = new();
    private readonly SingBoxVpnService _singBoxVpnService = new();
    private readonly WireGuardTunnelService _wireGuardTunnelService = new();
    private readonly AmneziaWireGuardService _amneziaWireGuardService = new();

    public async Task<CommandResult> PrepareProfileAsync(
        VpnProfile profile,
        string l2tpPsk,
        CancellationToken cancellationToken = default)
    {
        return profile.Protocol == VpnProtocolType.WindowsNative
            ? await _windowsNativeService.SaveOrUpdateProfileAsync(profile, l2tpPsk, cancellationToken)
            : new CommandResult(0, "Профиль сохранен локально", string.Empty);
    }

    public Task<CommandResult> RemoveProfileAsync(VpnProfile profile, string tunnelConfig, CancellationToken cancellationToken = default)
    {
        return profile.Protocol == VpnProtocolType.WindowsNative
            ? _windowsNativeService.RemoveProfileAsync(profile.Name, cancellationToken)
            : DisconnectAsync(profile, tunnelConfig, cancellationToken);
    }

    public async Task<CommandResult> ConnectAsync(
        VpnProfile profile,
        string password,
        string tunnelConfig,
        CancellationToken cancellationToken = default)
    {
        if (profile.Protocol != VpnProtocolType.WindowsNative)
        {
            var serviceResult = await _serviceClient.ConnectTunnelAsync(profile, tunnelConfig, cancellationToken);
            if (serviceResult is not null)
            {
                return serviceResult;
            }
        }

        return await ConnectLocalAsync(profile, password, tunnelConfig, cancellationToken);
    }

    public async Task<CommandResult> DisconnectAsync(
        VpnProfile profile,
        string tunnelConfig,
        CancellationToken cancellationToken = default)
    {
        if (profile.Protocol != VpnProtocolType.WindowsNative)
        {
            var serviceResult = await _serviceClient.DisconnectTunnelAsync(profile, tunnelConfig, cancellationToken);
            if (serviceResult is not null)
            {
                return serviceResult;
            }
        }

        return await DisconnectLocalAsync(profile, tunnelConfig, cancellationToken);
    }

    public async Task<CommandResult> GetStatusAsync(
        VpnProfile profile,
        CancellationToken cancellationToken = default)
    {
        if (profile.Protocol != VpnProtocolType.WindowsNative)
        {
            var serviceResult = await _serviceClient.GetTunnelStatusAsync(profile, cancellationToken);
            if (serviceResult is not null)
            {
                return serviceResult;
            }
        }

        return await GetLocalStatusAsync(profile, cancellationToken);
    }

    private Task<CommandResult> ConnectLocalAsync(
        VpnProfile profile,
        string password,
        string tunnelConfig,
        CancellationToken cancellationToken)
    {
        return profile.Protocol switch
        {
            VpnProtocolType.WindowsNative => _windowsNativeService.ConnectAsync(profile, password, cancellationToken),
            VpnProtocolType.VlessReality => _singBoxVpnService.ConnectAsync(profile, cancellationToken),
            VpnProtocolType.WireGuard => _wireGuardTunnelService.ConnectAsync(profile, tunnelConfig, cancellationToken),
            VpnProtocolType.AmneziaWireGuard => _amneziaWireGuardService.ConnectAsync(profile, tunnelConfig, cancellationToken),
            _ => Task.FromResult(new CommandResult(1, string.Empty, "Неизвестный протокол"))
        };
    }

    private Task<CommandResult> DisconnectLocalAsync(
        VpnProfile profile,
        string tunnelConfig,
        CancellationToken cancellationToken)
    {
        return profile.Protocol switch
        {
            VpnProtocolType.WindowsNative => _windowsNativeService.DisconnectAsync(profile.Name, cancellationToken),
            VpnProtocolType.VlessReality => Task.FromResult(_singBoxVpnService.Disconnect(profile.Id)),
            VpnProtocolType.WireGuard => _wireGuardTunnelService.DisconnectAsync(profile, cancellationToken),
            VpnProtocolType.AmneziaWireGuard => _amneziaWireGuardService.DisconnectAsync(profile, tunnelConfig, cancellationToken),
            _ => Task.FromResult(new CommandResult(1, string.Empty, "Неизвестный протокол"))
        };
    }

    private Task<CommandResult> GetLocalStatusAsync(
        VpnProfile profile,
        CancellationToken cancellationToken)
    {
        return profile.Protocol switch
        {
            VpnProtocolType.WindowsNative => _windowsNativeService.GetStatusAsync(profile.Name, cancellationToken),
            VpnProtocolType.VlessReality => Task.FromResult(_singBoxVpnService.GetStatus(profile.Id)),
            VpnProtocolType.WireGuard => _wireGuardTunnelService.GetStatusAsync(profile, cancellationToken),
            VpnProtocolType.AmneziaWireGuard => Task.FromResult(_amneziaWireGuardService.GetStatus()),
            _ => Task.FromResult(new CommandResult(1, string.Empty, "Неизвестный протокол"))
        };
    }
}
