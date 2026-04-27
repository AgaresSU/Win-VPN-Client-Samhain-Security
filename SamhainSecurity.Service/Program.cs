using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging;

const string ServiceName = "SamhainSecurity.Service";
const string ServiceDisplayName = "Samhain Security Service";
const string ServiceDescription = "Privileged local tunnel supervisor for Samhain Security.";

if (args.Length > 0 && await TryHandleCommandAsync(args))
{
    return;
}

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options =>
{
    options.ServiceName = ServiceName;
});
builder.Services.AddSingleton<ProtectionPolicyService>();
builder.Services.AddHostedService<PipeServerWorker>();
builder.Logging.AddSimpleConsole(options =>
{
    options.SingleLine = true;
    options.TimestampFormat = "HH:mm:ss ";
});

await builder.Build().RunAsync();

static async Task<bool> TryHandleCommandAsync(string[] args)
{
    var command = args[0].Trim().ToLowerInvariant();

    switch (command)
    {
        case "install":
            await InstallAsync();
            return true;
        case "uninstall":
            await StopAsync();
            await RunScAsync(["delete", ServiceName]);
            return true;
        case "start":
            await StartAsync();
            return true;
        case "stop":
            await StopAsync();
            return true;
        case "restart":
            await StopAsync();
            await StartAsync();
            return true;
        case "status":
            await RunScAsync(["query", ServiceName]);
            return true;
        case "run":
        case "--run-service":
            return false;
        default:
            PrintUsage();
            return true;
    }
}

static async Task InstallAsync()
{
    var executablePath = Environment.ProcessPath
        ?? throw new InvalidOperationException("Cannot resolve service executable path.");
    var binPath = $"\"{executablePath}\" --run-service";

    await RunScAsync(["create", ServiceName, "binPath=", binPath, "start=", "auto", "DisplayName=", ServiceDisplayName]);
    await RunScAsync(["description", ServiceName, ServiceDescription]);
}

static Task StartAsync()
{
    return RunScAsync(["start", ServiceName]);
}

static Task StopAsync()
{
    return RunScAsync(["stop", ServiceName], allowFailure: true);
}

static async Task RunScAsync(IReadOnlyList<string> arguments, bool allowFailure = false)
{
    using var process = new Process();
    process.StartInfo.FileName = "sc.exe";
    process.StartInfo.UseShellExecute = false;
    process.StartInfo.RedirectStandardOutput = true;
    process.StartInfo.RedirectStandardError = true;
    process.StartInfo.CreateNoWindow = true;

    foreach (var argument in arguments)
    {
        process.StartInfo.ArgumentList.Add(argument);
    }

    process.Start();
    var output = await process.StandardOutput.ReadToEndAsync();
    var error = await process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();

    if (!string.IsNullOrWhiteSpace(output))
    {
        Console.WriteLine(output.Trim());
    }

    if (!string.IsNullOrWhiteSpace(error))
    {
        Console.Error.WriteLine(error.Trim());
    }

    if (process.ExitCode != 0 && !allowFailure)
    {
        Environment.ExitCode = process.ExitCode;
    }
}

static void PrintUsage()
{
    Console.WriteLine("""
    Samhain Security Service

    Commands:
      install    Install Windows Service
      uninstall  Stop and delete Windows Service
      start      Start Windows Service
      stop       Stop Windows Service
      restart    Restart Windows Service
      status     Query Windows Service status
      run        Run as console host
    """);
}

public sealed class PipeServerWorker : BackgroundService
{
    private const string PipeName = "SamhainSecurity.Service.v1";
    private readonly ILogger<PipeServerWorker> _logger;
    private readonly ProtectionPolicyService _protectionPolicyService;

    public PipeServerWorker(
        ILogger<PipeServerWorker> logger,
        ProtectionPolicyService protectionPolicyService)
    {
        _logger = logger;
        _protectionPolicyService = protectionPolicyService;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Samhain Security service started. Pipe: {PipeName}", PipeName);

        while (!stoppingToken.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(
                PipeName,
                PipeDirection.InOut,
                NamedPipeServerStream.MaxAllowedServerInstances,
                PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous);

            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken);
                await HandleClientAsync(pipe, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Pipe request failed");
            }
        }
    }

    private async Task HandleClientAsync(NamedPipeServerStream pipe, CancellationToken cancellationToken)
    {
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, Encoding.UTF8, leaveOpen: true)
        {
            AutoFlush = true
        };

        var requestJson = await reader.ReadLineAsync(cancellationToken);
        var request = JsonSerializer.Deserialize<PipeRequest>(requestJson ?? "{}") ?? new PipeRequest();
        var response = await HandleAsync(request, cancellationToken);
        await writer.WriteLineAsync(JsonSerializer.Serialize(response));
    }

    private Task<PipeResponse> HandleAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        return request.Action switch
        {
            "ping" => Task.FromResult(PipeResponse.Success("pong")),
            "connect-windows-native" => ConnectWindowsNativeAsync(request, cancellationToken),
            "disconnect-windows-native" => DisconnectWindowsNativeAsync(request, cancellationToken),
            "status-windows-native" => StatusWindowsNativeAsync(request, cancellationToken),
            "protection-apply" => _protectionPolicyService.ApplyAsync(request, cancellationToken),
            "protection-remove" => _protectionPolicyService.RemoveAsync(cancellationToken),
            "protection-status" => _protectionPolicyService.StatusAsync(cancellationToken),
            _ => Task.FromResult(PipeResponse.Fail("Unknown action: " + request.Action))
        };
    }

    private static Task<PipeResponse> ConnectWindowsNativeAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.ProfileName))
        {
            return Task.FromResult(PipeResponse.Fail("ProfileName is required"));
        }

        var arguments = new List<string> { request.ProfileName };
        if (!string.IsNullOrWhiteSpace(request.UserName))
        {
            arguments.Add(request.UserName);
            arguments.Add(request.Password ?? string.Empty);
        }

        return RunAsync("rasdial.exe", arguments, cancellationToken);
    }

    private static Task<PipeResponse> DisconnectWindowsNativeAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.ProfileName))
        {
            return Task.FromResult(PipeResponse.Fail("ProfileName is required"));
        }

        return RunAsync("rasdial.exe", [request.ProfileName, "/disconnect"], cancellationToken);
    }

    private static Task<PipeResponse> StatusWindowsNativeAsync(PipeRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.ProfileName))
        {
            return Task.FromResult(PipeResponse.Fail("ProfileName is required"));
        }

        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $name = '{{request.ProfileName.Replace("'", "''")}}'
        $connection = Get-VpnConnection -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $connection) {
            'NotFound'
        } else {
            $connection.ConnectionStatus
        }
        """;

        var encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        return RunAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodedCommand], cancellationToken);
    }

    private static async Task<PipeResponse> RunAsync(
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
}

public sealed class PipeRequest
{
    public string Action { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public string UserName { get; set; } = string.Empty;

    public string Password { get; set; } = string.Empty;

    public string ProtocolName { get; set; } = string.Empty;

    public string ServerAddress { get; set; } = string.Empty;

    public int ServerPort { get; set; }

    public string EnginePath { get; set; } = string.Empty;

    public bool KillSwitchEnabled { get; set; }

    public bool DnsLeakProtectionEnabled { get; set; }

    public bool AllowLanTraffic { get; set; }

    public string DnsServers { get; set; } = string.Empty;
}

public sealed record PipeResponse(int ExitCode, string Output, string Error)
{
    public static PipeResponse Success(string output)
    {
        return new PipeResponse(0, output, string.Empty);
    }

    public static PipeResponse Fail(string error)
    {
        return new PipeResponse(1, string.Empty, error);
    }
}
