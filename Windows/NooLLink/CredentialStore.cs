using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace NooLLink;

internal static class CredentialStore
{
    internal static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NooL Link");
    private static string CredentialPath => Path.Combine(Root, "connection.dat");

    public static LinkCredentials? Load()
    {
        if (!File.Exists(CredentialPath)) return null;
        var protectedBytes = File.ReadAllBytes(CredentialPath);
        if (protectedBytes.Length > 16 * 1024) throw new InvalidDataException("Повреждены настройки подключения.");
        var plain = Transform(protectedBytes, protect: false);
        try
        {
            var result = JsonSerializer.Deserialize<LinkCredentials>(plain, LinkClient.Json)
                ?? throw new InvalidDataException("Повреждены настройки подключения.");
            if (!PairInvitation.IsPrivateIPv4(result.Host) || result.Port is < 1 or > 65535 ||
                string.IsNullOrEmpty(result.Fingerprint) || result.Fingerprint.Length != 64 || !result.Fingerprint.All(Uri.IsHexDigit) ||
                !PairInvitation.IsToken(result.Token) || !Guid.TryParse(result.LocalDeviceID, out _) ||
                !Guid.TryParse(result.DeviceID, out _) || (result.Hostname is not null && !PairInvitation.IsLocalHostname(result.Hostname)))
                throw new InvalidDataException("Повреждены настройки подключения.");
            return result;
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public static void Save(LinkCredentials credentials)
    {
        Directory.CreateDirectory(Root);
        var plain = JsonSerializer.SerializeToUtf8Bytes(credentials, LinkClient.Json);
        try
        {
            var target = CredentialPath + ".new";
            File.WriteAllBytes(target, Transform(plain, protect: true));
            File.Move(target, CredentialPath, overwrite: true);
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public static void Delete() => File.Delete(CredentialPath);

    private static byte[] Transform(byte[] input, bool protect)
    {
        var pointer = Marshal.AllocHGlobal(input.Length);
        try
        {
            Marshal.Copy(input, 0, pointer, input.Length);
            var source = new DataBlob { Length = input.Length, Data = pointer };
            DataBlob output;
            // CRYPTPROTECT_UI_FORBIDDEN; defaults to the current Windows user.
            var ok = protect
                ? CryptProtectData(ref source, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref source, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var bytes = new byte[output.Length];
                Marshal.Copy(output.Data, bytes, 0, bytes.Length);
                return bytes;
            }
            finally
            {
                for (var i = 0; i < output.Length; i++) Marshal.WriteByte(output.Data, i, 0);
                LocalFree(output.Data);
            }
        }
        finally
        {
            for (var i = 0; i < input.Length; i++) Marshal.WriteByte(pointer, i, 0);
            Marshal.FreeHGlobal(pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
}
