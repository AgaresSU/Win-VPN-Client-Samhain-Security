namespace SamhainSecurity.Models;

public sealed class SubscriptionImportResult
{
    public IReadOnlyList<VpnProfile> Profiles { get; init; } = [];

    public int VlessLinksSeen { get; init; }

    public int JsonProfilesSeen { get; init; }

    public int AwgProfilesSeen { get; init; }

    public int UnsupportedLinksSeen { get; init; }

    public bool WasBase64Decoded { get; init; }

    public bool JsonDetected { get; init; }

    public string SourceFormat { get; init; } = "text";

    public string Message { get; init; } = string.Empty;
}
