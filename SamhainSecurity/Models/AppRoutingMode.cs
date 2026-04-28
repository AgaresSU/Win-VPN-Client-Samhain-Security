namespace SamhainSecurity.Models;

public enum AppRoutingMode
{
    EntireComputer,
    SelectedAppsOnly,
    EntireComputerExceptSelectedApps
}

public static class AppRoutingModeExtensions
{
    public static string ToDisplayName(this AppRoutingMode mode) => mode switch
    {
        AppRoutingMode.SelectedAppsOnly => "Только выбранные приложения",
        AppRoutingMode.EntireComputerExceptSelectedApps => "Весь компьютер, кроме выбранных приложений",
        _ => "Весь компьютер"
    };

    public static AppRoutingMode GetEffectiveAppRoutingMode(this VpnProfile profile)
    {
        return profile.AppRoutingMode == AppRoutingMode.EntireComputer
            && profile.SplitTunneling
            && AppRoutingPathParser.Parse(profile.AppRoutingPaths).HasTargets
            ? AppRoutingMode.SelectedAppsOnly
            : profile.AppRoutingMode;
    }
}
