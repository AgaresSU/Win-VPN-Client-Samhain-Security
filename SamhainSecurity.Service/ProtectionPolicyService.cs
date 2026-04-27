using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

public sealed class ProtectionPolicyService
{
    private const string RuleGroupName = "Samhain Security Protection";
    private const int MaxAuditFieldLength = 4000;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _stateDirectory;
    private readonly string _statePath;
    private readonly string _auditPath;

    public ProtectionPolicyService()
    {
        _stateDirectory = Environment.GetEnvironmentVariable("SAMHAIN_SERVICE_STATE_DIR") ?? string.Empty;
        if (string.IsNullOrWhiteSpace(_stateDirectory))
        {
            _stateDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "SamhainSecurity",
                "Service");
        }

        _statePath = Path.Combine(_stateDirectory, "protection-state.json");
        _auditPath = Path.Combine(_stateDirectory, "protection-audit.jsonl");
    }

    public async Task<PipeResponse> PreviewAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var buildResult = await BuildPolicyStateAsync(request, cancellationToken);
        if (!buildResult.IsSuccess || buildResult.State is null)
        {
            await WriteAuditAsync("preview.failed", null, PipeResponse.Fail(buildResult.Error), cancellationToken);
            return PipeResponse.Fail(buildResult.Error);
        }

        var response = PipeResponse.Success(
            "Protection preview." + Environment.NewLine
            + await BuildStatusOutputAsync(buildResult.State, includeSystemStatus: false, cancellationToken));
        await WriteAuditAsync("preview.succeeded", buildResult.State, response, cancellationToken);
        return response;
    }

    public async Task<PipeResponse> ApplyAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var buildResult = await BuildPolicyStateAsync(request, cancellationToken);
        if (!buildResult.IsSuccess || buildResult.State is null)
        {
            await WriteAuditAsync("apply.failed", null, PipeResponse.Fail(buildResult.Error), cancellationToken);
            return PipeResponse.Fail(buildResult.Error);
        }

        var state = buildResult.State;
        state.FirewallProfiles = await GetFirewallProfileSnapshotsAsync(cancellationToken);
        if (state.FirewallProfiles.Length == 0)
        {
            var failure = PipeResponse.Fail("Cannot read Windows Firewall profile defaults.");
            await WriteAuditAsync("apply.failed", state, failure, cancellationToken);
            return failure;
        }

        await SaveStateAsync(state, cancellationToken);
        await WriteAuditAsync("apply.started", state, PipeResponse.Success("Protection apply started."), cancellationToken);

        if (state.KillSwitchEnabled)
        {
            var applyResult = await ApplyFirewallPolicyAsync(state, cancellationToken);
            if (!applyResult.IsSuccess)
            {
                await WriteAuditAsync("apply.failed", state, applyResult, cancellationToken);
                return applyResult;
            }

            state.EnforcementMode = "firewall";
            state.EnforcementActive = true;
            state.AppliedAtUtc = DateTimeOffset.UtcNow;

            var healthResult = await ValidateEnforcementAsync(state, cancellationToken);
            state.LastHealthCheckUtc = DateTimeOffset.UtcNow;
            state.LastHealthCheckResult = healthResult.Output.Trim();
            if (!healthResult.IsSuccess)
            {
                var rollbackResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: false, cancellationToken);
                state.EnforcementMode = "rolled-back";
                state.EnforcementActive = false;
                state.LastRollbackAtUtc = DateTimeOffset.UtcNow;
                await SaveStateAsync(state, cancellationToken);
                await WriteAuditAsync("apply.rolled-back", state, rollbackResult, cancellationToken);

                return PipeResponse.Fail(
                    "Protection health check failed; firewall policy was rolled back."
                    + Environment.NewLine
                    + healthResult.CombinedOutput
                    + Environment.NewLine
                    + rollbackResult.CombinedOutput);
            }
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

        var response = PipeResponse.Success(
            headline + Environment.NewLine
            + await BuildStatusOutputAsync(state, includeSystemStatus: true, cancellationToken));
        await WriteAuditAsync("apply.succeeded", state, response, cancellationToken);
        return response;
    }

    public async Task<PipeResponse> RemoveAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        var removeResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: false, cancellationToken);

        if (File.Exists(_statePath))
        {
            File.Delete(_statePath);
        }

        var response = removeResult.IsSuccess
            ? PipeResponse.Success("Protection policy removed." + Environment.NewLine + removeResult.Output.Trim())
            : removeResult;
        await WriteAuditAsync("remove.completed", state, response, cancellationToken);
        return response;
    }

    public async Task<PipeResponse> ResetAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        var removeResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: state is null, cancellationToken);

        if (File.Exists(_statePath))
        {
            File.Delete(_statePath);
        }

        var response = removeResult.IsSuccess
            ? PipeResponse.Success("Protection emergency reset completed." + Environment.NewLine + removeResult.Output.Trim())
            : removeResult;
        await WriteAuditAsync("reset.completed", state, response, cancellationToken);
        return response;
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

    public async Task<PipeResponse> WatchdogCheckAsync(CancellationToken cancellationToken)
    {
        var state = await TryLoadStateAsync(cancellationToken);
        if (state is null || !state.EnforcementActive)
        {
            return PipeResponse.Success("Protection watchdog: idle.");
        }

        var healthResult = await ValidateEnforcementAsync(state, cancellationToken);
        state.LastHealthCheckUtc = DateTimeOffset.UtcNow;
        state.LastHealthCheckResult = healthResult.Output.Trim();

        if (healthResult.IsSuccess)
        {
            await SaveStateAsync(state, cancellationToken);
            await WriteAuditAsync("watchdog.healthy", state, healthResult, cancellationToken);
            return PipeResponse.Success("Protection watchdog: healthy." + Environment.NewLine + healthResult.Output.Trim());
        }

        var rollbackResult = await RemoveFirewallPolicyAsync(state, forceDefaultAllow: false, cancellationToken);
        state.EnforcementMode = "rolled-back";
        state.EnforcementActive = false;
        state.LastRollbackAtUtc = DateTimeOffset.UtcNow;
        await SaveStateAsync(state, cancellationToken);
        await WriteAuditAsync("watchdog.rolled-back", state, rollbackResult, cancellationToken);

        return PipeResponse.Fail(
            "Protection watchdog rolled back enforcement."
            + Environment.NewLine
            + healthResult.CombinedOutput
            + Environment.NewLine
            + rollbackResult.CombinedOutput);
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
            $"Last health check: {FormatTimestamp(state.LastHealthCheckUtc)}",
            $"Last health result: {FormatValue(state.LastHealthCheckResult)}",
            $"Last rollback: {FormatTimestamp(state.LastRollbackAtUtc)}",
            $"State file: {_statePath}",
            $"Audit log: {_auditPath}"
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
        Directory.CreateDirectory(_stateDirectory);
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

    private static async Task<PipeResponse> ValidateEnforcementAsync(
        ProtectionPolicyState state,
        CancellationToken cancellationToken)
    {
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(state, JsonOptions));
        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $payloadJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{{payload}}'))
        $policy = $payloadJson | ConvertFrom-Json

        $rules = @(Get-NetFirewallRule -Group $policy.FirewallRuleGroup -ErrorAction SilentlyContinue)
        $profiles = @(Get-NetFirewallProfile)
        $notBlocked = @($profiles | Where-Object { $_.DefaultOutboundAction.ToString() -ne 'Block' })

        $messages = New-Object System.Collections.Generic.List[string]
        $messages.Add('Rules: ' + $rules.Count)
        $messages.Add('Profiles: ' + (($profiles | ForEach-Object { $_.Name + '=' + $_.DefaultOutboundAction.ToString() }) -join ', '))

        if ($rules.Count -lt 2) {
            throw 'Protection rule group is missing or incomplete. ' + ($messages -join '; ')
        }

        if ($notBlocked.Count -gt 0) {
            throw 'Firewall outbound defaults are not blocked. ' + ($messages -join '; ')
        }

        if ($policy.DnsLeakProtectionEnabled) {
            $dnsRules = @($rules | Where-Object { $_.DisplayName -like '*DNS*' })
            if ($dnsRules.Count -lt 2) {
                throw 'DNS allow rules are missing. ' + ($messages -join '; ')
            }
        }

        'Protection health check passed. ' + ($messages -join '; ')
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

    private static string FormatTimestamp(DateTimeOffset? value)
    {
        return value.HasValue ? value.Value.ToString("O") : "never";
    }

    private async Task WriteAuditAsync(
        string eventName,
        ProtectionPolicyState? state,
        PipeResponse response,
        CancellationToken cancellationToken)
    {
        try
        {
            Directory.CreateDirectory(_stateDirectory);
            var entry = new ProtectionAuditEntry
            {
                TimestampUtc = DateTimeOffset.UtcNow,
                EventName = eventName,
                ProfileName = state?.ProfileName ?? string.Empty,
                EnforcementMode = state?.EnforcementMode ?? string.Empty,
                EnforcementActive = state?.EnforcementActive ?? false,
                ExitCode = response.ExitCode,
                Output = Truncate(response.Output),
                Error = Truncate(response.Error)
            };

            await File.AppendAllTextAsync(
                _auditPath,
                JsonSerializer.Serialize(entry, JsonOptions) + Environment.NewLine,
                cancellationToken);
        }
        catch
        {
            // Protection actions should not fail because audit logging is unavailable.
        }
    }

    private static string Truncate(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length <= MaxAuditFieldLength)
        {
            return value;
        }

        return value[..MaxAuditFieldLength] + "...";
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

    public DateTimeOffset? LastHealthCheckUtc { get; set; }

    public string LastHealthCheckResult { get; set; } = string.Empty;

    public DateTimeOffset? LastRollbackAtUtc { get; set; }
}

public sealed record FirewallProfileSnapshot(string Name, string DefaultOutboundAction);

public sealed class ProtectionAuditEntry
{
    public DateTimeOffset TimestampUtc { get; set; }

    public string EventName { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public string EnforcementMode { get; set; } = string.Empty;

    public bool EnforcementActive { get; set; }

    public int ExitCode { get; set; }

    public string Output { get; set; } = string.Empty;

    public string Error { get; set; } = string.Empty;
}
