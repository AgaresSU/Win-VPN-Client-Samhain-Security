using System.IO;

namespace SamhainSecurity.Services;

public sealed class ServiceControlService
{
    private const string ServiceName = "SamhainSecurity.Service";

    public async Task<CommandResult> EnsureInstalledAndStartedAsync(CancellationToken cancellationToken = default)
    {
        var status = await QueryAsync(cancellationToken);
        if (status.IsSuccess && status.Output.Contains("RUNNING", StringComparison.OrdinalIgnoreCase))
        {
            return new CommandResult(0, "Samhain Security Service is already running", string.Empty);
        }

        if (!AdminElevationService.IsAdministrator())
        {
            return new CommandResult(1, string.Empty, "Administrator rights are required to install or start the service.");
        }

        if (!status.IsSuccess || status.CombinedOutput.Contains("does not exist", StringComparison.OrdinalIgnoreCase))
        {
            var executablePath = FindServiceExecutable();
            if (string.IsNullOrWhiteSpace(executablePath))
            {
                return new CommandResult(1, string.Empty, "SamhainSecurity.Service.exe was not found next to the app. Publish the service or copy it beside the desktop executable.");
            }

            var installResult = await ProcessRunner.RunProcessAsync(executablePath, ["install"], cancellationToken);
            if (!installResult.IsSuccess)
            {
                return installResult;
            }
        }

        return await StartAsync(cancellationToken);
    }

    public Task<CommandResult> QueryAsync(CancellationToken cancellationToken = default)
    {
        return ProcessRunner.RunProcessAsync("sc.exe", ["query", ServiceName], cancellationToken);
    }

    public Task<CommandResult> StartAsync(CancellationToken cancellationToken = default)
    {
        return ProcessRunner.RunProcessAsync("sc.exe", ["start", ServiceName], cancellationToken);
    }

    public Task<CommandResult> StopAsync(CancellationToken cancellationToken = default)
    {
        return ProcessRunner.RunProcessAsync("sc.exe", ["stop", ServiceName], cancellationToken);
    }

    private static string FindServiceExecutable()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "SamhainSecurity.Service.exe"),
            Path.Combine(AppContext.BaseDirectory, "service", "SamhainSecurity.Service.exe"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "..", "SamhainSecurity.Service", "bin", "Release", "net9.0-windows", "win-x64", "publish", "SamhainSecurity.Service.exe")),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "SamhainSecurity.Service", "bin", "Release", "net9.0-windows", "win-x64", "publish", "SamhainSecurity.Service.exe")),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "SamhainSecurity.Service", "bin", "Debug", "net9.0-windows", "SamhainSecurity.Service.exe"))
        };

        return candidates.FirstOrDefault(File.Exists) ?? string.Empty;
    }
}
