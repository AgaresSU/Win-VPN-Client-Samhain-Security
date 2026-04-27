using System.IO;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class AmneziaWireGuardService
{
    private readonly RuntimePathService _runtimePathService = new();

    public async Task<CommandResult> ConnectAsync(
        VpnProfile profile,
        string config,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(config))
        {
            return new CommandResult(1, string.Empty, "Вставьте AmneziaWG .conf");
        }

        var configPath = await WriteConfigAsync(profile, config, cancellationToken);
        var enginePath = EnginePathResolver.ResolveAmneziaWireGuard(profile.EnginePath);

        try
        {
            await ProcessRunner.RunProcessAsync(enginePath, ["down", configPath], cancellationToken);
            return await ProcessRunner.RunProcessAsync(enginePath, ["up", configPath], cancellationToken);
        }
        catch (Exception ex)
        {
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public async Task<CommandResult> DisconnectAsync(VpnProfile profile, string config, CancellationToken cancellationToken = default)
    {
        var configPath = await WriteConfigAsync(profile, config, cancellationToken);
        var enginePath = EnginePathResolver.ResolveAmneziaWireGuard(profile.EnginePath);

        try
        {
            return await ProcessRunner.RunProcessAsync(enginePath, ["down", configPath], cancellationToken);
        }
        catch (Exception ex)
        {
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public CommandResult GetStatus()
    {
        return new CommandResult(0, "Status depends on external awg-quick backend", string.Empty);
    }

    private async Task<string> WriteConfigAsync(
        VpnProfile profile,
        string config,
        CancellationToken cancellationToken)
    {
        var directory = _runtimePathService.GetProfileDirectory(profile.Id);
        var configPath = Path.Combine(directory, RuntimePathService.SanitizeName(profile.Name) + ".conf");
        await File.WriteAllTextAsync(configPath, config.Trim() + Environment.NewLine, cancellationToken);

        return configPath;
    }
}
