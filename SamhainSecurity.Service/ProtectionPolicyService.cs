using System.Diagnostics;
using System.Net;
using System.Text.Json;

public sealed class ProtectionPolicyService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _statePath;

    public ProtectionPolicyService()
    {
        var stateDirectory = Environment.GetEnvironmentVariable("SAMHAIN_SERVICE_STATE_DIR");
        if (string.IsNullOrWhiteSpace(stateDirectory))
        {
            stateDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "SamhainSecurity",
                "Service");
        }

        _statePath = Path.Combine(stateDirectory, "protection-state.json");
    }

    public async Task<PipeResponse> ApplyAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (!request.KillSwitchEnabled && !request.DnsLeakProtectionEnabled)
        {
            return PipeResponse.Fail("Protection is disabled for this profile.");
        }

        if (string.IsNullOrWhiteSpace(request.ProfileName))
        {
            return PipeResponse.Fail("ProfileName is required.");
        }

        var dnsServers = Array.Empty<string>();
        if (request.DnsLeakProtectionEnabled && !TryParseDnsServers(request.DnsServers, out dnsServers, out var dnsError))
        {
            return PipeResponse.Fail(dnsError);
        }

        var state = new ProtectionPolicyState
        {
            ProfileName = request.ProfileName,
            ProtocolName = request.ProtocolName,
            ServerAddress = request.ServerAddress,
            ServerPort = request.ServerPort,
            EnginePath = request.EnginePath,
            KillSwitchEnabled = request.KillSwitchEnabled,
            DnsLeakProtectionEnabled = request.DnsLeakProtectionEnabled,
            AllowLanTraffic = request.AllowLanTraffic,
            DnsServers = dnsServers,
            UpdatedAtUtc = DateTimeOffset.UtcNow
        };

        Directory.CreateDirectory(Path.GetDirectoryName(_statePath)!);
        await using (var stream = File.Create(_statePath))
        {
            await JsonSerializer.SerializeAsync(stream, state, JsonOptions, cancellationToken);
        }

        var output = await BuildStatusOutputAsync(state, cancellationToken);
        return PipeResponse.Success("Protection policy staged." + Environment.NewLine + output);
    }

    public Task<PipeResponse> RemoveAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        if (File.Exists(_statePath))
        {
            File.Delete(_statePath);
        }

        return Task.FromResult(PipeResponse.Success("Protection policy removed."));
    }

    public async Task<PipeResponse> StatusAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_statePath))
        {
            return PipeResponse.Success("Protection policy: not staged.");
        }

        await using var stream = File.OpenRead(_statePath);
        var state = await JsonSerializer.DeserializeAsync<ProtectionPolicyState>(stream, JsonOptions, cancellationToken);
        if (state is null)
        {
            return PipeResponse.Fail("Protection policy state is unreadable.");
        }

        return PipeResponse.Success(await BuildStatusOutputAsync(state, cancellationToken));
    }

    private async Task<string> BuildStatusOutputAsync(ProtectionPolicyState state, CancellationToken cancellationToken)
    {
        var lines = new List<string>
        {
            $"Protection policy: staged",
            $"Profile: {state.ProfileName}",
            $"Protocol: {state.ProtocolName}",
            $"Server: {state.ServerAddress}:{state.ServerPort}",
            $"Kill switch: {FormatSwitch(state.KillSwitchEnabled)}",
            $"DNS leak protection: {FormatSwitch(state.DnsLeakProtectionEnabled)}",
            $"Allowed local network: {FormatSwitch(state.AllowLanTraffic)}",
            $"DNS servers: {FormatDnsServers(state.DnsServers)}",
            $"State file: {_statePath}",
            "Enforcement: audit-only in this build; WFP filters are not installed yet."
        };

        lines.Add(await QueryFirewallServiceAsync(cancellationToken));
        lines.Add(await QueryDnsSnapshotAsync(cancellationToken));
        lines.AddRange(BuildWfpPlan(state));

        return string.Join(Environment.NewLine, lines);
    }

    private static IEnumerable<string> BuildWfpPlan(ProtectionPolicyState state)
    {
        yield return "WFP plan:";

        if (state.KillSwitchEnabled)
        {
            yield return "- block outbound flows that are not bound to the protected tunnel interface";
            yield return "- allow control traffic to the selected endpoint before tunnel establishment";
            yield return "- allow loopback and service pipe traffic";
        }

        if (state.DnsLeakProtectionEnabled)
        {
            yield return "- restrict UDP/TCP 53 and encrypted DNS endpoints to approved resolvers";
        }

        if (state.AllowLanTraffic)
        {
            yield return "- allow RFC1918/link-local local network ranges";
        }
    }

    private static async Task<string> QueryFirewallServiceAsync(CancellationToken cancellationToken)
    {
        var result = await RunProcessAsync("sc.exe", ["query", "mpssvc"], cancellationToken);
        var stateLine = result.Output
            .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(line => line.Contains("STATE", StringComparison.OrdinalIgnoreCase));

        return result.ExitCode == 0
            ? $"Firewall service: {stateLine ?? "available"}"
            : "Firewall service: unavailable";
    }

    private static async Task<string> QueryDnsSnapshotAsync(CancellationToken cancellationToken)
    {
        const string script = """
        Get-DnsClientServerAddress |
          Where-Object { $_.ServerAddresses.Count -gt 0 } |
          Select-Object -First 8 InterfaceAlias,AddressFamily,ServerAddresses |
          ConvertTo-Json -Compress
        """;

        var result = await RunProcessAsync(
            "powershell.exe",
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
            cancellationToken);

        if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.Output))
        {
            return "DNS snapshot: unavailable";
        }

        return "DNS snapshot: " + result.Output.Trim();
    }

    private static async Task<PipeResponse> RunProcessAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken)
    {
        using var process = new Process();
        process.StartInfo.FileName = fileName;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.CreateNoWindow = true;

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        process.Start();
        var output = await process.StandardOutput.ReadToEndAsync(cancellationToken);
        var error = await process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);

        return new PipeResponse(process.ExitCode, output, error);
    }

    private static bool TryParseDnsServers(string value, out string[] dnsServers, out string error)
    {
        dnsServers = value
            .Split([',', ';', ' ', '\r', '\n', '\t'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

        if (dnsServers.Length == 0)
        {
            error = "DNS servers are required when DNS leak protection is enabled.";
            return false;
        }

        foreach (var server in dnsServers)
        {
            if (!IPAddress.TryParse(server, out _))
            {
                error = $"Invalid DNS server address: {server}";
                return false;
            }
        }

        error = string.Empty;
        return true;
    }

    private static string FormatSwitch(bool value)
    {
        return value ? "on" : "off";
    }

    private static string FormatDnsServers(IReadOnlyCollection<string> dnsServers)
    {
        return dnsServers.Count == 0
            ? "not set"
            : string.Join(", ", dnsServers);
    }
}

public sealed class ProtectionPolicyState
{
    public string ProfileName { get; set; } = string.Empty;

    public string ProtocolName { get; set; } = string.Empty;

    public string ServerAddress { get; set; } = string.Empty;

    public int ServerPort { get; set; }

    public string EnginePath { get; set; } = string.Empty;

    public bool KillSwitchEnabled { get; set; }

    public bool DnsLeakProtectionEnabled { get; set; }

    public bool AllowLanTraffic { get; set; }

    public string[] DnsServers { get; set; } = [];

    public DateTimeOffset UpdatedAtUtc { get; set; }
}
