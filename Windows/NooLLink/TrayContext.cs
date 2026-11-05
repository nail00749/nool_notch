using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace NooLLink;

/// The connection to one paired Mac. Each Mac has its own polling cycle, so a
/// slow transfer from one Mac never stalls clipboard or AirDrop on another.
internal sealed class MacLink : IDisposable
{
    public MacLink(LinkCredentials credentials)
    {
        Credentials = credentials;
        Client = new(credentials);
    }

    public LinkCredentials Credentials { get; }
    public LinkClient Client { get; }
    public CancellationTokenSource Lifetime { get; } = new();
    public Queue<string[]> PendingSends { get; } = new();
    public Dictionary<string, TransferAcknowledgement> TransferResults { get; } = new();
    public ClipboardEnvelope? PendingPublish { get; set; }
    public string? RemoteID { get; set; }
    public bool Baseline { get; set; } = true;
    public bool Running { get; set; }
    public bool Connected { get; set; }
    public string Status { get; set; } = "подключение…";
    public string Name => Credentials.DeviceName;

    public void ResetBaseline()
    {
        Baseline = true;
        RemoteID = null;
        PendingPublish = null;
    }

    public void Dispose()
    {
        Lifetime.Cancel();
        Client.Dispose();
        Lifetime.Dispose();
    }
}

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly ContextMenuStrip menu = new();
    private readonly ToolStripMenuItem statusItem = new("Не подключено") { Enabled = false };
    private readonly ToolStripMenuItem pauseItem = new("Приостановить") { CheckOnClick = true };
    private readonly ToolStripMenuItem startupItem = new("Запускать при входе в Windows") { CheckOnClick = true };
    private readonly ToolStripMenuItem explorerItem = new("Пункт «Отправить → NooL Link» в Проводнике") { CheckOnClick = true };
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private readonly ClipboardListener clipboardListener = new();
    private readonly Control dispatcher = new();
    private readonly InstanceBroker broker;
    private readonly List<MacLink> links = [];
    private CancellationTokenSource session = new();
    private uint localSequence;
    private string? lastContentHash;
    private bool capturing;
    private bool disposed;
    private PairingForm? pairingForm;
    private string[] lastReceived = [];

    public TrayContext(SendRequest? initialSend)
    {
        dispatcher.CreateControl();
        Toasts.Initialize(dispatcher);
        menu.Opening += (_, _) => RebuildMenu();
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
            UpdateStatus();
        };
        startupItem.Checked = StartupEnabled();
        startupItem.Click += (_, _) => SetStartup(startupItem.Checked);
        explorerItem.Checked = ExplorerIntegration.IsEnabled;
        explorerItem.Click += (_, _) => SetExplorerIntegration(explorerItem.Checked);
        timer.Tick += async (_, _) => await TickAsync();
        try
        {
            foreach (var stored in CredentialStore.LoadAll()) links.Add(new MacLink(stored));
            SyncExplorer();
        }
        catch (Exception error) when (error is IOException or InvalidDataException or System.Security.Cryptography.CryptographicException or
            System.ComponentModel.Win32Exception or System.Text.Json.JsonException or ArgumentException or UnauthorizedAccessException)
        {
            SetStatus("Не удалось прочитать подключения");
        }
        ResetBaseline();
        UpdateStatus();
        timer.Start();
        broker = new InstanceBroker(QueueFilesFromBrokerAsync);
        if (initialSend is not null) dispatcher.BeginInvoke((Action)(() => QueueFiles(initialSend)));
        if (links.Count == 0) dispatcher.BeginInvoke((Action)ShowPairing);
    }

    private async Task TickAsync()
    {
        if (disposed || pauseItem.Checked || links.Count == 0) return;
        var token = session.Token;
        await CaptureLocalClipboardAsync(token);
        foreach (var link in links.ToArray())
            if (!link.Running) _ = RunCycleAsync(link, token);
    }

    /// Reads the Windows clipboard once and offers it to every connected Mac.
    private async Task CaptureLocalClipboardAsync(CancellationToken token)
    {
        var sequence = ClipboardBridge.GetClipboardSequenceNumber();
        if (capturing || sequence == localSequence) return;
        localSequence = sequence;
        capturing = true;
        try
        {
            var envelope = await ClipboardBridge.CaptureAsync(Guid.Empty.ToString(), token);
            // A copy that occurred during file loading belongs to the next tick.
            if (envelope is null || token.IsCancellationRequested ||
                ClipboardBridge.GetClipboardSequenceNumber() != sequence) return;
            ClipboardBridge.Validate(envelope);
            var hash = ClipboardBridge.Fingerprint(envelope);
            if (hash == lastContentHash) return;
            lastContentHash = hash;
            foreach (var link in links)
                if (!link.Baseline) link.PendingPublish = envelope with { OriginDeviceID = link.Credentials.LocalDeviceID };
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (error is IOException or InvalidDataException or ExternalException or
            ArgumentException or UnauthorizedAccessException or InvalidOperationException)
        {
            SetStatus(error is InvalidDataException ? error.Message : "Не удалось прочитать буфер обмена");
        }
        finally { capturing = false; }
    }

    private async Task RunCycleAsync(MacLink link, CancellationToken sessionToken)
    {
        link.Running = true;
        using var cycle = CancellationTokenSource.CreateLinkedTokenSource(sessionToken, link.Lifetime.Token);
        var token = cycle.Token;
        try
        {
            if (link.PendingSends.TryDequeue(out var selectedPaths))
            {
                await SendSelectedFilesAsync(link, selectedPaths, token);
                return;
            }
            await ReceiveTransferAsync(link, token);
            if (link.PendingPublish is { } publish)
            {
                link.PendingPublish = null;
                await link.Client.PublishAsync(publish, token);
            }
            var beforePoll = ClipboardBridge.GetClipboardSequenceNumber();
            var incoming = await link.Client.PollAsync(link.RemoteID, token);
            token.ThrowIfCancellationRequested();
            if (link.Baseline)
            {
                // The Mac's current item predates this connection; don't paste it.
                link.RemoteID = incoming?.Id;
                link.Baseline = false;
            }
            else if (incoming is not null && incoming.Id != link.RemoteID)
            {
                ClipboardBridge.Validate(incoming);
                link.RemoteID = incoming.Id;
                var hash = ClipboardBridge.Fingerprint(incoming);
                if (incoming.OriginDeviceID != link.Credentials.LocalDeviceID && hash != lastContentHash &&
                    ClipboardBridge.GetClipboardSequenceNumber() == beforePoll)
                {
                    var paths = await ClipboardBridge.PrepareFilesAsync(incoming, token);
                    if (!token.IsCancellationRequested && ClipboardBridge.GetClipboardSequenceNumber() == beforePoll)
                    {
                        ClipboardBridge.Apply(incoming, paths);
                        localSequence = ClipboardBridge.GetClipboardSequenceNumber();
                        lastContentHash = hash;
                    }
                }
            }
            link.Connected = true;
            link.Status = "подключён";
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or
            InvalidDataException or ExternalException or ArgumentException or System.Text.Json.JsonException or
            InvalidOperationException or UnauthorizedAccessException or ObjectDisposedException)
        {
            if (!token.IsCancellationRequested)
            {
                link.ResetBaseline();
                link.Connected = false;
                link.Status = error is InvalidDataException or HttpRequestException { StatusCode: System.Net.HttpStatusCode.Unauthorized }
                    ? error.Message : "нет связи";
            }
        }
        finally
        {
            link.Running = false;
            if (!disposed) UpdateStatus();
        }
    }

    private Task<bool> QueueFilesFromBrokerAsync(SendRequest request)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (disposed) return Task.FromResult(false);
        try { dispatcher.BeginInvoke((Action)(() => completion.TrySetResult(QueueFiles(request)))); }
        catch (InvalidOperationException) { completion.TrySetResult(false); }
        return completion.Task;
    }

    private bool QueueFiles(SendRequest request)
    {
        if (disposed || pauseItem.Checked) return false;
        if (links.Count == 0)
        {
            Notify("Нет подключённых Mac", "Подключите Mac и повторите отправку.");
            ShowPairing();
            return false;
        }
        var link = request.To is null
            ? links.Count == 1 ? links[0] : ChooseMac()
            : links.FirstOrDefault(item => item.Credentials.DeviceID == request.To);
        if (link is null || link.PendingSends.Count >= 64) return false;
        link.PendingSends.Enqueue(request.Paths);
        SetStatus($"Файлы добавлены в отправку на {link.Name}");
        return true;
    }

    /// Fallback for a plain `--send` with several Macs paired.
    private MacLink? ChooseMac()
    {
        using var form = new Form
        {
            Text = "NooL Link", StartPosition = FormStartPosition.CenterScreen, AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink, FormBorderStyle = FormBorderStyle.FixedDialog,
            MaximizeBox = false, MinimizeBox = false, TopMost = true
        };
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(16) };
        layout.Controls.Add(new Label { Text = "На какой Mac отправить файлы?", AutoSize = true, Margin = new(0, 0, 0, 8) });
        MacLink? chosen = null;
        foreach (var link in links)
        {
            var button = new Button { Text = link.Name, AutoSize = true, MinimumSize = new Size(260, 0) };
            button.Click += (_, _) => { chosen = link; form.DialogResult = DialogResult.OK; };
            layout.Controls.Add(button);
        }
        form.Controls.Add(layout);
        return form.ShowDialog() == DialogResult.OK ? chosen : null;
    }

    private async Task SendSelectedFilesAsync(MacLink link, string[] paths, CancellationToken cancellation)
    {
        try
        {
            SetStatus($"Отправка файлов на {link.Name}…");
            var envelope = await ClipboardBridge.CaptureFilesAsync(paths, link.Credentials.LocalDeviceID, cancellation);
            ClipboardBridge.Validate(envelope);
            await link.Client.SendFilesAsync(envelope, cancellation);
            if (!cancellation.IsCancellationRequested)
                Notify("Файлы отправлены", $"Сохранено на {link.Name}: {paths.Length} файл(ов).");
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            if (!disposed) Notify("Отправка прервана", "Повторите отправку выбранных файлов после возобновления NooL Link.");
        }
        catch (Exception error) when (error is IOException or InvalidDataException or HttpRequestException or
            UnauthorizedAccessException or OperationCanceledException or ArgumentException or System.Security.SecurityException)
        {
            Notify("Не удалось отправить файлы", error is InvalidDataException ? error.Message :
                $"Проверьте связь с {link.Name} и включите передачу файлов в настройках NooL Link. Затем повторите отправку.");
        }
    }

    private async Task ReceiveTransferAsync(MacLink link, CancellationToken cancellation)
    {
        var envelope = await link.Client.PollTransfersAsync(cancellation);
        if (envelope is null) return;
        cancellation.ThrowIfCancellationRequested();
        if (envelope.OriginDeviceID != link.Credentials.DeviceID || envelope.Kind != "files")
            throw new InvalidDataException("Mac вернул некорректную передачу файлов.");
        if (!link.TransferResults.TryGetValue(envelope.Id, out var result))
        {
            try
            {
                SetStatus($"Получение файлов с {link.Name}…");
                var saved = await FileTransferReceiver.ReceiveAsync(envelope, cancellation);
                result = new(envelope.Id, true);
                Notify(saved.Length == 1 ? $"Файл с {link.Name}" : $"Файлов с {link.Name}: {saved.Length}",
                    saved.Length == 1 ? Path.GetFileName(saved[0]) : "Сохранено в папку «Загрузки».", saved);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException)
            {
                result = new(envelope.Id, false, "Не удалось сохранить файлы на Windows.");
                Notify("Не удалось получить файлы", $"Проверьте место на диске и повторите отправку с {link.Name}.");
            }
            if (link.TransferResults.Count >= 128) link.TransferResults.Remove(link.TransferResults.Keys.First());
            link.TransferResults[envelope.Id] = result;
        }
        cancellation.ThrowIfCancellationRequested();
        await link.Client.AcknowledgeTransferAsync(result, cancellation);
    }

    private void Notify(string title, string message, string[]? reveal = null)
    {
        if (disposed) return;
        SetStatus(title);
        if (Toasts.Show(title, message, reveal)) return;
        // Fallback when notifications are disabled for the app or unavailable:
        // only a "received" balloon opens Explorer; error balloons do nothing on click.
        lastReceived = reveal ?? [];
        tray.ShowBalloonTip(5000, title, message, ToolTipIcon.Info);
    }

    private void AddOrReplace(LinkCredentials value)
    {
        var existing = links.FindIndex(item => item.Credentials.DeviceID == value.DeviceID);
        var link = new MacLink(value);
        localSequence = ClipboardBridge.GetClipboardSequenceNumber();
        if (existing >= 0) { links[existing].Dispose(); links[existing] = link; }
        else links.Add(link);
        SyncExplorer();
        UpdateStatus();
    }

    private void ResetBaseline()
    {
        foreach (var link in links) link.ResetBaseline();
        localSequence = ClipboardBridge.GetClipboardSequenceNumber();
    }

    private void UpdateStatus()
    {
        if (pauseItem.Checked) { SetStatus("Синхронизация приостановлена"); return; }
        if (links.Count == 0) { SetStatus("Не подключено"); return; }
        var connected = links.Where(link => link.Connected).Select(link => link.Name).ToArray();
        SetStatus(connected.Length == links.Count ? "Подключено: " + string.Join(", ", connected)
            : connected.Length == 0 ? "Нет связи с Mac. Проверьте сеть и NooL."
            : $"Подключено {connected.Length} из {links.Count}: " + string.Join(", ", connected));
    }

    private void SetStatus(string value)
    {
        if (disposed) return;
        statusItem.Text = value;
        var title = "NooL Link — " + value;
        tray.Text = title.Length > 63 ? title[..63] : title;
        pairingForm?.SetStatus(value);
    }

    private void RebuildMenu()
    {
        menu.Items.Clear();
        menu.Items.Add(statusItem);
        foreach (var link in links)
        {
            var item = new ToolStripMenuItem($"{link.Name} — {link.Status}");
            var target = link;
            item.DropDownItems.Add("Отвязать этот Mac…", null, (_, _) => Forget(target));
            menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(links.Count == 0 ? "Подключить Mac…" : "Подключить ещё один Mac…", null, (_, _) => ShowPairing());
        menu.Items.Add(pauseItem);
        menu.Items.Add("Открыть полученные файлы", null, (_, _) => OpenReceivedFiles());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startupItem);
        menu.Items.Add(explorerItem);
        menu.Items.Add("Выход", null, (_, _) => ExitThread());
    }

    private void ShowPairing()
    {
        if (pairingForm is { IsDisposed: false }) { pairingForm.Activate(); return; }
        pairingForm = new PairingForm(async (invitation, cancellation) =>
        {
            // One stable identity for this PC across every paired Mac.
            var localID = links.FirstOrDefault()?.Credentials.LocalDeviceID ?? Guid.NewGuid().ToString();
            using var connecting = new LinkClient(invitation);
            var response = await connecting.PairAsync(new(invitation.Token, Environment.MachineName, localID), cancellation);
            var value = new LinkCredentials(invitation.Host, invitation.Port, invitation.Fingerprint,
                response.Token, response.DeviceName, response.DeviceID, localID, invitation.Hostname);
            CredentialStore.Upsert(value);
            AddOrReplace(value);
        });
        pairingForm.SetStatus(statusItem.Text ?? "Не подключено");
        pairingForm.Show();
    }

    private void Forget(MacLink link)
    {
        if (MessageBox.Show($"Отвязать {link.Name} от этого компьютера? Для отзыва доступа удалите Windows также в настройках NooL на этом Mac.",
            "NooL Link", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { CredentialStore.Remove(link.Credentials.DeviceID); }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or
            System.Security.Cryptography.CryptographicException or System.ComponentModel.Win32Exception or System.Text.Json.JsonException)
        { MessageBox.Show("Не удалось удалить сохранённое подключение.", "NooL Link"); return; }
        links.Remove(link);
        link.Dispose();
        SyncExplorer();
        UpdateStatus();
    }

    private void SyncExplorer()
    {
        try { ExplorerIntegration.Sync(links.Select(link => link.Credentials).ToList()); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or COMException or
            Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or System.Security.SecurityException) { }
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
        try { ExplorerIntegration.SetEnabled(enabled, links.Select(link => link.Credentials).ToList()); }
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
        foreach (var link in links) link.Dispose();
        pairingForm?.Close();
        tray.Visible = false;
        tray.Dispose();
        timer.Dispose();
        clipboardListener.Dispose();
        dispatcher.Dispose();
        menu.Dispose();
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
