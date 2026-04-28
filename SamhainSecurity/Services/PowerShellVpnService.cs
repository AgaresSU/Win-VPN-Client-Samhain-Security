using System.Text;
using SamhainSecurity.Models;

namespace SamhainSecurity.Services;

public sealed class PowerShellVpnService
{
    private readonly SamhainServiceClient _serviceClient = new();

    public Task<CommandResult> SaveOrUpdateProfileAsync(
        VpnProfile profile,
        string l2tpPsk,
        CancellationToken cancellationToken = default)
    {
        var script = BuildSaveOrUpdateScript(profile, l2tpPsk);

        return RunPowerShellAsync(script, cancellationToken);
    }

    public Task<CommandResult> RemoveProfileAsync(string profileName, CancellationToken cancellationToken = default)
    {
        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $name = {{ToPowerShellLiteral(profileName)}}
        Remove-VpnConnection -Name $name -Force -ErrorAction SilentlyContinue | Out-Null
        """;

        return RunPowerShellAsync(script, cancellationToken);
    }

    public Task<CommandResult> GetStatusAsync(string profileName, CancellationToken cancellationToken = default)
    {
        return GetStatusInternalAsync(profileName, cancellationToken);
    }

    private async Task<CommandResult> GetStatusInternalAsync(string profileName, CancellationToken cancellationToken)
    {
        var serviceResult = await _serviceClient.GetWindowsNativeStatusAsync(profileName, cancellationToken);
        if (serviceResult is not null)
        {
            return serviceResult;
        }

        var script = $$"""
        $ErrorActionPreference = 'Stop'
        $name = {{ToPowerShellLiteral(profileName)}}
        $connection = Get-VpnConnection -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $connection) {
            'NotFound'
        } else {
            $connection.ConnectionStatus
        }
        """;

        return await RunPowerShellAsync(script, cancellationToken);
    }

    public Task<CommandResult> ConnectAsync(
        VpnProfile profile,
        string password,
        CancellationToken cancellationToken = default)
    {
        return ConnectInternalAsync(profile, password, cancellationToken);
    }

    private async Task<CommandResult> ConnectInternalAsync(
        VpnProfile profile,
        string password,
        CancellationToken cancellationToken)
    {
        var serviceResult = await _serviceClient.ConnectWindowsNativeAsync(profile, password, cancellationToken);
        if (serviceResult is not null)
        {
            return serviceResult;
        }

        var arguments = new List<string> { profile.Name };

        if (!string.IsNullOrWhiteSpace(profile.UserName))
        {
            arguments.Add(profile.UserName);
            arguments.Add(password ?? string.Empty);
        }

        return await ProcessRunner.RunProcessAsync("rasdial.exe", arguments, cancellationToken);
    }

    public Task<CommandResult> DisconnectAsync(string profileName, CancellationToken cancellationToken = default)
    {
        return DisconnectInternalAsync(profileName, cancellationToken);
    }

    private async Task<CommandResult> DisconnectInternalAsync(string profileName, CancellationToken cancellationToken)
    {
        var serviceResult = await _serviceClient.DisconnectWindowsNativeAsync(profileName, cancellationToken);
        if (serviceResult is not null)
        {
            return serviceResult;
        }

        return await ProcessRunner.RunProcessAsync("rasdial.exe", [profileName, "/disconnect"], cancellationToken);
    }

    private static string BuildSaveOrUpdateScript(VpnProfile profile, string l2tpPsk)
    {
        var name = ToPowerShellLiteral(profile.Name);
        var server = ToPowerShellLiteral(profile.ServerAddress);
        var tunnelType = ToPowerShellLiteral(profile.TunnelType.ToPowerShellValue());
        var splitTunneling = profile.GetEffectiveAppRoutingMode() == AppRoutingMode.SelectedAppsOnly ? "$true" : "$false";
        var psk = ToPowerShellLiteral(l2tpPsk);

        return $$"""
        $ErrorActionPreference = 'Stop'
        $name = {{name}}
        $server = {{server}}
        $tunnelType = {{tunnelType}}
        $splitTunneling = {{splitTunneling}}
        $l2tpPsk = {{psk}}

        $connection = Get-VpnConnection -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $connection) {
            $params = @{
                Name = $name
                ServerAddress = $server
                TunnelType = $tunnelType
                RememberCredential = $true
                Force = $true
            }

            if ($splitTunneling) {
                $params['SplitTunneling'] = $true
            }

            if ($tunnelType -eq 'L2tp' -and -not [string]::IsNullOrWhiteSpace($l2tpPsk)) {
                $params['L2tpPsk'] = $l2tpPsk
            }

            Add-VpnConnection @params | Out-Null
        } else {
            $params = @{
                Name = $name
                ServerAddress = $server
                TunnelType = $tunnelType
                SplitTunneling = $splitTunneling
                RememberCredential = $true
                Force = $true
            }

            if ($tunnelType -eq 'L2tp' -and -not [string]::IsNullOrWhiteSpace($l2tpPsk)) {
                $params['L2tpPsk'] = $l2tpPsk
            }

            Set-VpnConnection @params | Out-Null
        }

        (Get-VpnConnection -Name $name).ConnectionStatus
        """;
    }

    private static Task<CommandResult> RunPowerShellAsync(string script, CancellationToken cancellationToken)
    {
        var encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        var arguments = new[]
        {
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            encodedCommand
        };

        return ProcessRunner.RunProcessAsync("powershell.exe", arguments, cancellationToken);
    }

    private static string ToPowerShellLiteral(string? value)
    {
        return "'" + (value ?? string.Empty).Replace("'", "''") + "'";
    }
}
