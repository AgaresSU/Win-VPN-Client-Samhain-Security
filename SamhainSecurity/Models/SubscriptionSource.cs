namespace SamhainSecurity.Models;

public sealed class SubscriptionSource
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");

    public string Name { get; set; } = "Samhain Security";

    public string EncryptedUrl { get; set; } = string.Empty;

    public bool IsEnabled { get; set; } = true;

    public DateTimeOffset? LastUpdatedAt { get; set; }

    public int LastImportedCount { get; set; }

    public string LastStatus { get; set; } = string.Empty;

    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}
