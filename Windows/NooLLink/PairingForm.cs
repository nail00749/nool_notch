namespace NooLLink;

internal sealed class PairingForm : Form
{
    private readonly TextBox invitation = new() { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
    private readonly Button connect = new() { Text = "Подключить", AutoSize = true };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(500, 0) };
    private readonly CancellationTokenSource cancellation = new();

    public PairingForm(Func<PairInvitation, CancellationToken, Task> pair)
    {
        Text = "NooL Link";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 330);
        MinimumSize = new Size(500, 340);
        MaximizeBox = false;
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24), ColumnCount = 1, RowCount = 6 };
        layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        layout.Controls.Add(new Label { Text = "Общий буфер с Mac", Font = new Font("Segoe UI", 17, FontStyle.Bold), AutoSize = true, Margin = new(0, 0, 0, 16) });
        layout.Controls.Add(new Label { Text = "На Mac откройте NooL → Настройки → NooL Link и создайте приглашение. Перенесите его сюда. Оба компьютера должны быть в одной локальной сети.", AutoSize = true, MaximumSize = new Size(500, 0), Margin = new(0, 0, 0, 14) });
        layout.Controls.Add(invitation);
        layout.Controls.Add(connect);
        layout.Controls.Add(status);
        layout.Controls.Add(new Label { Text = "Текст до 1 МиБ, PNG до 10 МиБ, до 64 файлов общим размером 32 МиБ. Папки и ссылки пока не поддерживаются. Полученные файлы хранятся локально до ручного удаления; открыть папку можно из меню в трее.", AutoSize = true, MaximumSize = new Size(500, 0), ForeColor = SystemColors.GrayText, Margin = new(0, 14, 0, 0) });
        Controls.Add(layout);
        AcceptButton = connect;
        connect.Click += async (_, _) =>
        {
            try
            {
                var parsed = PairInvitation.Parse(invitation.Text);
                if (MessageBox.Show(this, $"Разрешить общий буфер и приём файлов с Mac по адресу {parsed.Host}:{parsed.Port}?\n\nИспользуйте только приглашение, полученное из вашего NooL.",
                    "Подключение устройства", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
                connect.Enabled = false;
                invitation.Enabled = false;
                SetStatus("Сопряжение…");
                await pair(parsed, cancellation.Token);
                invitation.Clear();
                SetStatus("Устройство подключено. Приложение продолжит работу в трее.");
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            catch (Exception error) when (error is IOException or InvalidDataException or HttpRequestException or TaskCanceledException or
                ArgumentException or System.Text.Json.JsonException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
            {
                if (!IsDisposed) SetStatus(error is InvalidDataException ? error.Message : "Не удалось подключиться. Создайте новое приглашение и проверьте локальную сеть.");
            }
            finally
            {
                if (!IsDisposed) { connect.Enabled = true; invitation.Enabled = true; }
            }
        };
        FormClosed += (_, _) => { invitation.Clear(); cancellation.Cancel(); };
    }

    public void SetStatus(string value) { if (!IsDisposed) status.Text = value; }
}
