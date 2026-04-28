namespace SamhainSecurity.Models;

public sealed class AppRoutingModeOption
{
    public AppRoutingModeOption(AppRoutingMode value)
    {
        Value = value;
        DisplayName = value.ToDisplayName();
    }

    public AppRoutingMode Value { get; }

    public string DisplayName { get; }
}
