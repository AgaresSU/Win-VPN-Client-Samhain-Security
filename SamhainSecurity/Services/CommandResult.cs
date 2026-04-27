namespace VpnClientWindows.Services;

public sealed record CommandResult(int ExitCode, string Output, string Error)
{
    public bool IsSuccess => ExitCode == 0;

    public string CombinedOutput
    {
        get
        {
            var parts = new[] { Output, Error }
                .Where(part => !string.IsNullOrWhiteSpace(part))
                .Select(part => part.Trim());

            return string.Join(Environment.NewLine, parts);
        }
    }
}
