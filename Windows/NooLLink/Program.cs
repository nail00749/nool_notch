namespace NooLLink;

internal static class Program
{
    [STAThread]
    private static void Main(string[] arguments)
    {
        ApplicationConfiguration.Initialize();
        SendRequest? send;
        try { send = InstanceBroker.ParseSendArguments(arguments); }
        catch (InvalidDataException error) { MessageBox.Show(error.Message, "NooL Link"); return; }
        using var instance = new Mutex(true, "Local\\NooLLink", out var firstInstance);
        if (!firstInstance)
        {
            if (send is null) return;
            try
            {
                if (!InstanceBroker.DeliverAsync(send).GetAwaiter().GetResult())
                    MessageBox.Show("Не удалось добавить файлы в отправку. Откройте NooL Link и проверьте подключение или паузу.", "NooL Link");
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or UnauthorizedAccessException)
            { MessageBox.Show("Не удалось связаться с NooL Link. Повторите отправку после запуска приложения.", "NooL Link"); }
            return;
        }
        Application.Run(new TrayContext(send));
    }
}
