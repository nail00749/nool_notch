using Microsoft.Toolkit.Uwp.Notifications;
using System.Diagnostics;

namespace NooLLink;

/// Windows notifications through the OS toast API. The toolkit registers an
/// AppUserModelID and a COM activator per user, so a click works even after the
/// banner moved to the notification center or the tray app was restarted.
internal static class Toasts
{
    private static readonly string[] PreviewExtensions = [".png", ".jpg", ".jpeg", ".gif", ".bmp"];
    private const long MaximumPreviewBytes = 3 * 1024 * 1024;
    private static Control? dispatcher;

    public static bool WasLaunchedByToast()
    {
        try { return ToastNotificationManagerCompat.WasCurrentProcessToastActivated(); }
        catch (Exception error) when (IsToastFailure(error)) { return false; }
    }

    public static void Initialize(Control uiDispatcher)
    {
        dispatcher = uiDispatcher;
        try { ToastNotificationManagerCompat.OnActivated += OnActivated; }
        catch (Exception error) when (IsToastFailure(error)) { }
    }

    /// Returns false when the OS refused the toast, so the caller can fall back to a balloon.
    public static bool Show(string title, string message, string[]? received = null)
    {
        try
        {
            var builder = new ToastContentBuilder().AddText(title).AddText(message);
            var first = received?.FirstOrDefault(File.Exists);
            if (first is not null)
            {
                builder.AddArgument("action", "reveal").AddArgument("path", first);
                if (received!.Length == 1)
                {
                    var info = new FileInfo(first);
                    if (PreviewExtensions.Contains(info.Extension.ToLowerInvariant()) && info.Length <= MaximumPreviewBytes)
                        builder.AddInlineImage(new Uri(first));
                    builder.AddButton(new ToastButton().SetContent("Открыть")
                        .AddArgument("action", "open").AddArgument("path", first));
                }
                builder.AddButton(new ToastButton().SetContent("Показать в папке")
                    .AddArgument("action", "reveal").AddArgument("path", first));
            }
            builder.Show();
            return true;
        }
        catch (Exception error) when (IsToastFailure(error)) { return false; }
    }

    private static void OnActivated(ToastNotificationActivatedEventArgsCompat activation)
    {
        // Arrives on a COM thread; Explorer is started from the UI thread.
        var arguments = ToastArguments.Parse(activation.Argument);
        if (!arguments.TryGetValue("action", out var action)) return;
        arguments.TryGetValue("path", out var path);
        try { dispatcher?.BeginInvoke((Action)(() => Perform(action, path))); }
        catch (InvalidOperationException) { }
    }

    private static void Perform(string action, string? path)
    {
        // Only files that still exist in the user's Downloads folder are opened.
        var downloads = Path.GetFullPath(FileTransferReceiver.DownloadsFolder) + Path.DirectorySeparatorChar;
        var target = path is null ? null : Path.GetFullPath(path);
        var valid = target is not null && File.Exists(target) && target.StartsWith(downloads, StringComparison.OrdinalIgnoreCase);
        try
        {
            if (action == "open" && valid)
                Process.Start(new ProcessStartInfo(target!) { UseShellExecute = true });
            else if (valid)
                Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select," + target }, UseShellExecute = false });
            else
                Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { FileTransferReceiver.DownloadsFolder }, UseShellExecute = false });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException) { }
    }

    private static bool IsToastFailure(Exception error) =>
        error is System.Runtime.InteropServices.COMException or InvalidOperationException or UnauthorizedAccessException or
            IOException or ArgumentException or UriFormatException or PlatformNotSupportedException;
}
