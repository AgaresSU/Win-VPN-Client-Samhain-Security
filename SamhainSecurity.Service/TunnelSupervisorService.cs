using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;

public sealed class TunnelSupervisorService : IDisposable
{
    private static readonly TimeSpan RuntimeRetention = TimeSpan.FromHours(24);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly Dictionary<string, Process> _singBoxProcesses = [];

    public TunnelSupervisorService()
    {
        CleanupExpiredRuntime();
    }

    public Task<PipeResponse> ConnectAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        return NormalizeProtocol(request.ProtocolName) switch
        {
            "vlessreality" => ConnectVlessRealityAsync(request, cancellationToken),
            "wireguard" => ConnectWireGuardAsync(request, cancellationToken),
            "amneziawireguard" => ConnectAmneziaWireGuardAsync(request, cancellationToken),
            _ => Task.FromResult(PipeResponse.Fail("Unsupported protocol: " + request.ProtocolName))
        };
    }

    public Task<PipeResponse> DisconnectAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        return NormalizeProtocol(request.ProtocolName) switch
        {
            "vlessreality" => Task.FromResult(DisconnectVlessReality(request)),
            "wireguard" => DisconnectWireGuardAsync(request, cancellationToken),
            "amneziawireguard" => DisconnectAmneziaWireGuardAsync(request, cancellationToken),
            _ => Task.FromResult(PipeResponse.Fail("Unsupported protocol: " + request.ProtocolName))
        };
    }

    public Task<PipeResponse> StatusAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        return NormalizeProtocol(request.ProtocolName) switch
        {
            "vlessreality" => Task.FromResult(StatusVlessReality(request)),
            "wireguard" => StatusWireGuardAsync(request, cancellationToken),
            "amneziawireguard" => Task.FromResult(PipeResponse.Success("Status depends on external awg-quick backend")),
            _ => Task.FromResult(PipeResponse.Fail("Unsupported protocol: " + request.ProtocolName))
        };
    }

    public void Dispose()
    {
        foreach (var process in _singBoxProcesses.Values)
        {
            TryKill(process);
            process.Dispose();
        }

        _singBoxProcesses.Clear();
        CleanupExpiredRuntime(TimeSpan.Zero);
    }

    private async Task<PipeResponse> ConnectVlessRealityAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        DisconnectVlessReality(request);

        var validationError = ValidateVlessReality(request);
        if (!string.IsNullOrWhiteSpace(validationError))
        {
            return PipeResponse.Fail(validationError);
        }

        var enginePath = ResolveSingBox(request.EnginePath);
        var profileDirectory = GetProfileDirectory(GetProfileKey(request));
        var configPath = Path.Combine(profileDirectory, "sing-box-vless-reality.json");
        await File.WriteAllTextAsync(configPath, BuildSingBoxConfig(request), cancellationToken);

        try
        {
            var checkResult = await RunAsync(enginePath, ["check", "-c", configPath], cancellationToken);
            if (!checkResult.IsSuccess)
            {
                CleanupProfileRuntime(GetProfileKey(request));
                return checkResult;
            }

            var process = StartProcess(enginePath, ["run", "-c", configPath], profileDirectory);
            _singBoxProcesses[GetProfileKey(request)] = process;

            await Task.Delay(1200, cancellationToken);
            if (process.HasExited)
            {
                _singBoxProcesses.Remove(GetProfileKey(request));
                CleanupProfileRuntime(GetProfileKey(request));
                return new PipeResponse(process.ExitCode, string.Empty, "sing-box exited immediately after start");
            }

            return PipeResponse.Success("sing-box supervised by service. Runtime config will be removed on disconnect.");
        }
        catch (Exception ex)
        {
            CleanupProfileRuntime(GetProfileKey(request));
            return PipeResponse.Fail(ex.Message);
        }
    }

    private PipeResponse DisconnectVlessReality(PipeRequest request)
    {
        var key = GetProfileKey(request);
        if (!_singBoxProcesses.TryGetValue(key, out var process))
        {
            CleanupProfileRuntime(key);
            return PipeResponse.Success("sing-box is not running under the service");
        }

        TryKill(process);
        process.Dispose();
        _singBoxProcesses.Remove(key);
        CleanupProfileRuntime(key);

        return PipeResponse.Success("sing-box stopped by service");
    }

    private PipeResponse StatusVlessReality(PipeRequest request)
    {
        var key = GetProfileKey(request);
        return _singBoxProcesses.TryGetValue(key, out var process) && !process.HasExited
            ? PipeResponse.Success("Running")
            : PipeResponse.Success("Stopped");
    }

    private async Task<PipeResponse> ConnectWireGuardAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.TunnelConfig))
        {
            return PipeResponse.Fail("WireGuard .conf is required");
        }

        var tunnelName = GetTunnelName(request);
        var configPath = await WriteTunnelConfigAsync(request, tunnelName + ".conf", cancellationToken);
        var enginePath = ResolveWireGuard(request.EnginePath);

        try
        {
            await RunAsync(enginePath, ["/uninstalltunnelservice", tunnelName], cancellationToken);
            var installResult = await RunAsync(enginePath, ["/installtunnelservice", configPath], cancellationToken);
            CleanupProfileRuntime(GetProfileKey(request));

            return installResult.IsSuccess
                ? installResult with { Output = $"WireGuard service installed by Samhain Security Service: WireGuardTunnel${tunnelName}" }
                : installResult;
        }
        catch (Exception ex)
        {
            CleanupProfileRuntime(GetProfileKey(request));
            return PipeResponse.Fail(ex.Message);
        }
    }

    private async Task<PipeResponse> DisconnectWireGuardAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var tunnelName = GetTunnelName(request);
        var enginePath = ResolveWireGuard(request.EnginePath);

        try
        {
            var result = await RunAsync(enginePath, ["/uninstalltunnelservice", tunnelName], cancellationToken);
            CleanupProfileRuntime(GetProfileKey(request));
            return result;
        }
        catch (Exception ex)
        {
            CleanupProfileRuntime(GetProfileKey(request));
            return PipeResponse.Fail(ex.Message);
        }
    }

    private Task<PipeResponse> StatusWireGuardAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        return RunAsync("sc.exe", ["query", $"WireGuardTunnel${GetTunnelName(request)}"], cancellationToken);
    }

    private async Task<PipeResponse> ConnectAmneziaWireGuardAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.TunnelConfig))
        {
            return PipeResponse.Fail("AmneziaWG .conf is required");
        }

        var configPath = await WriteTunnelConfigAsync(request, GetTunnelName(request) + ".conf", cancellationToken);
        var enginePath = ResolveAmneziaWireGuard(request.EnginePath);

        try
        {
            await RunAsync(enginePath, ["down", configPath], cancellationToken);
            var result = await RunAsync(enginePath, ["up", configPath], cancellationToken);
            CleanupProfileRuntime(GetProfileKey(request));
            return result;
        }
        catch (Exception ex)
        {
            CleanupProfileRuntime(GetProfileKey(request));
            return PipeResponse.Fail(ex.Message);
        }
    }

    private async Task<PipeResponse> DisconnectAmneziaWireGuardAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        var configPath = await WriteTunnelConfigAsync(request, GetTunnelName(request) + ".conf", cancellationToken);
        var enginePath = ResolveAmneziaWireGuard(request.EnginePath);

        try
        {
            var result = await RunAsync(enginePath, ["down", configPath], cancellationToken);
            CleanupProfileRuntime(GetProfileKey(request));
            return result;
        }
        catch (Exception ex)
        {
            CleanupProfileRuntime(GetProfileKey(request));
            return PipeResponse.Fail(ex.Message);
        }
    }

    private static string BuildSingBoxConfig(PipeRequest request)
    {
        var flow = string.IsNullOrWhiteSpace(request.VlessFlow)
            ? null
            : request.VlessFlow.Trim();

        var config = new
        {
            log = new
            {
                level = "info",
                timestamp = true
            },
            inbounds = new object[]
            {
                new
                {
                    type = "tun",
                    tag = "tun-in",
                    interface_name = SanitizeName(request.ProfileName),
                    address = new[] { "172.19.0.1/30" },
                    mtu = 9000,
                    auto_route = true,
                    strict_route = true,
                    stack = "system"
                }
            },
            outbounds = new object[]
            {
                new
                {
                    type = "vless",
                    tag = "proxy",
                    server = request.ServerAddress,
                    server_port = request.ServerPort,
                    uuid = request.VlessUuid,
                    flow,
                    network = "tcp",
                    tls = new
                    {
                        enabled = true,
                        server_name = request.RealityServerName,
                        utls = new
                        {
                            enabled = true,
                            fingerprint = string.IsNullOrWhiteSpace(request.RealityFingerprint)
                                ? "chrome"
                                : request.RealityFingerprint
                        },
                        reality = new
                        {
                            enabled = true,
                            public_key = request.RealityPublicKey,
                            short_id = request.RealityShortId
                        }
                    }
                },
                new
                {
                    type = "direct",
                    tag = "direct"
                }
            },
            route = BuildRoute(request)
        };

        return JsonSerializer.Serialize(config, JsonOptions);
    }

    private static Dictionary<string, object> BuildRoute(PipeRequest request)
    {
        var mode = NormalizeAppRoutingMode(request.AppRoutingMode);
        var targets = ParseAppRoutingTargets(request.AppRoutingPaths);
        var route = new Dictionary<string, object>
        {
            ["auto_detect_interface"] = true,
            ["final"] = mode == "selectedappsonly" && targets.HasTargets
                ? "direct"
                : "proxy"
        };
        var rules = BuildAppRoutingRules(mode, targets);
        if (rules.Count > 0)
        {
            route["rules"] = rules;
        }

        return route;
    }

    private static List<object> BuildAppRoutingRules(string mode, AppRoutingTargets targets)
    {
        var outbound = mode switch
        {
            "selectedappsonly" => "proxy",
            "entirecomputerexceptselectedapps" => "direct",
            _ => string.Empty
        };

        if (string.IsNullOrWhiteSpace(outbound) || !targets.HasTargets)
        {
            return [];
        }

        var rules = new List<object>();
        if (targets.ProcessPaths.Length > 0)
        {
            rules.Add(new
            {
                process_path = targets.ProcessPaths,
                outbound
            });
        }

        if (targets.ProcessNames.Length > 0)
        {
            rules.Add(new
            {
                process_name = targets.ProcessNames,
                outbound
            });
        }

        return rules;
    }

    private static string ValidateVlessReality(PipeRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ServerAddress))
        {
            return "VLESS server is required";
        }

        if (request.ServerPort <= 0 || request.ServerPort > 65535)
        {
            return "VLESS port is invalid";
        }

        if (string.IsNullOrWhiteSpace(request.VlessUuid))
        {
            return "VLESS UUID is required";
        }

        if (string.IsNullOrWhiteSpace(request.RealityServerName))
        {
            return "Reality SNI is required";
        }

        if (string.IsNullOrWhiteSpace(request.RealityPublicKey))
        {
            return "Reality public key is required";
        }

        if (NormalizeAppRoutingMode(request.AppRoutingMode) != "entirecomputer"
            && !ParseAppRoutingTargets(request.AppRoutingPaths).HasTargets)
        {
            return "Application routing requires at least one application.";
        }

        return string.Empty;
    }

    private static AppRoutingTargets ParseAppRoutingTargets(string value)
    {
        var processPaths = new List<string>();
        var processNames = new List<string>();

        foreach (var item in value.Split(
            ['\r', '\n', ';'],
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var normalized = item.Trim().Trim('"', '\'');
            if (string.IsNullOrWhiteSpace(normalized))
            {
                continue;
            }

            if (Path.IsPathRooted(normalized)
                || normalized.Contains(Path.DirectorySeparatorChar, StringComparison.Ordinal)
                || normalized.Contains(Path.AltDirectorySeparatorChar, StringComparison.Ordinal))
            {
                processPaths.Add(Environment.ExpandEnvironmentVariables(normalized));
            }
            else
            {
                processNames.Add(Path.GetFileName(normalized));
            }
        }

        return new AppRoutingTargets(
            processPaths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(),
            processNames.Distinct(StringComparer.OrdinalIgnoreCase).ToArray());
    }

    private static string NormalizeAppRoutingMode(string mode)
    {
        var normalized = mode
            .Replace(" ", string.Empty, StringComparison.Ordinal)
            .Replace("-", string.Empty, StringComparison.Ordinal)
            .Replace("_", string.Empty, StringComparison.Ordinal)
            .ToLowerInvariant();

        return normalized switch
        {
            "selectedappsonly" => "selectedappsonly",
            "entirecomputerexceptselectedapps" => "entirecomputerexceptselectedapps",
            _ => "entirecomputer"
        };
    }

    private static async Task<string> WriteTunnelConfigAsync(
        PipeRequest request,
        string fileName,
        CancellationToken cancellationToken)
    {
        var directory = GetProfileDirectory(GetProfileKey(request));
        var configPath = Path.Combine(directory, fileName);
        await File.WriteAllTextAsync(configPath, request.TunnelConfig.Trim() + Environment.NewLine, cancellationToken);

        return configPath;
    }

    private static string GetProfileDirectory(string profileKey)
    {
        var directory = Path.Combine(GetRuntimeRoot(), SanitizeName(profileKey));
        Directory.CreateDirectory(directory);

        return directory;
    }

    private static string GetRuntimeRoot()
    {
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        return Path.Combine(programData, "SamhainSecurity", "Service", "runtime");
    }

    private static void CleanupProfileRuntime(string profileKey)
    {
        SafeDeleteRuntimeDirectory(Path.Combine(GetRuntimeRoot(), SanitizeName(profileKey)));
    }

    private static void CleanupExpiredRuntime()
    {
        CleanupExpiredRuntime(RuntimeRetention);
    }

    private static void CleanupExpiredRuntime(TimeSpan retention)
    {
        var root = GetRuntimeRoot();
        if (!Directory.Exists(root))
        {
            return;
        }

        foreach (var directory in Directory.GetDirectories(root))
        {
            try
            {
                var lastWrite = Directory.GetLastWriteTimeUtc(directory);
                if (DateTime.UtcNow - lastWrite > retention)
                {
                    SafeDeleteRuntimeDirectory(directory);
                }
            }
            catch
            {
                // Runtime cleanup must not prevent service startup or shutdown.
            }
        }
    }

    private static void SafeDeleteRuntimeDirectory(string directory)
    {
        try
        {
            if (!Directory.Exists(directory) || !IsUnderRuntimeRoot(directory))
            {
                return;
            }

            Directory.Delete(directory, recursive: true);
        }
        catch
        {
            // Best-effort cleanup. Engines can briefly keep handles open.
        }
    }

    private static bool IsUnderRuntimeRoot(string path)
    {
        var root = Path.GetFullPath(GetRuntimeRoot()).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        var target = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        return target.StartsWith(root, StringComparison.OrdinalIgnoreCase);
    }

    private static string ResolveSingBox(string enginePath)
    {
        return ResolveEngine(
            enginePath,
            "sing-box.exe",
            Path.Combine("engines", "sing-box", "sing-box.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "sing-box", "sing-box.exe"));
    }

    private static string ResolveWireGuard(string enginePath)
    {
        return ResolveEngine(
            enginePath,
            "wireguard.exe",
            Path.Combine("engines", "wireguard", "wireguard.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WireGuard", "wireguard.exe"));
    }

    private static string ResolveAmneziaWireGuard(string enginePath)
    {
        return ResolveEngine(
            enginePath,
            "awg-quick.exe",
            Path.Combine("engines", "amneziawg", "awg-quick.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "AmneziaWG", "awg-quick.exe"));
    }

    private static string ResolveEngine(
        string enginePath,
        string executableName,
        string bundledRelativePath,
        string programFilesPath)
    {
        if (!string.IsNullOrWhiteSpace(enginePath))
        {
            var candidate = Path.IsPathRooted(enginePath)
                ? enginePath
                : Path.Combine(AppContext.BaseDirectory, enginePath);

            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        var bundled = Path.Combine(AppContext.BaseDirectory, bundledRelativePath);
        if (File.Exists(bundled))
        {
            return bundled;
        }

        return File.Exists(programFilesPath)
            ? programFilesPath
            : executableName;
    }

    private static string GetProfileKey(PipeRequest request)
    {
        return string.IsNullOrWhiteSpace(request.ProfileId)
            ? request.ProfileName
            : request.ProfileId;
    }

    private static string GetTunnelName(PipeRequest request)
    {
        return SanitizeName(request.ProfileName);
    }

    private static string NormalizeProtocol(string protocolName)
    {
        return protocolName
            .Replace(" ", string.Empty, StringComparison.Ordinal)
            .Replace("-", string.Empty, StringComparison.Ordinal)
            .Replace("_", string.Empty, StringComparison.Ordinal)
            .ToLowerInvariant();
    }

    private static string SanitizeName(string value)
    {
        var cleaned = new string(value
            .Where(character => char.IsLetterOrDigit(character) || character is '-' or '_')
            .ToArray());

        return string.IsNullOrWhiteSpace(cleaned)
            ? "samhain"
            : cleaned;
    }

    private static async Task<PipeResponse> RunAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken)
    {
        using var process = CreateProcess(fileName, arguments);
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;

        process.Start();
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        var output = await outputTask;
        var error = await errorTask;

        return new PipeResponse(process.ExitCode, output, error);
    }

    private static Process StartProcess(
        string fileName,
        IEnumerable<string> arguments,
        string? workingDirectory = null)
    {
        var process = CreateProcess(fileName, arguments);
        process.StartInfo.WorkingDirectory = workingDirectory ?? string.Empty;
        process.StartInfo.RedirectStandardOutput = false;
        process.StartInfo.RedirectStandardError = false;
        process.Start();

        return process;
    }

    private static Process CreateProcess(string fileName, IEnumerable<string> arguments)
    {
        var process = new Process();
        process.StartInfo.FileName = fileName;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        return process;
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // The process may have exited between the check and kill.
        }
    }
}

public sealed record AppRoutingTargets(string[] ProcessPaths, string[] ProcessNames)
{
    public int Count => ProcessPaths.Length + ProcessNames.Length;

    public bool HasTargets => Count > 0;
}
