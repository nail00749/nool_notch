using System.Runtime.InteropServices;

namespace NooLLink;

internal static class ExplorerIntegration
{
    private const string ShortcutName = "NooL Link.lnk";
    private const string Description = "Отправить файлы на связанный Mac через NooL Link";
    private static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), ShortcutName);

    public static bool IsEnabled
    {
        get
        {
            if (!File.Exists(ShortcutPath)) return false;
            try { return IsManagedShortcut(); }
            catch (Exception error) when (error is COMException or IOException or UnauthorizedAccessException or
                Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { return false; }
        }
    }

    public static void SetEnabled(bool enabled)
    {
        if (File.Exists(ShortcutPath) && !IsManagedShortcut())
            throw new IOException("Ярлык с таким именем уже существует и не принадлежит NooL Link.");
        if (!enabled)
        {
            File.Delete(ShortcutPath);
            return;
        }
        var executable = Environment.ProcessPath ?? throw new IOException("Не найден исполняемый файл NooL Link.");
        // SendTo supplies every selected path as a separate argument. The shell
        // shortcut handles quoting; no command interpreter or registry-wide handler is involved.
        object? shell = null;
        object? shortcut = null;
        try
        {
            var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Недоступны ярлыки Windows.");
            shell = Activator.CreateInstance(type) ?? throw new IOException("Не удалось создать ярлык.");
            shortcut = ((dynamic)shell).CreateShortcut(ShortcutPath);
            ((dynamic)shortcut).TargetPath = executable;
            ((dynamic)shortcut).Arguments = "--send";
            ((dynamic)shortcut).WorkingDirectory = Path.GetDirectoryName(executable);
            ((dynamic)shortcut).Description = Description;
            ((dynamic)shortcut).IconLocation = executable + ",0";
            ((dynamic)shortcut).Save();
        }
        finally
        {
            if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null) Marshal.FinalReleaseComObject(shell);
        }
    }

    private static bool IsManagedShortcut()
    {
        object? shell = null;
        object? shortcut = null;
        try
        {
            var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new IOException("Недоступны ярлыки Windows.");
            shell = Activator.CreateInstance(type) ?? throw new IOException("Недоступны ярлыки Windows.");
            shortcut = ((dynamic)shell).CreateShortcut(ShortcutPath);
            return ((string)((dynamic)shortcut).Description) == Description &&
                ((string)((dynamic)shortcut).Arguments) == "--send";
        }
        finally
        {
            if (shortcut is not null) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null) Marshal.FinalReleaseComObject(shell);
        }
    }
}
