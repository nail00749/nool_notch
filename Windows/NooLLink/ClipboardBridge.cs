using System.Buffers.Binary;
using System.Collections.Specialized;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace NooLLink;

internal static class ClipboardBridge
{
    public static readonly string ReceiveRoot = Path.Combine(CredentialStore.Root, "Received");

    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();

    public static async Task<ClipboardEnvelope> CaptureFilesAsync(string[] paths, string deviceID, CancellationToken cancellation)
    {
        var files = await Task.Run(() => ReadFiles(paths, cancellation), cancellation);
        return new(Guid.NewGuid().ToString(), deviceID, DateTimeOffset.UtcNow, "files", Files: files);
    }

    public static async Task<ClipboardEnvelope?> CaptureAsync(string deviceID, CancellationToken cancellation)
    {
        var data = Clipboard.GetDataObject();
        if (data is null || IsPrivate(data)) return null;
        var id = Guid.NewGuid().ToString();
        var createdAt = DateTimeOffset.UtcNow;
        if (data.GetDataPresent(DataFormats.FileDrop, false) && data.GetData(DataFormats.FileDrop, false) is string[] paths)
        {
            var files = await Task.Run(() => ReadFiles(paths, cancellation), cancellation);
            return new(id, deviceID, createdAt, "files", Files: files);
        }
        if (Clipboard.ContainsImage())
        {
            using var image = Clipboard.GetImage();
            if (image is null) return null;
            if ((long)image.Width * image.Height > 40_000_000) throw new InvalidDataException("Изображение слишком большое.");
            using var stream = new MemoryStream();
            image.Save(stream, ImageFormat.Png);
            if (stream.Length > LinkLimits.ImageBytes) throw new InvalidDataException("Изображение больше 10 МиБ.");
            return new(id, deviceID, createdAt, "image", ImageBase64: stream.ToArray());
        }
        if (data.GetDataPresent(DataFormats.UnicodeText, true) && data.GetData(DataFormats.UnicodeText, true) is string text)
        {
            // Invitations contain a pairing secret and must never leave the local clipboard.
            if (text.TrimStart().StartsWith("nool-link://", StringComparison.OrdinalIgnoreCase) || text.Length == 0) return null;
            if (Encoding.UTF8.GetByteCount(text) > LinkLimits.TextBytes) throw new InvalidDataException("Текст больше 1 МиБ.");
            return new(id, deviceID, createdAt, "text", Text: text);
        }
        return null;
    }

    /// Content identity across Macs: the same copy can arrive from two Macs
    /// (Universal Clipboard between them) with different envelope IDs.
    public static string Fingerprint(ClipboardEnvelope value)
    {
        using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(value.Kind + "\n"));
        if (value.Text is not null) hash.AppendData(Encoding.UTF8.GetBytes(value.Text));
        if (value.ImageBase64 is not null) hash.AppendData(value.ImageBase64);
        foreach (var file in value.Files ?? [])
        {
            hash.AppendData(Encoding.UTF8.GetBytes("\n" + file.Name + "\n"));
            hash.AppendData(file.DataBase64);
        }
        return Convert.ToHexString(hash.GetHashAndReset());
    }

    public static void Validate(ClipboardEnvelope value)
    {
        if (!Guid.TryParse(value.Id, out _) || !Guid.TryParse(value.OriginDeviceID, out _) ||
            // Matches the Mac's tolerance: home PCs often drift by a minute or more.
            value.CreatedAt > DateTimeOffset.UtcNow + LinkLimits.ClipboardLifetime ||
            DateTimeOffset.UtcNow - value.CreatedAt > LinkLimits.ClipboardLifetime)
            throw new InvalidDataException("Элемент буфера устарел или повреждён.");
        switch (value.Kind)
        {
            case "text" when value.Text is { Length: > 0 } text &&
                Encoding.UTF8.GetByteCount(text) <= LinkLimits.TextBytes && value.ImageBase64 is null && value.Files is null:
                if (text.TrimStart().StartsWith("nool-link://", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Приглашения не передаются через общий буфер.");
                break;
            case "image" when value.ImageBase64 is { Length: > 0 } image &&
                image.Length <= LinkLimits.ImageBytes && value.Text is null && value.Files is null:
                ValidatePng(image);
                break;
            case "files" when value.Files is { Length: > 0 and <= LinkLimits.FileCount } files &&
                value.Text is null && value.ImageBase64 is null:
                long total = 0;
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var file in files)
                {
                    if (file is null) throw new InvalidDataException("Получен некорректный список файлов.");
                    ValidateFileName(file.Name);
                    if (!names.Add(file.Name) || file.DataBase64 is null)
                        throw new InvalidDataException("Получен некорректный список файлов.");
                    total += file.DataBase64.Length;
                    if (total > LinkLimits.FileBytes) throw new InvalidDataException("Файлы больше 32 МиБ.");
                }
                break;
            default: throw new InvalidDataException("Неподдерживаемое содержимое буфера.");
        }
    }

    public static async Task<string[]?> PrepareFilesAsync(ClipboardEnvelope envelope, CancellationToken cancellation)
    {
        if (envelope.Kind != "files") return null;
        return await Task.Run(() =>
        {
            Directory.CreateDirectory(ReceiveRoot);
            var folder = Path.Combine(ReceiveRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                var paths = new List<string>();
                foreach (var file in envelope.Files!)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var path = Path.Combine(folder, file.Name);
                    using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                        output.Write(file.DataBase64);
                    paths.Add(path);
                }
                return paths.ToArray();
            }
            catch { Directory.Delete(folder, recursive: true); throw; }
        }, cancellation);
    }

    public static void Apply(ClipboardEnvelope envelope, string[]? filePaths)
    {
        var data = new DataObject();
        switch (envelope.Kind)
        {
            case "text": data.SetText(envelope.Text!, TextDataFormat.UnicodeText); break;
            case "image":
                using (var stream = new MemoryStream(envelope.ImageBase64!, writable: false))
                using (var image = Image.FromStream(stream))
                    data.SetImage(new Bitmap(image));
                break;
            case "files":
                var paths = new StringCollection();
                paths.AddRange(filePaths ?? throw new InvalidDataException("Файлы не загружены."));
                data.SetFileDropList(paths);
                // Copy effect only. A remote cut never deletes the source files.
                data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes(1)));
                break;
        }
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        Clipboard.SetDataObject(data, copy: true, retryTimes: 5, retryDelay: 40);
    }

    private static bool IsPrivate(IDataObject data)
    {
        if (new[] { "ExcludeClipboardContentFromMonitorProcessing", "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType" }
            .Any(format => data.GetDataPresent(format, false))) return true;
        if (!data.GetDataPresent("CanUploadToCloudClipboard", false)) return false;
        return data.GetData("CanUploadToCloudClipboard", false) switch
        {
            MemoryStream stream when stream.Length >= 4 => BitConverter.ToInt32(stream.ToArray(), 0) == 0,
            byte[] bytes when bytes.Length >= 4 => BitConverter.ToInt32(bytes, 0) == 0,
            int value => value == 0,
            _ => false
        };
    }

    private static LinkFile[] ReadFiles(string[] paths, CancellationToken cancellation)
    {
        if (paths.Length is < 1 or > LinkLimits.FileCount) throw new InvalidDataException("Можно передать от 1 до 64 файлов.");
        long total = 0;
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var files = new List<LinkFile>();
        foreach (var path in paths)
        {
            cancellation.ThrowIfCancellationRequested();
            var info = new FileInfo(path);
            if (!info.Exists || (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) != 0)
                throw new InvalidDataException("Пока поддерживаются только обычные файлы, без папок и ссылок.");
            ValidateFileName(info.Name);
            if (!names.Add(info.Name)) throw new InvalidDataException("В передаче есть файлы с одинаковыми именами.");
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (input.Length > LinkLimits.FileBytes - total) throw new InvalidDataException("Общий размер файлов больше 32 МиБ.");
            using var output = new MemoryStream();
            var buffer = new byte[64 * 1024];
            int count;
            while ((count = input.Read(buffer)) != 0)
            {
                cancellation.ThrowIfCancellationRequested();
                total += count;
                if (total > LinkLimits.FileBytes) throw new InvalidDataException("Общий размер файлов больше 32 МиБ.");
                output.Write(buffer, 0, count);
            }
            files.Add(new(info.Name, output.ToArray()));
        }
        return files.ToArray();
    }

    internal static void ValidateFileName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || name.Length > 240 || name is "." or ".." ||
            name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || name.Contains('/') || name.Contains('\\') ||
            name.EndsWith('.') || name.EndsWith(' ') || name.Any(char.IsControl))
            throw new InvalidDataException("Имя файла не поддерживается Windows.");
        var stem = name.Split('.')[0].ToUpperInvariant();
        if (stem is "CON" or "PRN" or "AUX" or "NUL" ||
            (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && stem[3] is >= '0' and <= '9'))
            throw new InvalidDataException("Имя файла зарезервировано Windows.");
    }

    private static void ValidatePng(byte[] bytes)
    {
        ReadOnlySpan<byte> signature = [137, 80, 78, 71, 13, 10, 26, 10];
        if (bytes.Length < 33 || !bytes.AsSpan(0, 8).SequenceEqual(signature) ||
            !bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8)) throw new InvalidDataException("Ожидалось изображение PNG.");
        var width = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4));
        var height = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4));
        if (width == 0 || height == 0 || (ulong)width * height > 40_000_000)
            throw new InvalidDataException("Изображение слишком большое.");
    }
}
