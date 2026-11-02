using System.Runtime.InteropServices;

namespace NooLLink;

internal static class FileTransferReceiver
{
    /// Files sent from the Mac land in the user's Downloads folder, like AirDrop.
    /// A durable receipt makes a retried delivery (lost acknowledgement or a tray
    /// restart after saving) report success without saving the files twice.
    public static async Task<string[]> ReceiveAsync(ClipboardEnvelope envelope, CancellationToken cancellation)
    {
        ClipboardBridge.Validate(envelope);
        if (envelope.Kind != "files") throw new InvalidDataException("Ожидалась передача файлов.");
        var device = Guid.Parse(envelope.OriginDeviceID).ToString("N");
        var id = Guid.Parse(envelope.Id).ToString("N");
        var receiptRoot = Path.Combine(CredentialStore.Root, "TransferReceipts", device);
        var receipt = Path.Combine(receiptRoot, id);
        if (File.Exists(receipt))
            return (await File.ReadAllLinesAsync(receipt, cancellation)).Where(File.Exists).ToArray();
        Directory.CreateDirectory(receiptRoot);
        var downloads = DownloadsFolder;
        Directory.CreateDirectory(downloads);
        var staging = Path.Combine(CredentialStore.Root, "Incoming", Guid.NewGuid().ToString("N"));
        var saved = new List<string>();
        try
        {
            Directory.CreateDirectory(staging);
            foreach (var file in envelope.Files!)
            {
                cancellation.ThrowIfCancellationRequested();
                await using var output = new FileStream(Path.Combine(staging, file.Name), FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 65536, true);
                await output.WriteAsync(file.DataBase64, cancellation);
            }
            cancellation.ThrowIfCancellationRequested();
            // Commit only complete files, then finish the receipt even if the user
            // pauses now, so a later poll acknowledges without a second copy.
            foreach (var file in envelope.Files!)
                saved.Add(MoveUnique(Path.Combine(staging, file.Name), downloads, file.Name));
            await File.WriteAllLinesAsync(receipt, saved, CancellationToken.None);
            return saved.ToArray();
        }
        catch when (saved.Count < envelope.Files!.Length)
        {
            foreach (var path in saved) File.Delete(path);
            throw;
        }
        finally
        {
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
        }
    }

    /// Explorer-style "name (2).ext" naming; never overwrites an existing file.
    private static string MoveUnique(string source, string directory, string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var extension = Path.GetExtension(name);
        for (var index = 1; index < 1000; index++)
        {
            var target = Path.Combine(directory, index == 1 ? name : $"{stem} ({index}){extension}");
            if (File.Exists(target) || Directory.Exists(target)) continue;
            try { File.Move(source, target, overwrite: false); return target; }
            catch (IOException) when (File.Exists(target)) { }
        }
        throw new IOException("В папке «Загрузки» слишком много файлов с таким именем.");
    }

    public static string DownloadsFolder
    {
        get
        {
            // FOLDERID_Downloads follows the user's relocated Downloads folder.
            var folder = new Guid("374DE290-123F-4565-9164-39C4925E467B");
            if (SHGetKnownFolderPath(folder, 0, IntPtr.Zero, out var pointer) == 0)
            {
                try { if (Marshal.PtrToStringUni(pointer) is { Length: > 0 } path) return path; }
                finally { Marshal.FreeCoTaskMem(pointer); }
            }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags,
        IntPtr token, out IntPtr path);
}
