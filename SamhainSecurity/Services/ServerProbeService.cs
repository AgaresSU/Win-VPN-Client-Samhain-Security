using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class ServerProbeService
{
    private const int DefaultTimeoutMs = 1200;

    public async Task<ServerProbeResult> ProbeAsync(
        VpnProfile profile,
        string tunnelConfig = "",
        CancellationToken cancellationToken = default)
    {
        if (!TryGetEndpoint(profile, tunnelConfig, out var host, out var port))
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Skipped, "нет адреса");
        }

        return profile.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            ? await ProbeUdpEndpointAsync(host, port, cancellationToken)
            : await ProbeTcpEndpointAsync(host, port, cancellationToken);
    }

    private static async Task<ServerProbeResult> ProbeTcpEndpointAsync(
        string host,
        int port,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(DefaultTimeoutMs));

        using var client = new TcpClient();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            await client.ConnectAsync(host, port, timeout.Token);
            stopwatch.Stop();

            return ServerProbeResult.Success(
                ServerProbeStatus.TcpOk,
                ClampElapsed(stopwatch.ElapsedMilliseconds),
                "доступен");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Failed, "таймаут");
        }
        catch (SocketException)
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Failed, "нет ответа");
        }
        catch
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Failed, "ошибка проверки");
        }
    }

    private static async Task<ServerProbeResult> ProbeUdpEndpointAsync(
        string host,
        int port,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(DefaultTimeoutMs));

        var stopwatch = Stopwatch.StartNew();

        try
        {
            var addresses = await Dns.GetHostAddressesAsync(host, timeout.Token);
            stopwatch.Stop();

            return addresses.Length == 0
                ? ServerProbeResult.Fail(ServerProbeStatus.Failed, "адрес не найден")
                : ServerProbeResult.Success(
                    ServerProbeStatus.EndpointResolved,
                    ClampElapsed(stopwatch.ElapsedMilliseconds),
                    port > 0 ? "адрес проверен" : "адрес найден");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Failed, "таймаут");
        }
        catch
        {
            return ServerProbeResult.Fail(ServerProbeStatus.Failed, "адрес не найден");
        }
    }

    private static bool TryGetEndpoint(
        VpnProfile profile,
        string tunnelConfig,
        out string host,
        out int port)
    {
        host = profile.ServerAddress.Trim();
        port = profile.ServerPort;

        if (string.IsNullOrWhiteSpace(host)
            && profile.Protocol is VpnProtocolType.WireGuard or VpnProtocolType.AmneziaWireGuard
            && TryParseEndpointFromConfig(tunnelConfig, out var configHost, out var configPort))
        {
            host = configHost;
            port = configPort;
        }

        return !string.IsNullOrWhiteSpace(host) && port is > 0 and <= 65535;
    }

    private static bool TryParseEndpointFromConfig(string config, out string host, out int port)
    {
        host = string.Empty;
        port = 0;

        if (string.IsNullOrWhiteSpace(config))
        {
            return false;
        }

        var endpointLine = config
            .Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(line => line.StartsWith("Endpoint", StringComparison.OrdinalIgnoreCase));

        if (string.IsNullOrWhiteSpace(endpointLine))
        {
            return false;
        }

        var value = endpointLine.Split('=', 2, StringSplitOptions.TrimEntries).LastOrDefault();
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var separatorIndex = value.LastIndexOf(':');
        if (separatorIndex <= 0 || separatorIndex >= value.Length - 1)
        {
            return false;
        }

        host = value[..separatorIndex].Trim('[', ']', ' ');
        return int.TryParse(value[(separatorIndex + 1)..], out port)
            && !string.IsNullOrWhiteSpace(host)
            && port is > 0 and <= 65535;
    }

    private static int ClampElapsed(long elapsedMs)
    {
        return (int)Math.Clamp(elapsedMs, 0, int.MaxValue);
    }
}

public static class ServerProbeStatus
{
    public const string Connected = "connected";
    public const string TcpOk = "tcp_ok";
    public const string EndpointResolved = "endpoint_resolved";
    public const string Failed = "failed";
    public const string Skipped = "skipped";
}

public sealed record ServerProbeResult(
    bool IsSuccess,
    int? LatencyMs,
    string Status,
    string Message)
{
    public static ServerProbeResult Success(string status, int latencyMs, string message)
    {
        return new ServerProbeResult(true, latencyMs, status, message);
    }

    public static ServerProbeResult Fail(string status, string message)
    {
        return new ServerProbeResult(false, null, status, message);
    }
}
