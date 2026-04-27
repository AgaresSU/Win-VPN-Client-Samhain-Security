using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

const string PipeName = "SamhainSecurity.Service.v1";

Console.WriteLine("Samhain Security service prototype started.");
Console.WriteLine("Pipe: " + PipeName);

while (true)
{
    await using var pipe = new NamedPipeServerStream(
        PipeName,
        PipeDirection.InOut,
        NamedPipeServerStream.MaxAllowedServerInstances,
        PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous);

    await pipe.WaitForConnectionAsync();

    try
    {
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, Encoding.UTF8, leaveOpen: true)
        {
            AutoFlush = true
        };

        var requestJson = await reader.ReadLineAsync();
        var request = JsonSerializer.Deserialize<PipeRequest>(requestJson ?? "{}") ?? new PipeRequest();
        var response = await HandleAsync(request);
        await writer.WriteLineAsync(JsonSerializer.Serialize(response));
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine(ex);
    }
}

static Task<PipeResponse> HandleAsync(PipeRequest request)
{
    return request.Action switch
    {
        "ping" => Task.FromResult(PipeResponse.Success("pong")),
        "connect-windows-native" => ConnectWindowsNativeAsync(request),
        "disconnect-windows-native" => DisconnectWindowsNativeAsync(request),
        "status-windows-native" => StatusWindowsNativeAsync(request),
        _ => Task.FromResult(PipeResponse.Fail("Unknown action: " + request.Action))
    };
}

static Task<PipeResponse> ConnectWindowsNativeAsync(PipeRequest request)
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

    return RunAsync("rasdial.exe", arguments);
}

static Task<PipeResponse> DisconnectWindowsNativeAsync(PipeRequest request)
{
    if (string.IsNullOrWhiteSpace(request.ProfileName))
    {
        return Task.FromResult(PipeResponse.Fail("ProfileName is required"));
    }

    return RunAsync("rasdial.exe", [request.ProfileName, "/disconnect"]);
}

static Task<PipeResponse> StatusWindowsNativeAsync(PipeRequest request)
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
    return RunAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encodedCommand]);
}

static async Task<PipeResponse> RunAsync(string fileName, IEnumerable<string> arguments)
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
    var output = await process.StandardOutput.ReadToEndAsync();
    var error = await process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync();

    return new PipeResponse(process.ExitCode, output, error);
}

public sealed class PipeRequest
{
    public string Action { get; set; } = string.Empty;

    public string ProfileName { get; set; } = string.Empty;

    public string UserName { get; set; } = string.Empty;

    public string Password { get; set; } = string.Empty;
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
