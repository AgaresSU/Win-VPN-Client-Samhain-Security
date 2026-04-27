using System.Diagnostics;
using System.Reflection;
using System.Security.Principal;

namespace VpnClientWindows.Services;

public static class AdminElevationService
{
    public static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);

        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    public static bool TryRelaunchAsAdministrator(out string error)
    {
        error = string.Empty;

        try
        {
            var executablePath = Environment.ProcessPath
                ?? Assembly.GetExecutingAssembly().Location;

            var startInfo = new ProcessStartInfo
            {
                FileName = executablePath,
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = AppContext.BaseDirectory
            };

            Process.Start(startInfo);
            return true;
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }
}
