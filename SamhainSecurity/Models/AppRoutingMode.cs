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
}
