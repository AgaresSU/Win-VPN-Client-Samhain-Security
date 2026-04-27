using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using VpnClientWindows.Models;

namespace VpnClientWindows.Services;

public sealed class SingBoxVpnService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly Dictionary<string, Process> _processes = [];
    private readonly RuntimePathService _runtimePathService = new();

    public async Task<CommandResult> ConnectAsync(VpnProfile profile, CancellationToken cancellationToken = default)
    {
        Disconnect(profile.Id);

        var validationError = Validate(profile);
        if (!string.IsNullOrWhiteSpace(validationError))
        {
            return new CommandResult(1, string.Empty, validationError);
        }

        var enginePath = EnginePathResolver.ResolveSingBox(profile.EnginePath);
        var profileDirectory = _runtimePathService.GetProfileDirectory(profile.Id);
        var configPath = Path.Combine(profileDirectory, "sing-box-vless-reality.json");
        await File.WriteAllTextAsync(configPath, BuildConfig(profile), cancellationToken);

        try
        {
            var checkResult = await ProcessRunner.RunProcessAsync(enginePath, ["check", "-c", configPath], cancellationToken);
            if (!checkResult.IsSuccess)
            {
                return checkResult;
            }

            var process = ProcessRunner.StartProcess(enginePath, ["run", "-c", configPath], profileDirectory);
            _processes[profile.Id] = process;

            await Task.Delay(1200, cancellationToken);
            if (process.HasExited)
            {
                _processes.Remove(profile.Id);
                return new CommandResult(process.ExitCode, string.Empty, "sing-box завершился сразу после запуска");
            }

            return new CommandResult(0, $"sing-box запущен. Config: {configPath}", string.Empty);
        }
        catch (Exception ex)
        {
            return new CommandResult(1, string.Empty, ex.Message);
        }
    }

    public CommandResult Disconnect(string profileId)
    {
        if (!_processes.TryGetValue(profileId, out var process))
        {
            return new CommandResult(0, "sing-box не запущен этим приложением", string.Empty);
        }

        ProcessRunner.TryKill(process);
        process.Dispose();
        _processes.Remove(profileId);

        return new CommandResult(0, "sing-box остановлен", string.Empty);
    }

    public CommandResult GetStatus(string profileId)
    {
        return _processes.TryGetValue(profileId, out var process) && !process.HasExited
            ? new CommandResult(0, "Running", string.Empty)
            : new CommandResult(0, "Stopped", string.Empty);
    }

    private static string BuildConfig(VpnProfile profile)
    {
        var flow = string.IsNullOrWhiteSpace(profile.VlessFlow)
            ? null
            : profile.VlessFlow.Trim();

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
                    interface_name = RuntimePathService.SanitizeName(profile.Name),
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
                    server = profile.ServerAddress,
                    server_port = profile.ServerPort,
                    uuid = profile.VlessUuid,
                    flow,
                    network = "tcp",
                    tls = new
                    {
                        enabled = true,
                        server_name = profile.RealityServerName,
                        utls = new
                        {
                            enabled = true,
                            fingerprint = string.IsNullOrWhiteSpace(profile.RealityFingerprint)
                                ? "chrome"
                                : profile.RealityFingerprint
                        },
                        reality = new
                        {
                            enabled = true,
                            public_key = profile.RealityPublicKey,
                            short_id = profile.RealityShortId
                        }
                    }
                },
                new
                {
                    type = "direct",
                    tag = "direct"
                }
            },
            route = new
            {
                auto_detect_interface = true,
                final = "proxy"
            }
        };

        return JsonSerializer.Serialize(config, JsonOptions);
    }

    private static string Validate(VpnProfile profile)
    {
        if (string.IsNullOrWhiteSpace(profile.ServerAddress))
        {
            return "Введите сервер VLESS";
        }

        if (profile.ServerPort <= 0 || profile.ServerPort > 65535)
        {
            return "Введите корректный порт VLESS";
        }

        if (string.IsNullOrWhiteSpace(profile.VlessUuid))
        {
            return "Введите UUID VLESS";
        }

        if (string.IsNullOrWhiteSpace(profile.RealityServerName))
        {
            return "Введите Reality SNI";
        }

        if (string.IsNullOrWhiteSpace(profile.RealityPublicKey))
        {
            return "Введите Reality public key";
        }

        return string.Empty;
    }
}
