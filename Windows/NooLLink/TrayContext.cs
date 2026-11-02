using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NooLLink;

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem statusItem = new("Не подключено") { Enabled = false };
    private readonly ToolStripMenuItem pauseItem = new("Приостановить") { CheckOnClick = true };
    private readonly ToolStripMenuItem startupItem = new("Запускать при входе в Windows") { CheckOnClick = true };
    private readonly ToolStripMenuItem explorerItem = new("Пункт «Отправить → NooL Link» в Проводнике") { CheckOnClick = true };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private readonly ClipboardListener clipboardListener = new();
    private readonly Control dispatcher = new();
    private readonly InstanceBroker broker;
    private readonly Queue<string[]> pendingSends = new();
    private readonly Dictionary<string, TransferAcknowledgement> transferResults = new();
    private LinkCredentials? credentials;
    private LinkClient? client;
    private CancellationTokenSource session = new();
    private uint localSequence;
    private string? remoteID;
    private bool baseline = true;
    private bool ticking;
    private bool disposed;
    private PairingForm? pairingForm;
    private string[] lastReceived = [];

    public TrayContext(string[] initialFiles)
    {
        dispatcher.CreateControl();
        var menu = new ContextMenuStrip();
        menu.Items.Add(statusItem);
        menu.Items.Add("Подключить Mac…", null, (_, _) => ShowPairing());
        menu.Items.Add(pauseItem);
        menu.Items.Add("Открыть полученные файлы", null, (_, _) => OpenReceivedFiles());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startupItem);
        menu.Items.Add(explorerItem);
        menu.Items.Add("Забыть подключение", null, (_, _) => Forget());
        menu.Items.Add("Выход", null, (_, _) => ExitThread());
        tray = new NotifyIcon { Icon = SystemIcons.Application, Text = "NooL Link", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => ShowPairing();
        tray.BalloonTipClicked += (_, _) => RevealReceived();
        pauseItem.CheckedChanged += (_, _) =>
        {
            if (pauseItem.Checked)
            {
                // Cancel pending reads, sends, and clipboard writes as soon as
                // the user pauses. A fresh session is created when they resume.
                session.Cancel();
            }
            else
            {
                session.Dispose();
                session = new CancellationTokenSource();
            }
            ResetBaseline();
            SetStatus(pauseItem.Checked ? "Синхронизация приостановлена" : credentials is null ? "Не подключено" : "Подключение…");
        };
        startupItem.Checked = StartupEnabled();
        startupItem.Click += (_, _) => SetStartup(startupItem.Checked);
        explorerItem.Checked = ExplorerIntegration.IsEnabled;
        explorerItem.Click += (_, _) => SetExplorerIntegration(explorerItem.Checked);
        timer.Tick += async (_, _) => await TickAsync();
        try
        {
            var stored = CredentialStore.Load();
            if (stored is not null) SetCredentials(stored);
        }
        catch (Exception error) when (error is IOException or System.Security.Cryptography.CryptographicException or
            System.ComponentModel.Win32Exception or System.Text.Json.JsonException or ArgumentException or UnauthorizedAccessException)
        {
            SetStatus("Не удалось прочитать подключение");
        }
        timer.Start();
        broker = new InstanceBroker(QueueFilesFromBrokerAsync);
        if (initialFiles.Length > 0) QueueFiles(initialFiles);
        if (credentials is null) dispatcher.BeginInvoke((Action)ShowPairing);
    }

    private async Task TickAsync()
    {
        if (ticking || disposed || client is null || credentials is null || pauseItem.Checked) return;
        ticking = true;
        var active = session;
        var activeClient = client;
        var activeCredentials = credentials;
        try
        {
            if (pendingSends.TryDequeue(out var selectedPaths))
            {
                await SendSelectedFilesAsync(selectedPaths, activeClient, activeCredentials, active.Token);
                return;
            }
            await ReceiveTransferAsync(activeClient, activeCredentials, active.Token);
            if (active.IsCancellationRequested) return;
            var sequence = ClipboardBridge.GetClipboardSequenceNumber();
            if (!baseline && sequence != localSequence)
            {
                localSequence = sequence;
                SetStatus("Передача буфера…");
                var envelope = await ClipboardBridge.CaptureAsync(activeCredentials.LocalDeviceID, active.Token);
                // A copy that occurred during file loading belongs to the next tick.
                if (envelope is not null && !active.IsCancellationRequested &&
                    ClipboardBridge.GetClipboardSequenceNumber() == sequence)
                {
                    ClipboardBridge.Validate(envelope);
                    await activeClient.PublishAsync(envelope, active.Token);
                }
            }
            var beforePoll = ClipboardBridge.GetClipboardSequenceNumber();
            var incoming = await activeClient.PollAsync(remoteID, active.Token);
            if (active.IsCancellationRequested) return;
            if (baseline)
            {
                remoteID = incoming?.Id;
                localSequence = ClipboardBridge.GetClipboardSequenceNumber();
                baseline = false;
            }
            else if (incoming is not null && incoming.Id != remoteID)
            {
                ClipboardBridge.Validate(incoming);
                remoteID = incoming.Id;
                if (incoming.OriginDeviceID != activeCredentials.LocalDeviceID &&
                    ClipboardBridge.GetClipboardSequenceNumber() == beforePoll)
                {
                    SetStatus(incoming.Kind == "files" ? "Получение файлов…" : "Получение буфера…");
                    var paths = await ClipboardBridge.PrepareFilesAsync(incoming, active.Token);
                    if (!active.IsCancellationRequested && ClipboardBridge.GetClipboardSequenceNumber() == beforePoll)
                    {
                        ClipboardBridge.Apply(incoming, paths);
                        localSequence = ClipboardBridge.GetClipboardSequenceNumber();
                    }
                }
            }
            SetStatus($"Подключено: {activeCredentials.DeviceName}");
        }
        catch (OperationCanceledException) when (active.IsCancellationRequested) { }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or
            InvalidDataException or ExternalException or ArgumentException or System.Text.Json.JsonException or
            InvalidOperationException or UnauthorizedAccessException)
        {
            if (!active.IsCancellationRequested)
            {
                ResetBaseline();
                SetStatus(error is InvalidDataException ? error.Message : "Нет связи с Mac. Проверьте сеть и NooL.");
            }
        }
        finally { ticking = false; }
    }

    private Task<bool> QueueFilesFromBrokerAsync(string[] paths)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (disposed) return Task.FromResult(false);
        try { dispatcher.BeginInvoke((Action)(() => completion.TrySetResult(QueueFiles(paths)))); }
        catch (InvalidOperationException) { completion.TrySetResult(false); }
        return completion.Task;
    }

    private bool QueueFiles(string[] paths)
    {
        if (disposed || pauseItem.Checked || pendingSends.Count >= 64) return false;
        pendingSends.Enqueue(paths);
        SetStatus(credentials is null ? "Подключите Mac для отправки файлов" : "Файлы добавлены в отправку");
        if (credentials is null) ShowPairing();
        return true;
    }

    private async Task SendSelectedFilesAsync(string[] paths, LinkClient activeClient, LinkCredentials activeCredentials,
        CancellationToken cancellation)
    {
        try
        {
            SetStatus("Отправка файлов на Mac…");
            var envelope = await ClipboardBridge.CaptureFilesAsync(paths, activeCredentials.LocalDeviceID, cancellation);
            ClipboardBridge.Validate(envelope);
            await activeClient.SendFilesAsync(envelope, cancellation);
            if (!cancellation.IsCancellationRequested)
                Notify("Файлы отправлены", $"Сохранено на {activeCredentials.DeviceName}: {paths.Length} файл(ов).");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            if (!disposed) Notify("Отправка прервана", "Повторите отправку выбранных файлов после возобновления NooL Link.");
        }
        catch (Exception error) when (error is IOException or InvalidDataException or HttpRequestException or
            UnauthorizedAccessException or OperationCanceledException or ArgumentException or System.Security.SecurityException)
        {
            Notify("Не удалось отправить файлы", error is InvalidDataException ? error.Message :
                "Проверьте связь с Mac и включите передачу файлов в настройках NooL Link. Затем повторите отправку.");
        }
    }

    private async Task ReceiveTransferAsync(LinkClient activeClient, LinkCredentials activeCredentials,
        CancellationToken cancellation)
    {
        var envelope = await activeClient.PollTransfersAsync(cancellation);
        if (envelope is null) return;
        cancellation.ThrowIfCancellationRequested();
        if (envelope.OriginDeviceID != activeCredentials.DeviceID || envelope.Kind != "files")
            throw new InvalidDataException("Mac вернул некорректную передачу файлов.");
        if (!transferResults.TryGetValue(envelope.Id, out var result))
        {
            try
            {
                SetStatus("Получение файлов с Mac…");
                var saved = await FileTransferReceiver.ReceiveAsync(envelope, cancellation);
                result = new(envelope.Id, true);
                Notify(saved.Length == 1 ? "Получен файл" : $"Получено файлов: {saved.Length}",
                    (saved.Length == 1 ? Path.GetFileName(saved[0]) : "Сохранено в папку «Загрузки».") +
                    " Нажмите, чтобы показать в Проводнике.", saved);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException)
            {
                result = new(envelope.Id, false, "Не удалось сохранить файлы на Windows.");
                Notify("Не удалось получить файлы", "Проверьте место на диске и повторите отправку с Mac.");
            }
            if (transferResults.Count >= 128) transferResults.Remove(transferResults.Keys.First());
            transferResults[envelope.Id] = result;
        }
        cancellation.ThrowIfCancellationRequested();
        await activeClient.AcknowledgeTransferAsync(result, cancellation);
    }

    private void Notify(string title, string message, string[]? reveal = null)
    {
        if (disposed) return;
        // Only a "received" balloon opens Explorer; error balloons do nothing on click.
        lastReceived = reveal ?? [];
        SetStatus(title);
        tray.ShowBalloonTip(5000, title, message, ToolTipIcon.Info);
    }

    private void SetCredentials(LinkCredentials value)
    {
        session.Cancel();
        client?.Dispose();
        session.Dispose();
        session = new();
        credentials = value;
        transferResults.Clear();
        client = new(value);
        ResetBaseline();
        SetStatus($"Подключение: {value.DeviceName}");
    }

    private void ResetBaseline()
    {
        baseline = true;
        remoteID = null;
        localSequence = ClipboardBridge.GetClipboardSequenceNumber();
    }

    private void SetStatus(string value)
    {
        if (disposed) return;
        statusItem.Text = value;
        var title = "NooL Link — " + value;
        tray.Text = title.Length > 63 ? title[..63] : title;
        pairingForm?.SetStatus(value);
    }

    private void ShowPairing()
    {
        if (pairingForm is { IsDisposed: false }) { pairingForm.Activate(); return; }
        pairingForm = new PairingForm(async (invitation, cancellation) =>
        {
            var localID = credentials?.LocalDeviceID ?? Guid.NewGuid().ToString();
            using var connecting = new LinkClient(invitation);
            var response = await connecting.PairAsync(new(invitation.Token, Environment.MachineName, localID), cancellation);
            var value = new LinkCredentials(invitation.Host, invitation.Port, invitation.Fingerprint,
                response.Token, response.DeviceName, response.DeviceID, localID, invitation.Hostname);
            CredentialStore.Save(value);
            SetCredentials(value);
        });
        pairingForm.SetStatus(statusItem.Text ?? "Не подключено");
        pairingForm.Show();
    }

    private void Forget()
    {
        if (MessageBox.Show("Удалить подключение с этого компьютера? Для отзыва доступа удалите Windows также в настройках NooL на Mac.",
            "NooL Link", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { CredentialStore.Delete(); }
        catch (IOException) { MessageBox.Show("Не удалось удалить сохранённое подключение.", "NooL Link"); return; }
        session.Cancel();
        client?.Dispose();
        client = null;
        credentials = null;
        pendingSends.Clear();
        transferResults.Clear();
        ResetBaseline();
        SetStatus("Не подключено");
    }

    private static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("NooL Link") is string;
    }

    private void SetStartup(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (enabled) key.SetValue("NooL Link", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("NooL Link", throwOnMissingValue: false);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            startupItem.Checked = StartupEnabled();
            MessageBox.Show("Не удалось изменить автозапуск.", "NooL Link");
        }
    }

    private void SetExplorerIntegration(bool enabled)
    {
        try { ExplorerIntegration.SetEnabled(enabled); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or COMException or
            Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or System.Security.SecurityException)
        {
            explorerItem.Checked = ExplorerIntegration.IsEnabled;
            MessageBox.Show("Не удалось изменить пункт «Отправить → NooL Link» в Проводнике.", "NooL Link");
        }
    }

    private void RevealReceived()
    {
        var existing = lastReceived.FirstOrDefault(File.Exists);
        if (existing is null) { OpenReceivedFiles(); return; }
        try { Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select," + existing }, UseShellExecute = false }); }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException) { OpenReceivedFiles(); }
    }

    private static void OpenReceivedFiles()
    {
        try
        {
            var folder = FileTransferReceiver.DownloadsFolder;
            Directory.CreateDirectory(folder);
            Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { folder }, UseShellExecute = false });
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        { MessageBox.Show("Не удалось открыть папку полученных файлов.", "NooL Link"); }
    }

    protected override void ExitThreadCore()
    {
        disposed = true;
        broker.Dispose();
        timer.Stop();
        session.Cancel();
        client?.Dispose();
        pairingForm?.Close();
        tray.Visible = false;
        tray.Dispose();
        timer.Dispose();
        clipboardListener.Dispose();
        dispatcher.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class ClipboardListener : NativeWindow, IDisposable
{
    public ClipboardListener()
    {
        CreateHandle(new CreateParams { Caption = "NooL Link Clipboard", Parent = new IntPtr(-3) });
        if (!AddClipboardFormatListener(Handle))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() { RemoveClipboardFormatListener(Handle); DestroyHandle(); }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddClipboardFormatListener(IntPtr window);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveClipboardFormatListener(IntPtr window);
}
