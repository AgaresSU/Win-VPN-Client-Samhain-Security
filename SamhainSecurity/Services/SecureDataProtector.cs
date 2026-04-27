using System.Security.Cryptography;
using System.Text;

namespace SamhainSecurity.Services;

public sealed class SecureDataProtector
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("VpnClientWindows.ProfileSecrets.v1");

    public string Protect(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        var bytes = Encoding.UTF8.GetBytes(value);
        var encrypted = ProtectedData.Protect(bytes, Entropy, DataProtectionScope.CurrentUser);

        return Convert.ToBase64String(encrypted);
    }

    public string Unprotect(string? encryptedValue)
    {
        if (string.IsNullOrWhiteSpace(encryptedValue))
        {
            return string.Empty;
        }

        try
        {
            var encrypted = Convert.FromBase64String(encryptedValue);
            var bytes = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);

            return Encoding.UTF8.GetString(bytes);
        }
        catch
        {
            return string.Empty;
        }
    }
}
