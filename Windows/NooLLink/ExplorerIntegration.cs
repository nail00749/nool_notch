using System.Runtime.InteropServices;

namespace NooLLink;

/// One "Send to → NooL Link — <Mac>" shortcut per paired Mac. Shortcuts are
/// recognised by their description, so user shortcuts are never touched.
internal static class ExplorerIntegration
{
    private const string LegacyDescription = "Отправить файлы на связанный Mac через NooL Link";
    private const string DescriptionPrefix = "NooL Link: отправить файлы на Mac ";
    private static string SendToFolder => Environment.GetFolderPath(Environment.SpecialFolder.SendTo);
    private static string MarkerPath => Path.Combine(CredentialStore.Root, "explorer-send-to");

    public static bool IsEnabled => File.Exists(MarkerPath) || ManagedShortcuts().Any();

    public static void SetEnabled(bool enabled, IReadOnlyList<LinkCredentials> macs)
    {
        Directory.CreateDirectory(CredentialStore.Root);
        if (enabled) File.WriteAllText(MarkerPath, "enabled");
        else File.Delete(MarkerPath);
        Sync(macs, enabled);
    }

    /// Recreates managed shortcuts for the current list of Macs.
    public static void Sync(IReadOnlyList<LinkCredentials> macs) => Sync(macs, IsEnabled);

    private static void Sync(IReadOnlyList<LinkCredentials> macs, bool enabled)
    {
        foreach (var path in ManagedShortcuts()) File.Delete(path);
        if (!enabled) return;
        var executable = Environment.ProcessPath ?? throw new IOException("Не найден исполняемый файл NooL Link.");
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var mac in macs)
        {
            var label = SafeLabel(mac.DeviceName);
            if (!used.Add(label)) label += " " + mac.DeviceID[..4];
            var path = Path.Combine(SendToFolder, $"NooL Link — {label}.lnk");
            // A file the user created under the same name is left alone.
            if (File.Exists(path)) continue;
            // SendTo appends every selected path as a separate argument after these.
            WithShortcut(path, shortcut =>
            {
                shortcut.TargetPath = executable;
                shortcut.Arguments = "--send --to " + mac.DeviceID;
                shortcut.WorkingDirectory = Path.GetDirectoryName(executable);
                shortcut.Description = DescriptionPrefix + mac.DeviceID;
                shortcut.IconLocation = executable + ",0";
                shortcut.Save();
                return true;
            });
        }
    }

    private static IEnumerable<string> ManagedShortcuts()
    {
        if (!Directory.Exists(SendToFolder)) return [];
        return Directory.EnumerateFiles(SendToFolder, "NooL Link*.lnk").Where(path =>
        {
            try
            {
                return WithShortcut(path, shortcut =>
                {
                    var description = (string)shortcut.Description;
                    var arguments = (string)shortcut.Arguments;
                    return description.StartsWith(DescriptionPrefix, StringComparison.Ordinal) ||
                        (description == LegacyDescription && arguments == "--send");
                });
            }
            catch (Exception error) when (error is COMException or IOException or UnauthorizedAccessException or
                Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { return false; }
        }).ToList();
    }

    private static string SafeLabel(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var label = new string(name.Select(c => invalid.Contains(c) || char.IsControl(c) ? '_' : c).ToArray()).Trim(' ', '.');
        if (label.Length > 60) label = label[..60].TrimEnd(' ', '.');
        return label.Length == 0 ? "Mac" : label;
    }

    private static bool WithShortcut(string path, Func<dynamic, bool> body)
    {
        object? shell = null;
        object? shortcut = null;
        try
        {
            var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Недоступны ярлыки Windows.");
            shell = Activator.CreateInstance(type) ?? throw new IOException("Недоступны ярлыки Windows.");
            shortcut = ((dynamic)shell).CreateShortcut(path);
            return body(shortcut!);
        }
        finally
        {
            if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null) Marshal.FinalReleaseComObject(shell);
        }
    }
}
