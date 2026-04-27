using System.Diagnostics;
using System.IO;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class EngineVersionService
{
    public async Task<string> DetectVersionAsync(
        VpnProtocolType protocol,
        string enginePath,
        CancellationToken cancellationToken = default)
    {
        return protocol switch
        {
            VpnProtocolType.VlessReality => await DetectExternalVersionAsync(
                EnginePathResolver.ResolveSingBox(enginePath),
                [["version"], ["--version"]],
                cancellationToken),
            VpnProtocolType.WireGuard => await DetectWireGuardVersionAsync(enginePath, cancellationToken),
            VpnProtocolType.AmneziaWireGuard => await DetectExternalVersionAsync(
                EnginePathResolver.ResolveAmneziaWireGuard(enginePath),
                [["--version"], ["version"], ["-v"]],
                cancellationToken),
            _ => "Windows built-in"
        };
    }

    private static async Task<string> DetectWireGuardVersionAsync(string enginePath, CancellationToken cancellationToken)
    {
        var resolvedPath = EnginePathResolver.ResolveWireGuard(enginePath);
        var fileVersion = TryGetFileVersion(resolvedPath);
        if (!string.IsNullOrWhiteSpace(fileVersion))
        {
            return fileVersion;
        }

        return await DetectExternalVersionAsync(resolvedPath, [["/?"], ["--version"]], cancellationToken);
    }

    private static async Task<string> DetectExternalVersionAsync(
        string resolvedPath,
        IReadOnlyList<IReadOnlyList<string>> argumentSets,
        CancellationToken cancellationToken)
    {
        if (!EnginePathResolver.IsPathAvailable(resolvedPath))
        {
            return "missing";
        }

        var fileVersion = TryGetFileVersion(resolvedPath);
        if (!string.IsNullOrWhiteSpace(fileVersion))
        {
            return fileVersion;
        }

        foreach (var arguments in argumentSets)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(3));

            try
            {
                var result = await ProcessRunner.RunProcessAsync(resolvedPath, arguments, timeout.Token);
                var output = result.CombinedOutput
                    .Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                    .FirstOrDefault();

                if (!string.IsNullOrWhiteSpace(output))
                {
                    return output;
                }
            }
            catch
            {
                // Some engines do not expose a stable version command.
            }
        }

        return "found, version unknown";
    }

    private static string TryGetFileVersion(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return string.Empty;
            }

            var info = FileVersionInfo.GetVersionInfo(path);
            return !string.IsNullOrWhiteSpace(info.ProductVersion)
                ? info.ProductVersion
                : info.FileVersion ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }
}
