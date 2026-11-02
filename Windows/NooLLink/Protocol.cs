using System.Net;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Security.Cryptography;
using System.Net.Sockets;
using System.Net.Security;

namespace NooLLink;

internal static class LinkLimits
{
    public const int TextBytes = 1024 * 1024;
    public const int ImageBytes = 10 * 1024 * 1024;
    public const int FileBytes = 32 * 1024 * 1024;
    public const int BodyBytes = 46 * 1024 * 1024;
    public const int FileCount = 64;
    public static readonly TimeSpan ClipboardLifetime = TimeSpan.FromMinutes(5);
}

internal sealed record PairRequest(string Token, string DeviceName, string DeviceID);
internal sealed record PairResponse(string Token, string DeviceName, string DeviceID);
internal sealed record LinkCredentials(string Host, int Port, string Fingerprint, string Token,
    string DeviceName, string DeviceID, string LocalDeviceID, string? Hostname = null);
internal sealed record LinkFile(string Name, byte[] DataBase64);
internal sealed record ClipboardEnvelope(string Id, string OriginDeviceID, DateTimeOffset CreatedAt,
    string Kind, string? Text = null, byte[]? ImageBase64 = null, LinkFile[]? Files = null);
internal sealed record TransferAcknowledgement(string Id, bool Success, string? Message = null);

internal sealed record PairInvitation(string Host, int Port, string Token, string Fingerprint, string? Hostname = null)
{
    public static PairInvitation Parse(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri) ||
            uri.Scheme != "nool-link" || uri.Host != "pair" || uri.AbsolutePath is not ("" or "/") ||
            !string.IsNullOrEmpty(uri.Fragment) || !string.IsNullOrEmpty(uri.UserInfo))
            throw new InvalidDataException("Вставьте приглашение из настроек NooL Link на Mac.");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = item.Split('=', 2);
            if (parts.Length != 2 || !values.TryAdd(Uri.UnescapeDataString(parts[0]), Uri.UnescapeDataString(parts[1])))
                throw new InvalidDataException("Приглашение повреждено.");
        }
        if (!values.TryGetValue("host", out var host) || !IsPrivateIPv4(host) ||
            !values.TryGetValue("port", out var rawPort) || !int.TryParse(rawPort, out var port) || port is < 1 or > 65535 ||
            !values.TryGetValue("token", out var token) || !IsToken(token) ||
            !values.TryGetValue("fingerprint", out var fingerprint) || fingerprint.Length != 64 ||
            !fingerprint.All(Uri.IsHexDigit))
            throw new InvalidDataException("Приглашение должно содержать локальный IPv4-адрес и ключ сопряжения.");
        values.TryGetValue("hostname", out var hostname);
        if (hostname is not null && !IsLocalHostname(hostname)) throw new InvalidDataException("Некорректное локальное имя Mac.");
        return new(host, port, token, fingerprint.ToLowerInvariant(), hostname);
    }

    public static bool IsPrivateIPv4(string host)
    {
        if (!IPAddress.TryParse(host, out var ip) || ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
            return false;
        var b = ip.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) ||
               (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
    }

    public static bool IsLocalHostname(string hostname)
    {
        if (!hostname.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) return false;
        var label = hostname[..^6];
        return label.Length is >= 1 and <= 63 && label[0] != '-' && label[^1] != '-' &&
            label.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
    }

    public static bool IsToken(string? token)
    {
        if (token is null || token.Length is < 43 or > 44) return false;
        try { return Convert.FromBase64String(token.Replace('-', '+').Replace('_', '/').PadRight(44, '=')).Length == 32; }
        catch (FormatException) { return false; }
    }
}

internal sealed class LinkClient : IDisposable
{
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };
    private readonly HttpClient http;
    private readonly string? token;

    public LinkClient(PairInvitation invitation, string? token = null)
    {
        this.token = token;
        var fingerprint = Convert.FromHexString(invitation.Fingerprint);
        var handler = new SocketsHttpHandler
        {
            UseProxy = false, AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(12),
            PooledConnectionLifetime = TimeSpan.FromMinutes(1),
            SslOptions = new SslClientAuthenticationOptions
            {
                RemoteCertificateValidationCallback = (_, certificate, _, _) => certificate is not null &&
                    CryptographicOperations.FixedTimeEquals(SHA256.HashData(certificate.GetRawCertData()), fingerprint)
            },
            ConnectCallback = async (_, cancellation) =>
            {
                var addresses = new List<IPAddress>();
                if (invitation.Hostname is not null && PairInvitation.IsLocalHostname(invitation.Hostname))
                {
                    using var dnsTimeout = RequestTimeout(cancellation, TimeSpan.FromSeconds(3));
                    try
                    {
                        var resolved = await Dns.GetHostAddressesAsync(invitation.Hostname, dnsTimeout.Token);
                        addresses.AddRange(resolved.Where(address => PairInvitation.IsPrivateIPv4(address.ToString())));
                    }
                    catch (Exception error) when (error is SocketException or OperationCanceledException && !cancellation.IsCancellationRequested) { }
                }
                addresses.Add(IPAddress.Parse(invitation.Host));
                foreach (var address in addresses.Distinct().Take(3))
                {
                    var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                    try
                    {
                        using var connectTimeout = RequestTimeout(cancellation, TimeSpan.FromSeconds(3));
                        await socket.ConnectAsync(address, invitation.Port, connectTimeout.Token);
                        return new NetworkStream(socket, ownsSocket: true);
                    }
                    catch (Exception error) when (error is SocketException or OperationCanceledException && !cancellation.IsCancellationRequested)
                    { socket.Dispose(); }
                    catch { socket.Dispose(); throw; }
                }
                throw new HttpRequestException("Mac недоступен в локальной сети.");
            }
        };
        http = new HttpClient(handler)
        {
            BaseAddress = new Uri($"https://{invitation.Host}:{invitation.Port}/"),
            Timeout = Timeout.InfiniteTimeSpan,
            MaxResponseContentBufferSize = LinkLimits.BodyBytes
        };
    }

    public LinkClient(LinkCredentials credentials) : this(
        new(credentials.Host, credentials.Port, "", credentials.Fingerprint, credentials.Hostname), credentials.Token) { }

    public async Task<PairResponse> PairAsync(PairRequest request, CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromSeconds(20));
        using var response = await SendAsync(HttpMethod.Post, "v1/pair", request, timeout.Token);
        var result = await ReadAsync<PairResponse>(response, timeout.Token);
        if (!PairInvitation.IsToken(result.Token) || !Guid.TryParse(result.DeviceID, out _) || string.IsNullOrWhiteSpace(result.DeviceName))
            throw new InvalidDataException("Mac вернул некорректный ответ сопряжения.");
        return result;
    }

    public async Task<ClipboardEnvelope?> PollAsync(string? after, CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromMinutes(3));
        using var response = await SendAsync(HttpMethod.Get,
            "v1/clipboard" + (after is null ? "" : "?after=" + Uri.EscapeDataString(after)), null, timeout.Token);
        return response.StatusCode == HttpStatusCode.NoContent ? null : await ReadAsync<ClipboardEnvelope>(response, timeout.Token);
    }

    public async Task PublishAsync(ClipboardEnvelope envelope, CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromMinutes(3));
        using var response = await SendAsync(HttpMethod.Post, "v1/clipboard", envelope, timeout.Token);
    }

    public async Task SendFilesAsync(ClipboardEnvelope envelope, CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromMinutes(3));
        using var response = await SendAsync(HttpMethod.Post, "v1/transfers", envelope, timeout.Token);
    }

    public async Task<ClipboardEnvelope?> PollTransfersAsync(CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromMinutes(3));
        try
        {
            using var response = await SendAsync(HttpMethod.Get, "v1/transfers", null, timeout.Token);
            return response.StatusCode == HttpStatusCode.NoContent ? null : await ReadAsync<ClipboardEnvelope>(response, timeout.Token);
        }
        catch (HttpRequestException error) when (error.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.BadRequest)
        {
            // Clipboard sync stays usable with the first Mac companion version.
            return null;
        }
    }

    public async Task AcknowledgeTransferAsync(TransferAcknowledgement acknowledgement, CancellationToken cancellation)
    {
        using var timeout = RequestTimeout(cancellation, TimeSpan.FromSeconds(20));
        using var response = await SendAsync(HttpMethod.Post, "v1/transfers/ack", acknowledgement, timeout.Token);
    }

    private static CancellationTokenSource RequestTimeout(CancellationToken cancellation, TimeSpan interval)
    {
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(interval);
        return timeout;
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, object? body, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(method, path);
        if (token is not null) request.Headers.Authorization = new("Bearer", token);
        if (body is not null)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(body, body.GetType(), Json);
            if (bytes.Length > LinkLimits.BodyBytes) throw new InvalidDataException("Превышен размер передачи.");
            request.Content = new ByteArrayContent(bytes);
            request.Content.Headers.ContentType = new("application/json");
        }
        var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode)
        {
            var status = response.StatusCode;
            response.Dispose();
            throw new HttpRequestException(status is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                ? "Доступ отозван. Создайте новое приглашение на Mac."
                : $"Mac отклонил запрос ({(int)status}).", null, status);
        }
        return response;
    }

    private static async Task<T> ReadAsync<T>(HttpResponseMessage response, CancellationToken cancellation)
    {
        if (response.Content.Headers.ContentLength > LinkLimits.BodyBytes)
            throw new InvalidDataException("Полученный объект слишком большой.");
        await using var stream = await response.Content.ReadAsStreamAsync(cancellation);
        using var data = new MemoryStream();
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellation);
            if (count == 0) break;
            if (data.Length + count > LinkLimits.BodyBytes) throw new InvalidDataException("Полученный объект слишком большой.");
            data.Write(buffer, 0, count);
        }
        return JsonSerializer.Deserialize<T>(data.GetBuffer().AsSpan(0, (int)data.Length), Json)
            ?? throw new InvalidDataException("Некорректный ответ Mac.");
    }

    public void Dispose() => http.Dispose();
}
