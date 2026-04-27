using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

public sealed class ProtectionPolicyService
{
    private const string RuleGroupName = "Samhain Security Protection";

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

    public async Task<PipeResponse> PreviewAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var buildResult = await BuildPolicyStateAsync(request, cancellationToken);
        if (!buildResult.IsSuccess || buildResult.State is null)
        {
            return PipeResponse.Fail(buildResult.Error);
        }

        return PipeResponse.Success(
            "Protection preview." + Environment.NewLine
            + await BuildStatusOutputAsync(buildResult.State, includeSystemStatus: false, cancellationToken));
    }

    public async Task<PipeResponse> ApplyAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var buildResult = await BuildPolicyStateAsync(request, cancellationToken);
        if (!buildResult.IsSuccess || buildResult.State is null)
        {
            return PipeResponse.Fail(buildResult.Error);
        }

        var state = buildResult.State;
        state.FirewallProfiles = await GetFirewallProfileSnapshotsAsync(cancellationToken);
        if (state.FirewallProfiles.Length == 0)
        {
            return PipeResponse.Fail("Cannot read Windows Firewall profile defaults.");
        }

        await SaveStateAsync(state, cancellationToken);

        if (state.KillSwitchEnabled)
        {
            var applyResult = await ApplyFirewallPolicyAsync(state, cancellationToken);
            if (!applyResult.IsSuccess)
            {
                return applyResult;
            }

            state.EnforcementMode = "firewall";
            state.EnforcementActive = true;
            state.AppliedAtUtc = DateTimeOffset.UtcNow;
        }
        else
        {
            state.EnforcementMode = "audit-only";
            state.EnforcementActive = false;
        }

        await SaveStateAsync(state, cancellationToken);

        var headline = state.EnforcementActive
            ? "Protection policy enforced."
            : "Protection policy staged.";

        return PipeResponse.Success(
            headline + Environment.NewLine
            + await BuildStatusOutputAsync(state, includeSystemStatus: true, cancellationToken));
    }

    public async Task<PipeResponse> RemoveAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        var removeResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: false, cancellationToken);

        if (File.Exists(_statePath))
        {
            File.Delete(_statePath);
        }

        return removeResult.IsSuccess
            ? PipeResponse.Success("Protection policy removed." + Environment.NewLine + removeResult.Output.Trim())
            : removeResult;
    }

    public async Task<PipeResponse> ResetAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        var removeResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: state is null, cancellationToken);

        if (File.Exists(_statePath))
        {
            File.Delete(_statePath);
        }

        return removeResult.IsSuccess
            ? PipeResponse.Success("Protection emergency reset completed." + Environment.NewLine + removeResult.Output.Trim())
            : removeResult;
    }

    public async Task<PipeResponse> StatusAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        if (state is null)
        {
            return PipeResponse.Success(
                "Protection policy: not staged." + Environment.NewLine
                + await QueryFirewallPolicyStatusAsync(cancellationToken));
        }

        return PipeResponse.Success(await BuildStatusOutputAsync(state, includeSystemStatus: true, cancellationToken));
    }

    private async Task<BuildPolicyStateResult> BuildPolicyStateAsync(
        PipeRequest request,
        CancellationToken cancellationToken)
    {
        if (!request.KillSwitchEnabled && !request.DnsLeakProtectionEnabled)
        {
            return BuildPolicyStateResult.Fail("Protection is disabled for this profile.");
        }

        if (string.IsNullOrWhiteSpace(request.ProfileName))
        {
            return BuildPolicyStateResult.Fail("ProfileName is required.");
        }

        if (request.DnsLeakProtectionEnabled && !request.KillSwitchEnabled)
        {
            return BuildPolicyStateResult.Fail("DNS leak protection requires Kill switch enforcement in this build.");
        }

        var dnsServers = Array.Empty<string>();
        if (request.DnsLeakProtectionEnabled && !TryParseDnsServers(request.DnsServers, out dnsServers, out var dnsError))
        {
            return BuildPolicyStateResult.Fail(dnsError);
        }

        var endpointAddresses = await ResolveEndpointAddressesAsync(request.ServerAddress, cancellationToken);
        var endpointRequired = request.KillSwitchEnabled
            && endpointAddresses.Length == 0
            && string.IsNullOrWhiteSpace(request.EnginePath)
            && string.IsNullOrWhiteSpace(request.TunnelInterfaceAlias);

        if (endpointRequired)
        {
            return BuildPolicyStateResult.Fail("Kill switch needs a server address, engine path, or tunnel interface alias.");
        }

        return BuildPolicyStateResult.Success(new ProtectionPolicyState
        {
            ProfileName = request.ProfileName,
            ProtocolName = request.ProtocolName,
            ServerAddress = request.ServerAddress,
            ServerPort = request.ServerPort,
            EnginePath = request.EnginePath,
            TunnelInterfaceAlias = string.IsNullOrWhiteSpace(request.TunnelInterfaceAlias)
                ? request.ProfileName
                : request.TunnelInterfaceAlias,
            KillSwitchEnabled = request.KillSwitchEnabled,
            DnsLeakProtectionEnabled = request.DnsLeakProtectionEnabled,
            AllowLanTraffic = request.AllowLanTraffic,
            DnsServers = dnsServers,
            EndpointAddresses = endpointAddresses,
            FirewallRuleGroup = RuleGroupName,
            EnforcementMode = request.KillSwitchEnabled ? "firewall" : "audit-only",
            EnforcementActive = false,
            UpdatedAtUtc = DateTimeOffset.UtcNow
        });
    }

    private async Task<string> BuildStatusOutputAsync(
        ProtectionPolicyState state,
        bool includeSystemStatus,
        CancellationToken cancellationToken)
    {
        var lines = new List<string>
        {
            state.EnforcementActive ? "Protection policy: enforced" : "Protection policy: staged",
            $"Profile: {state.ProfileName}",
            $"Protocol: {state.ProtocolName}",
            $"Server: {FormatEndpoint(state)}",
            $"Endpoint addresses: {FormatCollection(state.EndpointAddresses)}",
            $"Tunnel interface: {FormatValue(state.TunnelInterfaceAlias)}",
            $"Engine path: {FormatValue(state.EnginePath)}",
            $"Kill switch: {FormatSwitch(state.KillSwitchEnabled)}",
            $"DNS leak protection: {FormatSwitch(state.DnsLeakProtectionEnabled)}",
            $"Allowed local network: {FormatSwitch(state.AllowLanTraffic)}",
            $"DNS servers: {FormatCollection(state.DnsServers)}",
            $"Enforcement mode: {state.EnforcementMode}",
            $"Rule group: {state.FirewallRuleGroup}",
            $"State file: {_statePath}"
        };

        lines.AddRange(BuildFirewallRulePlan(state));

        if (includeSystemStatus)
        {
            lines.Add(await QueryFirewallPolicyStatusAsync(cancellationToken));
            lines.Add(await QueryDnsSnapshotAsync(cancellationToken));
        }

        return string.Join(Environment.NewLine, lines);
    }

    private static IEnumerable<string> BuildFirewallRulePlan(ProtectionPolicyState state)
    {
        yield return "Firewall plan:";

        if (!state.KillSwitchEnabled)
        {
            yield return "- firewall default outbound policy is unchanged";
            yield break;
        }

        yield return "- remove old Samhain Security protection rules";
        yield return "- add allow rules for tunnel interface, endpoint, engine, DHCP, and loopback-safe local paths";
        yield return "- set Domain/Private/Public DefaultOutboundAction to Block";

        if (state.EndpointAddresses.Length > 0)
        {
            yield return $"- allow endpoint addresses: {string.Join(", ", state.EndpointAddresses)}";
        }

        if (state.DnsLeakProtectionEnabled)
        {
            yield return $"- allow DNS only to approved resolvers: {string.Join(", ", state.DnsServers)}";
        }

        if (state.FirewallProfiles.Length > 0)
        {
            yield return "- restore snapshot is available for: "
                + string.Join(", ", state.FirewallProfiles.Select(profile => $"{profile.Name}={profile.DefaultOutboundAction}"));
        }
    }

    private async Task SaveStateAsync(ProtectionPolicyState state, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_statePath)!);
        await using var stream = File.Create(_statePath);
        await JsonSerializer.SerializeAsync(stream, state, JsonOptions, cancellationToken);
    }

    private async Task<ProtectionPolicyState?> TryLoadStateAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_statePath))
        {
            return null;
        }

        await using var stream = File.OpenRead(_statePath);
        return await JsonSerializer.DeserializeAsync<ProtectionPolicyState>(stream, JsonOptions, cancellationToken);
    }

    private static async Task<PipeResponse> ApplyFirewallPolicyAsync(
        ProtectionPolicyState state,
        CancellationToken cancellationToken)
    {
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions));
        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{payload}}'))
        $policy = $payloadJson | ConvertFrom-Json

        function To-Array($value) {
            if ($null -eq $value) { return @() }
            if ($value -is [array]) { return $value }
            return @($value)
        }

        function Remove-SamhainRules {
            Get-NetFirewallRule -Group $policy.FirewallRuleGroup -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue
        }

        function Restore-ProfileDefaults {
            foreach ($profile in (To-Array $policy.FirewallProfiles)) {
                if ($profile.Name -and $profile.DefaultOutboundAction) {
                    Set-NetFirewallProfile -Profile $profile.Name -DefaultOutboundAction $profile.DefaultOutboundAction
                }
            }
        }

        try {
            Remove-SamhainRules

            if ($policy.AllowLanTraffic) {
                New-NetFirewallRule -DisplayName 'Samhain Security Allow Local Network' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -RemoteAddress LocalSubnet | Out-Null
            }

            New-NetFirewallRule -DisplayName 'Samhain Security Allow DHCP' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Protocol UDP -RemotePort 67,68 | Out-Null

            $endpointAddresses = To-Array $policy.EndpointAddresses
            if ($endpointAddresses.Count -gt 0 -and $policy.ServerPort -gt 0) {
                New-NetFirewallRule -DisplayName 'Samhain Security Allow Endpoint TCP' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Protocol TCP -RemotePort $policy.ServerPort -RemoteAddress $endpointAddresses | Out-Null
                New-NetFirewallRule -DisplayName 'Samhain Security Allow Endpoint UDP' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Protocol UDP -RemotePort $policy.ServerPort -RemoteAddress $endpointAddresses | Out-Null
            }

            $dnsServers = To-Array $policy.DnsServers
            if ($policy.DnsLeakProtectionEnabled -and $dnsServers.Count -gt 0) {
                New-NetFirewallRule -DisplayName 'Samhain Security Allow DNS UDP' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Protocol UDP -RemotePort 53 -RemoteAddress $dnsServers | Out-Null
                New-NetFirewallRule -DisplayName 'Samhain Security Allow DNS TCP' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Protocol TCP -RemotePort 53 -RemoteAddress $dnsServers | Out-Null
            }

            if ($policy.EnginePath -and (Test-Path -LiteralPath $policy.EnginePath)) {
                New-NetFirewallRule -DisplayName 'Samhain Security Allow Engine' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -Program $policy.EnginePath | Out-Null
            }

            if ($policy.TunnelInterfaceAlias -and (Get-NetAdapter -Name $policy.TunnelInterfaceAlias -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'Samhain Security Allow Tunnel Interface' -Group $policy.FirewallRuleGroup -Direction Outbound -Action Allow -InterfaceAlias $policy.TunnelInterfaceAlias | Out-Null
            }

            Set-NetFirewallProfile -Profile Domain,Private,Public -DefaultOutboundAction Block
            'Firewall enforcement applied. Rule group: ' + $policy.FirewallRuleGroup
        } catch {
            try {
                Remove-SamhainRules
                Restore-ProfileDefaults
            } catch {
            }

            throw
        }
        """;

        return await RunPowerShellAsync(script, cancellationToken);
    }

    private static async Task<PipeResponse> RemoveFirewallPolicyAsync(
        ProtectionPolicyState? state,
        bool forceDefaultAllow,
        CancellationToken cancellationToken)
    {
        var resetState = state ?? new ProtectionPolicyState
        {
            FirewallRuleGroup = RuleGroupName,
            FirewallProfiles = forceDefaultAllow
                ? [new FirewallProfileSnapshot("Domain", "Allow"), new FirewallProfileSnapshot("Private", "Allow"), new FirewallProfileSnapshot("Public", "Allow")]
                : []
        };

        if (string.IsNullOrWhiteSpace(resetState.FirewallRuleGroup))
        {
            resetState.FirewallRuleGroup = RuleGroupName;
        }

        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(resetState, JsonOptions));
        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{payload}}'))
        $policy = $payloadJson | ConvertFrom-Json

        function To-Array($value) {
            if ($null -eq $value) { return @() }
            if ($value -is [array]) { return $value }
            return @($value)
        }

        Get-NetFirewallRule -Group $policy.FirewallRuleGroup -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue

        foreach ($profile in (To-Array $policy.FirewallProfiles)) {
            if ($profile.Name -and $profile.DefaultOutboundAction) {
                Set-NetFirewallProfile -Profile $profile.Name -DefaultOutboundAction $profile.DefaultOutboundAction
            }
        }

        'Firewall protection removed. Rule group: ' + $policy.FirewallRuleGroup
        """;

        return await RunPowerShellAsync(script, cancellationToken);
    }

    private static async Task<FirewallProfileSnapshot[]> GetFirewallProfileSnapshotsAsync(CancellationToken cancellationToken)
    {
        const string script = """
        Get-NetFirewallProfile |
          Select-Object Name,@{Name='DefaultOutboundAction';Expression={$_.DefaultOutboundAction.ToString()}} |
          ConvertTo-Json -Compress
        """;

        var result = await RunPowerShellAsync(script, cancellationToken);
        if (!result.IsSuccess || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var snapshots = JsonSerializer.Deserialize<FirewallProfileSnapshot[]>(result.Output.Trim(), JsonOptions);
            if (snapshots is not null)
            {
                return snapshots;
            }

            var snapshot = JsonSerializer.Deserialize<FirewallProfileSnapshot>(result.Output.Trim(), JsonOptions);
            return snapshot is null ? [] : [snapshot];
        }
        catch
        {
            return [];
        }
    }

    private static async Task<string> QueryFirewallPolicyStatusAsync(CancellationToken cancellationToken)
    {
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(RuleGroupName));
        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $group = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{payload}}'))
        $rules = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue)
        $profiles = Get-NetFirewallProfile | Select-Object Name,DefaultOutboundAction | ConvertTo-Json -Compress
        'Firewall rules: ' + $rules.Count + '; profiles: ' + $profiles
        """;

        var result = await RunPowerShellAsync(script, cancellationToken);
        return result.IsSuccess
            ? result.Output.Trim()
            : "Firewall rules: unavailable";
    }

    private static async Task<string> QueryDnsSnapshotAsync(CancellationToken cancellationToken)
    {
        const string script = """
        Get-DnsClientServerAddress |
          Where-Object { $_.ServerAddresses.Count -gt 0 } |
          Select-Object -First 8 InterfaceAlias,AddressFamily,ServerAddresses |
          ConvertTo-Json -Compress
        """;

        var result = await RunPowerShellAsync(script, cancellationToken);
        if (!result.IsSuccess || string.IsNullOrWhiteSpace(result.Output))
        {
            return "DNS snapshot: unavailable";
        }

        return "DNS snapshot: " + result.Output.Trim();
    }

    private static async Task<string[]> ResolveEndpointAddressesAsync(
        string serverAddress,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(serverAddress))
        {
            return [];
        }

        if (IPAddress.TryParse(serverAddress, out var parsedAddress))
        {
            return [parsedAddress.ToString()];
        }

        try
        {
            var addresses = await Dns.GetHostAddressesAsync(serverAddress, cancellationToken);
            return addresses
                .Where(address => address.AddressFamily is AddressFamily.InterNetwork or AddressFamily.InterNetworkV6)
                .Select(address => address.ToString())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch
        {
            return [];
        }
    }

    private static async Task<PipeResponse> RunPowerShellAsync(string script, CancellationToken cancellationToken)
    {
        var encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        return await RunProcessAsync(
            "powershell.exe",
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodedCommand],
            cancellationToken);
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

    private static string FormatCollection(IReadOnlyCollection<string> values)
    {
        return values.Count == 0 ? "not set" : string.Join(", ", values);
    }

    private static string FormatEndpoint(ProtectionPolicyState state)
    {
        return string.IsNullOrWhiteSpace(state.ServerAddress)
            ? "not set"
            : $"{state.ServerAddress}:{state.ServerPort}";
    }

    private static string FormatValue(string value)
    {
        return string.IsNullOrWhiteSpace(value) ? "not set" : value;
    }

    private sealed record BuildPolicyStateResult(bool IsSuccess, ProtectionPolicyState? State, string Error)
    {
        public static BuildPolicyStateResult Success(ProtectionPolicyState state)
        {
            return new BuildPolicyStateResult(true, state, string.Empty);
        }

        public static BuildPolicyStateResult Fail(string error)
        {
            return new BuildPolicyStateResult(false, null, error);
        }
    }
}

public sealed class ProtectionPolicyState
{
    public string ProfileName { get; set; } = string.Empty;

    public string ProtocolName { get; set; } = string.Empty;

    public string ServerAddress { get; set; } = string.Empty;

    public int ServerPort { get; set; }

    public string EnginePath { get; set; } = string.Empty;

    public string TunnelInterfaceAlias { get; set; } = string.Empty;

    public bool KillSwitchEnabled { get; set; }

    public bool DnsLeakProtectionEnabled { get; set; }

    public bool AllowLanTraffic { get; set; }

    public string[] DnsServers { get; set; } = [];

    public string[] EndpointAddresses { get; set; } = [];

    public string FirewallRuleGroup { get; set; } = string.Empty;

    public FirewallProfileSnapshot[] FirewallProfiles { get; set; } = [];

    public string EnforcementMode { get; set; } = "audit-only";

    public bool EnforcementActive { get; set; }

    public DateTimeOffset UpdatedAtUtc { get; set; }

    public DateTimeOffset? AppliedAtUtc { get; set; }
}

public sealed record FirewallProfileSnapshot(string Name, string DefaultOutboundAction);
