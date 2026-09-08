import Combine
import Foundation

enum CodexResetForecastConfidence: String, Equatable, Sendable {
    case low
    case medium
    case high
    case unknown
}

struct CodexResetForecast: Equatable, Sendable {
    let probability24Hours: Int
    let probability48Hours: Int
    let updatedAt: Date
    let lastResetAt: Date?
    let confidence: CodexResetForecastConfidence
    let confidenceNote: String?
}

protocol CodexResetForecastLoading: Sendable {
    func loadForecast() async throws -> CodexResetForecast
}

struct CodexResetForecastClient: CodexResetForecastLoading, @unchecked Sendable {
    static let sourceURL = URL(string: "https://codex-reset.com")!
    static let endpointURL = URL(string: "https://codex-reset.com/api/forecast")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: configuration)
    }

    func loadForecast() async throws -> CodexResetForecast {
        var request = URLRequest(
            url: Self.endpointURL,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 8
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CodexResetForecastError.invalidResponse
        }
        return try CodexResetForecastDecoder.decode(data)
    }
}

enum CodexResetForecastDecoder {
    private struct Payload: Decodable {
        struct Probabilities: Decodable {
            let rounded24Hours: Int
            let rounded48Hours: Int

            enum CodingKeys: String, CodingKey {
                case rounded24Hours = "rounded_24h"
                case rounded48Hours = "rounded_48h"
            }
        }

        let updatedAt: String
        let probabilities: Probabilities
        let confidence: String?
        let confidenceNote: String?
        let lastResetAt: String?

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case probabilities
            case confidence
            case confidenceNote = "confidence_note"
            case lastResetAt = "last_reset_at"
        }
    }

    static func decode(_ data: Data) throws -> CodexResetForecast {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CodexResetForecastError.invalidResponse
        }

        guard (0...100).contains(payload.probabilities.rounded24Hours),
              (0...100).contains(payload.probabilities.rounded48Hours),
              let updatedAt = parseISO8601(payload.updatedAt) else {
            throw CodexResetForecastError.invalidResponse
        }

        let lastResetAt: Date?
        if let value = payload.lastResetAt {
            guard let parsed = parseISO8601(value) else {
                throw CodexResetForecastError.invalidResponse
            }
            lastResetAt = parsed
        } else {
            lastResetAt = nil
        }

        return CodexResetForecast(
            probability24Hours: payload.probabilities.rounded24Hours,
            probability48Hours: payload.probabilities.rounded48Hours,
            updatedAt: updatedAt,
            lastResetAt: lastResetAt,
            confidence: CodexResetForecastConfidence(rawValue: payload.confidence ?? "") ?? .unknown,
            confidenceNote: payload.confidenceNote
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

enum CodexResetForecastVisibility {
    static func shouldLoad(
        isExpanded: Bool,
        selectedPanel: PanelID,
        selectedAISection: AISection,
        isShowingSettings: Bool,
        isUtilityPresented: Bool,
        isChatGPTProviderVisible: Bool
    ) -> Bool {
        isExpanded
            && selectedPanel == .ai
            && selectedAISection == .limits
            && isShowingSettings == false
            && isUtilityPresented == false
            && isChatGPTProviderVisible
    }
}

@MainActor
final class CodexResetForecastProvider: ObservableObject {
    private static let staleAfter: TimeInterval = 6 * 60 * 60

    @Published private(set) var forecast: CodexResetForecast?
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?

    private let loader: any CodexResetForecastLoading

    init(loader: any CodexResetForecastLoading = CodexResetForecastClient()) {
        self.loader = loader
    }

    func refresh() async {
        guard isLoading == false else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await loader.loadForecast()
            guard Task.isCancelled == false else { return }
            forecast = loaded
            isStale = Date().timeIntervalSince(loaded.updatedAt) > Self.staleAfter
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard Task.isCancelled == false else { return }
            isStale = forecast != nil
            errorMessage = "Прогноз временно недоступен"
        }
    }
}

private enum CodexResetForecastError: Error {
    case invalidResponse
}
