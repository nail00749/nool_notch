import Foundation
import NotchCore

struct ClaudeQuotaProvider: QuotaProvider, QuotaProviderAuthenticating, Sendable {
    let id = "claude-code-subscription"
    let displayName = "Claude Code"
    let sourceURL = URL(string: "https://claude.ai/settings/usage")

    func loadSnapshot() async -> QuotaSnapshot {
        let now = Date()
        if let cached = await ClaudeUsageGate.shared.cachedSnapshot(at: now) { return cached }
        do {
            let credential = try await Task.detached {
                try ClaudeCodeCredentialStore.loadCredential()
            }.value
            // An expired token only earns 401/429 responses; Claude Code renews it on its next run.
            if let expiresAt = credential.expiresAt, expiresAt <= now {
                throw ClaudeQuotaError.tokenExpired
            }
            let snapshot = try await ClaudeUsageClient.loadSnapshot(
                accessToken: credential.accessToken,
                sourceURL: sourceURL
            )
            await ClaudeUsageGate.shared.recordSuccess(snapshot, at: now)
            return snapshot
        } catch ClaudeQuotaError.rateLimited(let retryAfter) {
            return await ClaudeUsageGate.shared.recordRateLimit(until: now.addingTimeInterval(retryAfter),
                                                                 sourceURL: sourceURL)
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

/// The usage endpoint rate-limits aggressively (one blocked hour after bursts), so NooL asks at most
/// once a minute, honours `Retry-After`, and keeps showing the last limits while it waits.
actor ClaudeUsageGate {
    static let shared = ClaudeUsageGate()
    static let minimumInterval: TimeInterval = 60
    static let defaultRetryAfter: TimeInterval = 15 * 60

    private var lastSnapshot: QuotaSnapshot?
    private var lastFetchAt: Date?
    private var blockedUntil: Date?

    /// A snapshot to return instead of calling the API, or nil when a request is allowed.
    func cachedSnapshot(at date: Date) -> QuotaSnapshot? {
        if let blockedUntil, date < blockedUntil { return waitingSnapshot(until: blockedUntil, sourceURL: lastSnapshot?.sourceURL) }
        if let lastFetchAt, let lastSnapshot, date.timeIntervalSince(lastFetchAt) < Self.minimumInterval {
            return lastSnapshot
        }
        return nil
    }

    func recordSuccess(_ snapshot: QuotaSnapshot, at date: Date) {
        lastSnapshot = snapshot
        lastFetchAt = date
        blockedUntil = nil
    }

    func recordRateLimit(until date: Date, sourceURL: URL?) -> QuotaSnapshot {
        blockedUntil = date
        return waitingSnapshot(until: date, sourceURL: sourceURL)
    }

    private func waitingSnapshot(until date: Date, sourceURL: URL?) -> QuotaSnapshot {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard let lastSnapshot else {
            return .unavailable(providerID: "claude-code-subscription", providerName: "Claude Code", sourceURL: sourceURL,
                                message: "Anthropic временно ограничил запросы лимитов. Повтор после \(time).")
        }
        return QuotaSnapshot(providerID: lastSnapshot.providerID, providerName: lastSnapshot.providerName,
                             windows: lastSnapshot.windows, connection: .stale, updatedAt: lastSnapshot.updatedAt,
                             sourceURL: lastSnapshot.sourceURL,
                             message: "Показаны последние лимиты: Anthropic ограничил запросы до \(time).")
    }
}

enum ClaudeQuotaError: Error {
    case authenticationRequired
    case authenticationRejected
    case tokenExpired
    case rateLimited(retryAfter: TimeInterval)
    case commandUnavailable
    case invalidResponse
    case serviceUnavailable

    func snapshot(sourceURL: URL?) -> QuotaSnapshot {
        switch self {
        case .tokenExpired:
            return .requiresAuthentication(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Вход Claude Code истёк. Запустите claude в терминале, и лимиты появятся снова."
            )
        case .rateLimited:
            return .unavailable(
                providerID: "claude-code-subscription",
                providerName: "Claude Code",
                sourceURL: sourceURL,
                message: "Anthropic временно ограничил запросы лимитов."
            )
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
        /// Milliseconds since 1970, as Claude Code writes it.
        let expiresAt: Double?
    }

    struct Credential: Sendable {
        let accessToken: String
        let expiresAt: Date?
    }

    static func loadCredential() throws -> Credential {
        if let keychainData = readKeychainItem(),
           let credential = decodeCredential(from: keychainData) {
            return credential
        }

        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credentialsURL),
           let credential = decodeCredential(from: data) {
            return credential
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

    private static func decodeCredential(from data: Data) -> Credential? {
        guard let oauth = (try? JSONDecoder().decode(CredentialsFile.self, from: data))?.claudeAiOauth,
              oauth.accessToken.isEmpty == false else {
            return nil
        }
        let expiresAt = oauth.expiresAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return Credential(accessToken: oauth.accessToken, expiresAt: expiresAt)
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
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw ClaudeQuotaError.rateLimited(retryAfter: min(max(retryAfter ?? ClaudeUsageGate.defaultRetryAfter, 60), 6 * 3600))
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
