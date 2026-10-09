import Foundation

protocol NetworkHTTPSChecking: Sendable {
    func check() async -> NetworkProbeResult
}

struct SystemNetworkHTTPSChecker: NetworkHTTPSChecking {
    func check() async -> NetworkProbeResult {
        let target = "https://example.com · TLS + HTTP"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirectNetworkDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        request.httpShouldHandleCookies = false
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return NetworkProbeResult(kind: .https, target: target, outcome: .warning,
                                          detail: "Сервер не вернул ответ HTTP.")
            }
            guard (200..<300).contains(response.statusCode) else {
                return NetworkProbeResult(kind: .https, target: target, outcome: .warning,
                                          detail: "HTTPS ответил кодом \(response.statusCode); перенаправления не выполнялись.")
            }
            return NetworkProbeResult(kind: .https, target: target, outcome: .success,
                                      detail: "Защищённое соединение установлено. HTTP \(response.statusCode).")
        } catch {
            return NetworkProbeResult(kind: .https, target: target, outcome: .warning,
                                      detail: "Не удалось получить HTTPS-ответ за 5 секунд. Причина может быть в сети, DNS или сервере.")
        }
    }
}

private final class NoRedirectNetworkDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
