using System.IO;
using VpnClientWindows.Models;

namespace VpnClientWindows.Services;

public sealed class WireGuardTunnelService
{
    private readonly RuntimePathService _runtimePathService = new();

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

            return installResult.IsSuccess
                ? installResult with { Output = $"WireGuard service installed: WireGuardTunnel${tunnelName}" }
                : installResult;
        }
        catch (Exception ex)
        {
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public Task<CommandResult> DisconnectAsync(VpnProfile profile, CancellationToken cancellationToken = default)
    {
        var tunnelName = GetTunnelName(profile);
        var enginePath = EnginePathResolver.ResolveWireGuard(profile.EnginePath);

        try
        {
            return ProcessRunner.RunProcessAsync(enginePath, ["/uninstalltunnelservice", tunnelName], cancellationToken);
        }
        catch (Exception ex)
        {
            return Task.FromResult(new CommandResult(1, string.Empty, ex.Message));
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
