using System.IO;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class WireGuardTunnelService
{
    private readonly RuntimePathService _runtimePathService = new();

    public WireGuardTunnelService()
    {
        _runtimePathService.CleanupExpired();
    }

    public async Task<CommandResult> ConnectAsync(
        VpnProfile profile,
        string config,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(config))
        {
            return new CommandResult(1, string.Empty, "Вставьте WireGuard .conf");
        }

        var tunnelName = GetTunnelName(profile);
        var configPath = await WriteConfigAsync(profile, tunnelName, config, cancellationToken);
        var enginePath = EnginePathResolver.ResolveWireGuard(profile.EnginePath);

        try
        {
            await ProcessRunner.RunProcessAsync(enginePath, ["/uninstalltunnelservice", tunnelName], cancellationToken);
            var installResult = await ProcessRunner.RunProcessAsync(enginePath, ["/installtunnelservice", configPath], cancellationToken);
            _runtimePathService.CleanupProfileDirectory(profile.Id);

            return installResult.IsSuccess
                ? installResult with { Output = $"WireGuard service installed: WireGuardTunnel${tunnelName}" }
                : installResult;
        }
        catch (Exception ex)
        {
            _runtimePathService.CleanupProfileDirectory(profile.Id);
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public async Task<CommandResult> DisconnectAsync(VpnProfile profile, CancellationToken cancellationToken = default)
    {
        var tunnelName = GetTunnelName(profile);
        var enginePath = EnginePathResolver.ResolveWireGuard(profile.EnginePath);

        try
        {
            var result = await ProcessRunner.RunProcessAsync(enginePath, ["/uninstalltunnelservice", tunnelName], cancellationToken);
            _runtimePathService.CleanupProfileDirectory(profile.Id);
            return result;
        }
        catch (Exception ex)
        {
            _runtimePathService.CleanupProfileDirectory(profile.Id);
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public Task<CommandResult> GetStatusAsync(VpnProfile profile, CancellationToken cancellationToken = default)
    {
        var tunnelName = GetTunnelName(profile);
        return ProcessRunner.RunProcessAsync("sc.exe", ["query", $"WireGuardTunnel${tunnelName}"], cancellationToken);
    }

    private async Task<string> WriteConfigAsync(
        VpnProfile profile,
        string tunnelName,
        string config,
        CancellationToken cancellationToken)
    {
        var directory = _runtimePathService.GetProfileDirectory(profile.Id);
        var configPath = Path.Combine(directory, tunnelName + ".conf");
        await File.WriteAllTextAsync(configPath, config.Trim() + Environment.NewLine, cancellationToken);

        return configPath;
    }

    private static string GetTunnelName(VpnProfile profile)
    {
        return RuntimePathService.SanitizeName(profile.Name);
    }
}
