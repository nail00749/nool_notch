using System.Buffers.Binary;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text.Json;

namespace NooLLink;

/// Files chosen in Explorer; To names the destination Mac, or null for the only one.
internal sealed record SendRequest(string? To, string[] Paths);

/// Delivers explicit Explorer requests to the existing user's tray process.
internal sealed class InstanceBroker : IDisposable
{
    private const int MaximumRequestBytes = 512 * 1024;
    private static readonly string PipeName = "NooLLink-" + WindowsIdentity.GetCurrent().User!.Value + "-" +
        System.Diagnostics.Process.GetCurrentProcess().SessionId;
    private readonly CancellationTokenSource lifetime = new();

    public InstanceBroker(Func<SendRequest, Task<bool>> receive)
    {
        _ = ListenAsync(receive);
    }

    public static SendRequest? ParseSendArguments(string[] arguments)
    {
        if (arguments.Length == 0) return null;
        if (arguments[0] != "--send") throw new InvalidDataException("Неизвестная команда NooL Link.");
        string? to = null;
        var paths = arguments[1..];
        if (paths.Length >= 2 && paths[0] == "--to")
        {
            if (!Guid.TryParse(paths[1], out _)) throw new InvalidDataException("Неизвестный Mac для отправки.");
            to = paths[1];
            paths = paths[2..];
        }
        ValidatePaths(paths);
        return new(to, paths);
    }

    private static void ValidatePaths(string[] paths)
    {
        if (paths.Length is < 1 or > LinkLimits.FileCount ||
            paths.Any(path => string.IsNullOrWhiteSpace(path) || path.Length > 32767 || !Path.IsPathFullyQualified(path)))
            throw new InvalidDataException("Выберите от 1 до 64 файлов для отправки.");
    }

    public static async Task<bool> DeliverAsync(SendRequest request)
    {
        ValidatePaths(request.Paths);
        var payload = JsonSerializer.SerializeToUtf8Bytes(request);
        if (payload.Length > MaximumRequestBytes) throw new InvalidDataException("Слишком длинный список путей файлов.");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        await using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(timeout.Token);
        var length = new byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(length, payload.Length);
        await pipe.WriteAsync(length, timeout.Token);
        await pipe.WriteAsync(payload, timeout.Token);
        await pipe.FlushAsync(timeout.Token);
        var reply = new byte[1];
        await pipe.ReadExactlyAsync(reply, timeout.Token);
        return reply[0] == 1;
    }

    private async Task ListenAsync(Func<SendRequest, Task<bool>> receive)
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(lifetime.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                timeout.CancelAfter(TimeSpan.FromSeconds(8));
                var length = new byte[4];
                await pipe.ReadExactlyAsync(length, timeout.Token);
                var count = BinaryPrimitives.ReadInt32LittleEndian(length);
                if (count is < 1 or > MaximumRequestBytes) continue;
                var payload = new byte[count];
                await pipe.ReadExactlyAsync(payload, timeout.Token);
                var request = JsonSerializer.Deserialize<SendRequest>(payload)
                    ?? throw new JsonException("Пустой запрос отправки.");
                ValidatePaths(request.Paths ?? []);
                if (request.To is not null && !Guid.TryParse(request.To, out _)) continue;
                var accepted = await receive(request).WaitAsync(timeout.Token);
                await pipe.WriteAsync(new byte[] { accepted ? (byte)1 : (byte)0 }, timeout.Token);
                await pipe.FlushAsync(timeout.Token);
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { return; }
            catch (Exception error) when (error is IOException or OperationCanceledException or JsonException or ArgumentException)
            {
                // A malformed or vanished same-user client must not end the broker.
            }
        }
    }

    public void Dispose() { lifetime.Cancel(); }
}
