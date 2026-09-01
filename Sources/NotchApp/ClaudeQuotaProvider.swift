import Foundation
import NotchCore

struct ClaudeQuotaProvider: QuotaProvider, QuotaProviderAuthenticating, Sendable {
    let id = "claude-code-subscription"
    let displayName = "Claude Code"
    let sourceURL = URL(string: "https://claude.ai/settings/usage")

    func loadSnapshot() async -> QuotaSnapshot {
        do {
            let accessToken = try await Task.detached {
                try ClaudeCodeCredentialStore.loadAccessToken()
            }.value
            return try await ClaudeUsageClient.loadSnapshot(
                accessToken: accessToken,
                sourceURL: sourceURL
            )
        } catch let error as ClaudeQuotaError {
            return error.snapshot(sourceURL: sourceURL)
        } catch {
            return .unavailable(
                providerID: id,
                providerName: displayName,
                sourceURL: sourceURL,
                message: "Не удалось загрузить лимиты Claude Code."
            )
        }
    }

    @MainActor
    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void) {
        ClaudeCodeAuthenticationSession.shared.begin(onUpdate: onUpdate)
    }
}

private enum ClaudeQuotaError: Error {
    case authenticationRequired
    case authenticationRejected
    case commandUnavailable
    case invalidResponse
    case serviceUnavailable

    func snapshot(sourceURL: URL?) -> QuotaSnapshot {
        switch self {
        case .authenticationRequired, .authenticationRejected:
            return .requiresAuthentication(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Войдите в Claude Code, чтобы загрузить лимиты подписки."
            )
        case .commandUnavailable:
            return .unavailable(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Команда claude не найдена."
            )
        case .invalidResponse:
            return .unavailable(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Claude Code вернул неизвестный формат usage."
            )
        case .serviceUnavailable:
            return .unavailable(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Сервис лимитов Claude Code временно недоступен."
            )
        }
    }
}

private enum ClaudeCodeCredentialStore {
    private struct CredentialsFile: Decodable {
        let claudeAiOauth: OAuthCredential?
    }

    private struct OAuthCredential: Decodable {
        let accessToken: String
    }

    static func loadAccessToken() throws -> String {
        if let keychainData = readKeychainItem(),
           let token = decodeAccessToken(from: keychainData) {
            return token
        }

        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credentialsURL),
           let token = decodeAccessToken(from: data) {
            return token
        }

        throw ClaudeQuotaError.authenticationRequired
    }

    private static func readKeychainItem() -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Claude Code-credentials",
            "-w"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard data.count <= 1_000_000 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func decodeAccessToken(from data: Data) -> String? {
        guard let credentials = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let token = credentials.claudeAiOauth?.accessToken,
              token.isEmpty == false else {
            return nil
        }
        return token
    }
}

private enum ClaudeUsageClient {
    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    static func loadSnapshot(accessToken: String, sourceURL: URL?) async throws -> QuotaSnapshot {
        guard let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeQuotaError.invalidResponse
        }

        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeQuotaError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw ClaudeQuotaError.authenticationRejected
        default:
            throw ClaudeQuotaError.serviceUnavailable
        }

        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw ClaudeQuotaError.invalidResponse
        }

        let windows = [
            makeWindow(label: "5h", usage: usage.fiveHour),
            makeWindow(label: "7d", usage: usage.sevenDay),
            makeWindow(label: "Opus · 7d", usage: usage.sevenDayOpus),
            makeWindow(label: "Sonnet · 7d", usage: usage.sevenDaySonnet)
        ].compactMap { $0 }

        guard windows.isEmpty == false else {
            throw ClaudeQuotaError.invalidResponse
        }

        return QuotaSnapshot(
            providerID: "claude-code-subscription",
            providerName: "Claude Code",
            windows: windows,
            connection: .live,
            updatedAt: .now,
            sourceURL: sourceURL,
            message: "Лимиты подписки Claude Code"
        )
    }

    private static func makeWindow(label: String, usage: UsageWindow?) -> QuotaWindow? {
        guard let usage, let utilization = usage.utilization else { return nil }
        let used = min(max(utilization, 0), 100)
        return QuotaWindow(
            id: "claude-code-\(label)",
            label: label,
            limit: 100,
            remaining: 100 - used,
            resetAt: usage.resetsAt.flatMap(parseDate),
            unit: .percentage
        )
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawValue) ?? ISO8601DateFormatter().date(from: rawValue)
    }
}

@MainActor
private final class ClaudeCodeAuthenticationSession {
    static let shared = ClaudeCodeAuthenticationSession()

    private var process: Process?
    private var onUpdate: (@MainActor () -> Void)?

    func begin(onUpdate: @escaping @MainActor () -> Void) {
        self.onUpdate = onUpdate
        guard process == nil else { return }
        guard let executableURL = Self.executableURL else {
            onUpdate()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["auth", "login", "--claudeai"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.onUpdate?()
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
            onUpdate()
        }
    }

    private static var executableURL: URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
