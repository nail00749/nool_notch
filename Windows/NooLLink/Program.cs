namespace NooLLink;

internal static class Program
{
    [STAThread]
    private static void Main(string[] arguments)
    {
        ApplicationConfiguration.Initialize();
        string[] paths;
        try { paths = InstanceBroker.ParseSendArguments(arguments); }
        catch (InvalidDataException error) { MessageBox.Show(error.Message, "NooL Link"); return; }
        using var instance = new Mutex(true, "Local\\NooLLink", out var firstInstance);
        if (!firstInstance)
        {
            if (paths.Length == 0) return;
            try
            {
                if (!InstanceBroker.DeliverAsync(paths).GetAwaiter().GetResult())
                    MessageBox.Show("Не удалось добавить файлы в отправку. Откройте NooL Link и проверьте подключение или паузу.", "NooL Link");
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or UnauthorizedAccessException)
            { MessageBox.Show("Не удалось связаться с NooL Link. Повторите отправку после запуска приложения.", "NooL Link"); }
            return;
        }
        Application.Run(new TrayContext(paths));
    }
}
