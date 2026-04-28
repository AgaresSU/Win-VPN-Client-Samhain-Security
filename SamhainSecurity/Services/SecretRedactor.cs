using System.Text.RegularExpressions;

namespace SamhainSecurity.Services;

public static partial class SecretRedactor
{
    public static string Redact(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return value;
        }

        var redacted = SubscriptionTokenQueryRegex().Replace(value, "${prefix}****");
        redacted = SubscriptionTokenPathRegex().Replace(redacted, "${prefix}****");
        redacted = VlessUriRegex().Replace(redacted, "vless://****");
        redacted = PrivateKeyRegex().Replace(redacted, "${prefix}****");
        redacted = JsonTokenRegex().Replace(redacted, "${prefix}****${suffix}");

        return redacted;
    }

    [GeneratedRegex(@"(?<prefix>[?&](?:token|access_token|key)=)[^&\s]+", RegexOptions.IgnoreCase)]
    private static partial Regex SubscriptionTokenQueryRegex();

    [GeneratedRegex(@"(?<prefix>/api/sub/)[^/\s?]+", RegexOptions.IgnoreCase)]
    private static partial Regex SubscriptionTokenPathRegex();

    [GeneratedRegex(@"vless://[^\s""']+", RegexOptions.IgnoreCase)]
    private static partial Regex VlessUriRegex();

    [GeneratedRegex(@"(?<prefix>^\s*PrivateKey\s*=\s*).+$", RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex PrivateKeyRegex();

    [GeneratedRegex(@"(?<prefix>""(?:token|password|privateKey|private_key|uuid)""\s*:\s*"")[^""]+(?<suffix>"")", RegexOptions.IgnoreCase)]
    private static partial Regex JsonTokenRegex();
}
