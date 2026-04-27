using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class EnvironmentDiagnosticsService
{
    private readonly EngineVersionService _engineVersionService = new();
    private readonly SamhainServiceClient _serviceClient = new();
    private readonly ServiceControlService _serviceControlService = new();

    public async Task<string> BuildReportAsync(VpnProtocolType protocol, string enginePath, CancellationToken cancellationToken = default)
    {
        var lines = new List<string>
        {
            "Diagnostics",
            $"Version: {GetType().Assembly.GetName().Version}",
            $"OS: {Environment.OSVersion}",
            $"Process: {(Environment.Is64BitProcess ? "x64" : "x86")}",
            $"Admin: {(AdminElevationService.IsAdministrator() ? "yes" : "no")}",
            $"Service control: {await GetServiceStatusAsync(cancellationToken)}",
            $"Service pipe: {(await _serviceClient.IsAvailableAsync(cancellationToken) ? "available" : "not running")}",
            $"Protection: {await GetProtectionStatusAsync(cancellationToken)}",
            $"App directory: {AppContext.BaseDirectory}",
            $"Current directory: {Environment.CurrentDirectory}"
        };

        lines.Add(await CheckCommandAsync("rasdial.exe", ["rasdial"], cancellationToken));
        lines.Add(await CheckPowerShellCmdletAsync("Add-VpnConnection", "Windows native add cmdlet", cancellationToken));
        lines.Add(await CheckPowerShellCmdletAsync("Get-VpnConnection", "Windows native status cmdlet", cancellationToken));

        if (protocol == VpnProtocolType.VlessReality)
        {
            lines.AddRange(BuildEngineReport("sing-box", EnginePathResolver.GetSingBoxCandidates(enginePath), EnginePathResolver.ResolveSingBox(enginePath)));
            lines.Add($"sing-box version: {await _engineVersionService.DetectVersionAsync(protocol, enginePath, cancellationToken)}");
        }
        else if (protocol == VpnProtocolType.WireGuard)
        {
            lines.AddRange(BuildEngineReport("WireGuard", EnginePathResolver.GetWireGuardCandidates(enginePath), EnginePathResolver.ResolveWireGuard(enginePath)));
            lines.Add($"WireGuard version: {await _engineVersionService.DetectVersionAsync(protocol, enginePath, cancellationToken)}");
            lines.Add(await CheckCommandAsync("sc.exe", ["query", "state=", "all"], cancellationToken));
        }
        else if (protocol == VpnProtocolType.AmneziaWireGuard)
        {
            lines.AddRange(BuildEngineReport("AmneziaWG", EnginePathResolver.GetAmneziaWireGuardCandidates(enginePath), EnginePathResolver.ResolveAmneziaWireGuard(enginePath)));
            lines.Add($"AmneziaWG version: {await _engineVersionService.DetectVersionAsync(protocol, enginePath, cancellationToken)}");
        }

        lines.Add("Hint: VLESS TUN, WireGuard tunnel services, and AmneziaWG usually need administrator rights.");

        return string.Join(Environment.NewLine, lines);
    }

    private static IEnumerable<string> BuildEngineReport(string title, IReadOnlyList<string> candidates, string resolvedPath)
    {
        yield return $"{title}: {FormatAvailability(resolvedPath)}";
        yield return $"{title} resolved: {resolvedPath}";

        foreach (var candidate in candidates.Take(6))
        {
            yield return $"  candidate: {candidate} [{FormatAvailability(candidate)}]";
        }

        if (!EnginePathResolver.IsPathAvailable(resolvedPath))
        {
            yield return $"Repair: select {title} executable manually or place it in the first portable candidate path above.";
        }
    }

    private static async Task<string> CheckCommandAsync(
        string title,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        try
        {
            var result = await ProcessRunner.RunProcessAsync("where.exe", [arguments[0]], cancellationToken);
            return result.IsSuccess
                ? $"{title}: found {result.Output.Trim().Split(Environment.NewLine).FirstOrDefault()}"
                : $"{title}: not found";
        }
        catch (Exception ex)
        {
            return $"{title}: check failed: {ex.Message}";
        }
    }

    private static async Task<string> CheckPowerShellCmdletAsync(string commandName, string displayName, CancellationToken cancellationToken)
    {
        try
        {
            var result = await ProcessRunner.RunProcessAsync(
                "powershell.exe",
                ["-NoProfile", "-Command", $"Get-Command {commandName} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name"],
                cancellationToken);

            return result.IsSuccess && result.Output.Contains(commandName, StringComparison.OrdinalIgnoreCase)
                ? $"{displayName}: found"
                : $"{displayName}: not found";
        }
        catch (Exception ex)
        {
            return $"{displayName}: check failed: {ex.Message}";
        }
    }

    private static string FormatAvailability(string path)
    {
        return EnginePathResolver.IsPathAvailable(path) ? "found" : "missing";
    }

    private async Task<string> GetServiceStatusAsync(CancellationToken cancellationToken)
    {
        var result = await _serviceControlService.QueryAsync(cancellationToken);
        if (!result.IsSuccess)
        {
            return "not installed";
        }

        var stateLine = result.Output
            .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(line => line.Contains("STATE", StringComparison.OrdinalIgnoreCase));

        return string.IsNullOrWhiteSpace(stateLine)
            ? "installed"
            : stateLine.Trim();
    }

    private async Task<string> GetProtectionStatusAsync(CancellationToken cancellationToken)
    {
        var result = await _serviceClient.GetProtectionStatusAsync(cancellationToken);
        if (result is null)
        {
            return "service unavailable";
        }

        var firstLine = result.Output
            .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault();

        return string.IsNullOrWhiteSpace(firstLine)
            ? "unknown"
            : firstLine;
    }
}
