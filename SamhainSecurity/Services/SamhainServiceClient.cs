using System.IO.Pipes;
using System.IO;
using System.Text;
using System.Text.Json;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class SamhainServiceClient
{
    private const string PipeName = "SamhainSecurity.Service.v1";
    private static readonly TimeSpan PingTimeout = TimeSpan.FromMilliseconds(650);
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(45);

    public async Task<bool> IsAvailableAsync(CancellationToken cancellationToken = default)
    {
        var response = await SendAsync(new ServicePipeRequest { Action = "ping" }, PingTimeout, cancellationToken);
        return response?.IsSuccess == true;
    }

    public Task<CommandResult?> ConnectWindowsNativeAsync(
        VpnProfile profile,
        string password,
        CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "connect-windows-native",
            ProfileName = profile.Name,
            UserName = profile.UserName,
            Password = password
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> DisconnectWindowsNativeAsync(
        string profileName,
        CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "disconnect-windows-native",
            ProfileName = profileName
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> GetWindowsNativeStatusAsync(
        string profileName,
        CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "status-windows-native",
            ProfileName = profileName
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> ConnectTunnelAsync(
        VpnProfile profile,
        string tunnelConfig,
        CancellationToken cancellationToken = default)
    {
        var request = BuildTunnelRequest("tunnel-connect", profile, tunnelConfig);
        return SendAsync(request, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> DisconnectTunnelAsync(
        VpnProfile profile,
        string tunnelConfig,
        CancellationToken cancellationToken = default)
    {
        var request = BuildTunnelRequest("tunnel-disconnect", profile, tunnelConfig);
        return SendAsync(request, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> GetTunnelStatusAsync(
        VpnProfile profile,
        CancellationToken cancellationToken = default)
    {
        var request = BuildTunnelRequest("tunnel-status", profile, string.Empty);
        return SendAsync(request, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> ApplyProtectionAsync(
        VpnProfile profile,
        CancellationToken cancellationToken = default)
    {
        var request = BuildProtectionRequest("protection-apply", profile);
        return SendAsync(request, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> PreviewProtectionAsync(
        VpnProfile profile,
        CancellationToken cancellationToken = default)
    {
        var request = BuildProtectionRequest("protection-preview", profile);
        return SendAsync(request, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> RemoveProtectionAsync(CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "protection-remove"
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> ResetProtectionAsync(CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "protection-reset"
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> RunProtectionWatchdogAsync(CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "protection-watchdog-check"
        }, CommandTimeout, cancellationToken);
    }

    public Task<CommandResult?> GetProtectionStatusAsync(CancellationToken cancellationToken = default)
    {
        return SendAsync(new ServicePipeRequest
        {
            Action = "protection-status"
        }, CommandTimeout, cancellationToken);
    }

    private static ServicePipeRequest BuildProtectionRequest(string action, VpnProfile profile)
    {
        return new ServicePipeRequest
        {
            Action = action,
            ProfileName = profile.Name,
            ProtocolName = profile.Protocol.ToDisplayName(),
            ServerAddress = profile.ServerAddress,
            ServerPort = profile.ServerPort,
            EnginePath = profile.EnginePath,
            TunnelInterfaceAlias = profile.Name,
            KillSwitchEnabled = profile.KillSwitchEnabled,
            DnsLeakProtectionEnabled = profile.DnsLeakProtectionEnabled,
            AllowLanTraffic = profile.AllowLanTraffic,
            DnsServers = profile.DnsServers
        };
    }

    private static ServicePipeRequest BuildTunnelRequest(
        string action,
        VpnProfile profile,
        string tunnelConfig)
    {
        return new ServicePipeRequest
        {
            Action = action,
            ProfileId = profile.Id,
            ProfileName = profile.Name,
            ProtocolName = profile.Protocol.ToString(),
            ServerAddress = profile.ServerAddress,
            ServerPort = profile.ServerPort,
            EnginePath = profile.EnginePath,
            TunnelConfig = tunnelConfig,
            TunnelInterfaceAlias = profile.Name,
            VlessUuid = profile.VlessUuid,
            VlessFlow = profile.VlessFlow,
            RealityServerName = profile.RealityServerName,
            RealityPublicKey = profile.RealityPublicKey,
            RealityShortId = profile.RealityShortId,
            RealityFingerprint = profile.RealityFingerprint
        };
    }

    private static async Task<CommandResult?> SendAsync(
        ServicePipeRequest request,
        TimeSpan timeoutValue,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var pipe = new NamedPipeClientStream(
                ".",
                PipeName,
                PipeDirection.InOut,
                PipeOptions.Asynchronous);

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(timeoutValue);
            await pipe.ConnectAsync(timeout.Token);

            await using var writer = new StreamWriter(pipe, Encoding.UTF8, leaveOpen: true)
            {
                AutoFlush = true
            };
            using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);

            await writer.WriteLineAsync(JsonSerializer.Serialize(request));
            var responseJson = await reader.ReadLineAsync(timeout.Token);
            var response = JsonSerializer.Deserialize<ServicePipeResponse>(responseJson ?? "{}");

            return response is null
                ? null
                : new CommandResult(response.ExitCode, response.Output, response.Error);
        }
        catch
        {
            return null;
        }
    }
}

public sealed class ServicePipeRequest
{
    public string Action { get; set; } = string.Empty;

    public string ProfileId { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public string UserName { get; set; } = string.Empty;

    public string Password { get; set; } = string.Empty;

    public string ProtocolName { get; set; } = string.Empty;

    public string ServerAddress { get; set; } = string.Empty;

    public int ServerPort { get; set; }

    public string EnginePath { get; set; } = string.Empty;

    public string TunnelConfig { get; set; } = string.Empty;

    public string TunnelInterfaceAlias { get; set; } = string.Empty;

    public string VlessUuid { get; set; } = string.Empty;

    public string VlessFlow { get; set; } = string.Empty;

    public string RealityServerName { get; set; } = string.Empty;

    public string RealityPublicKey { get; set; } = string.Empty;

    public string RealityShortId { get; set; } = string.Empty;

    public string RealityFingerprint { get; set; } = string.Empty;

    public bool KillSwitchEnabled { get; set; }

    public bool DnsLeakProtectionEnabled { get; set; }

    public bool AllowLanTraffic { get; set; }

    public string DnsServers { get; set; } = string.Empty;
}

public sealed class ServicePipeResponse
{
    public int ExitCode { get; set; }

    public string Output { get; set; } = string.Empty;

    public string Error { get; set; } = string.Empty;
}
