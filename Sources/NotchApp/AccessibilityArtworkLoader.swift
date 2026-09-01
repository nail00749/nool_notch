import AppKit
import Foundation

enum AccessibilityArtworkError: Error, Equatable {
    case insecureURL
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge
    case invalidImage
}

struct AccessibilityArtworkLoader {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 5 * 1_024 * 1_024
    static let timeout: TimeInterval = 3

    static func load(url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        return try await load(url: url) { request in
            try await session.data(for: request)
        }
    }

    static func load(url: URL, fetch: Fetch) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw AccessibilityArtworkError.insecureURL
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: timeout
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AccessibilityArtworkError.invalidResponse
        }
        guard httpResponse.mimeType?.lowercased().hasPrefix("image/") == true else {
            throw AccessibilityArtworkError.unsupportedContentType
        }
        if response.expectedContentLength > maximumResponseBytes
            || data.count > maximumResponseBytes {
            throw AccessibilityArtworkError.responseTooLarge
        }
        guard NSImage(data: data) != nil else {
            throw AccessibilityArtworkError.invalidImage
        }
        return data
    }
}
