import Darwin
import Foundation
import NotchCore

struct CodexQuotaProvider: QuotaProvider, Sendable {
    let id = "chatgpt-subscription"
    let displayName = "ChatGPT подписка"
    let sourceURL = URL(string: "https://chatgpt.com/codex/settings/usage")

    func loadSnapshot() async -> QuotaSnapshot {
        await Task.detached(priority: .utility) {
            do {
                let exchange = try CodexAppServerTransport.fetch()
                let account = exchange.decode(CodexAccountResponse.self, id: 2)
                let rateLimits = exchange.decode(CodexRateLimitsResponse.self, id: 3)

                guard account?.account != nil else {
                    throw CodexQuotaError.authenticationRequired
                }
                guard let rateLimits else {
                    throw CodexQuotaError.responseNotRecognized
                }

                let windows = CodexQuotaSnapshotMapper.windows(
                    from: rateLimits,
                    planType: account?.account?.planType
                )
                guard !windows.isEmpty else {
                    throw CodexQuotaError.noLimits
                }

                return QuotaSnapshot(
                    providerID: "chatgpt-subscription",
                    providerName: "ChatGPT подписка",
                    windows: windows,
                    connection: .live,
                    updatedAt: Date(),
                    sourceURL: URL(string: "https://chatgpt.com/codex/settings/usage"),
                    message: "Локальный Codex app-server"
                )
            } catch let error as CodexQuotaError {
                return QuotaSnapshot(
                    providerID: "chatgpt-subscription",
                    providerName: "ChatGPT подписка",
                    windows: [],
                    connection: error.connection,
                    updatedAt: Date(),
                    sourceURL: URL(string: "https://chatgpt.com/codex/settings/usage"),
                    message: error.localizedDescription
                )
            } catch {
                return QuotaSnapshot.unavailable(
                    providerID: "chatgpt-subscription",
                    providerName: "ChatGPT подписка",
                    sourceURL: URL(string: "https://chatgpt.com/codex/settings/usage"),
                    message: Self.unavailableMessage(for: error)
                )
            }
        }.value
    }

    static func unavailableMessage(for error: Error) -> String {
        "Codex app-server: \(error.localizedDescription)"
    }
}

private struct CodexAccountResponse: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let type: String
        let planType: String?
    }

    let account: Account?
}

private struct CodexRateLimitsResponse: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Int?
    }

    struct Snapshot: Decodable, Sendable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }

    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
}

private enum CodexQuotaSnapshotMapper {
    static func windows(
        from response: CodexRateLimitsResponse,
        planType: String?
    ) -> [QuotaWindow] {
        let primary = response.rateLimits
        let primaryID = primary.limitId
        let normalizedPlanType = planType?.lowercased()
        let hidesFiveHourWindows = normalizedPlanType == "pro" || normalizedPlanType == "prolite"
        var buckets: [(key: String, snapshot: CodexRateLimitsResponse.Snapshot)] = [
            (primaryID ?? "codex", primary)
        ]

        for (key, snapshot) in (response.rateLimitsByLimitId ?? [:]).sorted(by: { $0.key < $1.key }) {
            let duplicatesPrimary = key == "codex"
                || (primaryID.map { $0 == key || $0 == snapshot.limitId } ?? false)
            if !duplicatesPrimary {
                buckets.append((key, snapshot))
            }
        }

        var seenWindows = Set<String>()
        return buckets.flatMap { bucket in
            let bucketName = bucket.snapshot.limitName
                ?? (bucket.key == "codex" ? nil : bucket.key)
            return [
                makeWindow(
                    id: "\(bucket.key)-primary",
                    window: bucket.snapshot.primary,
                    bucketName: bucketName,
                    hidesFiveHourWindows: hidesFiveHourWindows
                ),
                makeWindow(
                    id: "\(bucket.key)-secondary",
                    window: bucket.snapshot.secondary,
                    bucketName: bucketName,
                    hidesFiveHourWindows: hidesFiveHourWindows
                )
            ].compactMap { $0 }
        }.filter { window in
            seenWindows.insert(window.label).inserted
        }
    }

    private static func makeWindow(
        id: String,
        window: CodexRateLimitsResponse.Window?,
        bucketName: String?,
        hidesFiveHourWindows: Bool
    ) -> QuotaWindow? {
        guard let window else { return nil }
        if hidesFiveHourWindows,
           let minutes = window.windowDurationMins,
           approximately(minutes, 300) {
            return nil
        }
        let duration = durationLabel(window.windowDurationMins)
        let label = bucketName.map { "\($0) · \(duration)" } ?? duration
        let usedPercent = min(max(Double(window.usedPercent), 0), 100)

        return QuotaWindow(
            id: id,
            label: label,
            limit: 100,
            remaining: 100 - usedPercent,
            resetAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            unit: .percentage
        )
    }

    private static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "Лимит" }
        if approximately(minutes, 300) { return "5h" }
        if approximately(minutes, 1_440) { return "Дневное окно" }
        if approximately(minutes, 10_080) { return "7d" }
        if approximately(minutes, 43_200) { return "Месячное окно" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-дневное окно" }
        if minutes % 60 == 0 { return "\(minutes / 60)-часовое окно" }
        return "\(minutes) мин. окно"
    }

    private static func approximately(_ value: Int, _ expected: Int) -> Bool {
        let value = Double(value)
        let expected = Double(expected)
        return value >= expected * 0.95 && value <= expected * 1.05
    }
}

private enum CodexQuotaError: LocalizedError, Sendable {
    case executableNotFound
    case authenticationRequired
    case responseNotRecognized
    case noLimits
    case timeout
    case transport

    var connection: ProviderConnectionState {
        switch self {
        case .authenticationRequired:
            .requiresAuthentication
        default:
            .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Локальный Codex не найден"
        case .authenticationRequired:
            "Войдите в ChatGPT/Codex локально"
        case .responseNotRecognized:
            "Codex вернул неизвестный формат usage"
        case .noLimits:
            "Лимиты ChatGPT не найдены"
        case .timeout:
            "Codex app-server не ответил вовремя"
        case .transport:
            "Не удалось получить usage из Codex"
        }
    }
}

private struct CodexRPCExchange: Sendable {
    let results: [Int: Data]

    func decode<T: Decodable>(_ type: T.Type, id: Int) -> T? {
        guard let data = results[id] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct CodexAppServerTransport: Sendable {
    static func fetch() throws -> CodexRPCExchange {
        guard let executable = CodexPaths.executable() else {
            throw CodexQuotaError.executableNotFound
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let collector = CodexRPCCollector()

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { _ in
            collector.markProcessExited()
        }

        do {
            try process.run()
            try send(
                [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": [
                        "clientInfo": [
                            "name": "notch-usage-tracker",
                            "title": "Notch Usage Tracker",
                            "version": "0.1"
                        ],
                        "capabilities": ["experimentalApi": true]
                    ]
                ],
                to: input.fileHandleForWriting
            )
            try collector.wait(for: [1], timeout: 8)

            try send(
                ["jsonrpc": "2.0", "method": "initialized", "params": [:]],
                to: input.fileHandleForWriting
            )
            try sendRequest(
                id: 2,
                method: "account/read",
                params: ["refreshToken": false],
                to: input.fileHandleForWriting
            )
            try sendRequest(
                id: 3,
                method: "account/rateLimits/read",
                params: [:],
                to: input.fileHandleForWriting
            )
            try collector.wait(for: [2, 3], timeout: 12)
        } catch let error as CodexQuotaError {
            cleanup(process: process, input: input, output: output)
            throw error
        } catch {
            cleanup(process: process, input: input, output: output)
            throw CodexQuotaError.transport
        }

        cleanup(process: process, input: input, output: output)
        return collector.exchange
    }

    private static func sendRequest(
        id: Int,
        method: String,
        params: [String: Any],
        to handle: FileHandle
    ) throws {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: handle)
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func cleanup(process: Process, input: Pipe, output: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<15 where process.isRunning {
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private final class CodexRPCCollector: @unchecked Sendable {
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024
    private let condition = NSCondition()
    private var buffer = Data()
    private var results: [Int: Data] = [:]
    private var completedIDs = Set<Int>()
    private var processExited = false
    private var receivedBytes = 0

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !data.isEmpty else {
            processExited = true
            condition.broadcast()
            return
        }
        guard data.count <= Self.maximumBufferedBytes - receivedBytes else {
            processExited = true
            condition.broadcast()
            return
        }

        receivedBytes += data.count
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            consume(line)
        }
    }

    func markProcessExited() {
        condition.lock()
        processExited = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(for ids: Set<Int>, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !ids.isSubset(of: completedIDs), !processExited {
            if !condition.wait(until: deadline) { break }
        }

        guard ids.isSubset(of: completedIDs) else {
            if processExited {
                throw CodexQuotaError.transport
            }
            throw CodexQuotaError.timeout
        }
    }

    var exchange: CodexRPCExchange {
        condition.lock()
        defer { condition.unlock() }
        return CodexRPCExchange(results: results)
    }

    private func consume(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["method"] == nil,
              let id = (object["id"] as? NSNumber)?.intValue else {
            return
        }

        if let result = object["result"],
           JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result) {
            results[id] = data
        }
        completedIDs.insert(id)
        condition.broadcast()
    }
}

private enum CodexPaths {
    static func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}
