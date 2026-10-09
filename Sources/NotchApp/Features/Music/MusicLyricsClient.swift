import Foundation

struct MusicLyricsHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let retryAfter: String?
}

struct MusicLyricsClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> MusicLyricsHTTPResponse
    private let transport: Transport
    private let now: @Sendable () -> Date
    static let maximumResponseBytes = 1_048_576

    init(transport: @escaping Transport = MusicLyricsClient.send, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func lookup(_ track: MusicLyricsTrack) async throws -> MusicLyricsState {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        if let album = track.album { components.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if track.duration > 0 { components.queryItems?.append(URLQueryItem(name: "duration", value: String(track.duration))) }
        guard let url = components.url else { throw MusicLyricsFailure("Не удалось подготовить запрос текста.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("NooL App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport(request)
        try Task.checkCancellation()
        guard response.data.count <= Self.maximumResponseBytes else { throw MusicLyricsFailure("Ответ сервиса слишком большой.") }
        if response.statusCode == 404 { return .notFound }
        if response.statusCode == 429 {
            throw MusicLyricsFailure("Сервис временно ограничил запросы. Попробуйте позже.", retryAfter: retryDate(response.retryAfter))
        }
        guard response.statusCode == 200 else { throw MusicLyricsFailure("Сервис текстов недоступен (\(response.statusCode)).") }
        struct Payload: Decodable { let plainLyrics: String?; let syncedLyrics: String?; let instrumental: Bool? }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: response.data) }
        catch { throw MusicLyricsFailure("Не удалось прочитать ответ сервиса.") }
        if payload.instrumental == true { return .instrumental }
        let document = try MusicLyricsParser.document(plain: payload.plainLyrics, synced: payload.syncedLyrics)
        return document.plainText.isEmpty && document.timedLines.isEmpty ? .notFound : .loaded(document)
    }

    private func retryDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now().addingTimeInterval(min(seconds, 86_400 * 365)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }

    private static func send(_ request: URLRequest) async throws -> MusicLyricsHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration, delegate: MusicLyricsRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MusicLyricsFailure("Не удалось прочитать ответ сервиса.") }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw MusicLyricsFailure("Ответ сервиса слишком большой.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseBytes else { throw MusicLyricsFailure("Ответ сервиса слишком большой.") }
            data.append(byte)
        }
        return MusicLyricsHTTPResponse(data: data, statusCode: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}

// Metadata is sent only to the configured service, even if a server returns a redirect.
private final class MusicLyricsRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
