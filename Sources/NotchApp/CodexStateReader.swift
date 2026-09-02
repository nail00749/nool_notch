import Foundation
import SQLite3

enum CodexStateReaderError: Error, Equatable, Sendable {
    case databaseUnavailable
    case unsupportedSchema
    case queryFailed
}

struct CodexStateReader: Sendable {
    static let sourceID = "codex-desktop"

    let databaseURL: URL
    let maximumCandidateCount: Int
    let rolloutTailByteLimit: UInt64

    init(
        databaseURL: URL = CodexStateReader.defaultDatabaseURL(),
        maximumCandidateCount: Int = 50,
        rolloutTailByteLimit: UInt64 = 256 * 1_024
    ) {
        self.databaseURL = databaseURL
        self.maximumCandidateCount = maximumCandidateCount
        self.rolloutTailByteLimit = rolloutTailByteLimit
    }

    func loadSessions(now: Date = .now) throws -> [AISession] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw CodexStateReaderError.databaseUnavailable
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CodexStateReaderError.databaseUnavailable
        }
        defer { sqlite3_close(database) }

        let columns = tableColumns(database: database, table: "threads")
        guard columns.contains("id"),
              columns.contains("archived"),
              columns.contains("source") else {
            throw CodexStateReaderError.unsupportedSchema
        }

        guard let timestampExpression = timestampExpression(columns: columns) else {
            throw CodexStateReaderError.unsupportedSchema
        }

        let titleExpression = coalesceExpression(
            candidates: ["name", "title", "preview", "first_user_message"],
            columns: columns,
            fallback: "'Codex task'"
        )
        let cwdExpression = columns.contains("cwd") ? "cwd" : "NULL"
        let modelExpression = columns.contains("model") ? "model" : "NULL"
        let rolloutExpression = columns.contains("rollout_path") ? "rollout_path" : "NULL"

        let sql = """
            SELECT id, \(titleExpression), \(cwdExpression), \(modelExpression),
                   \(rolloutExpression), \(timestampExpression)
            FROM threads
            WHERE archived = 0
              AND (source = 'vscode' OR source = 'appServer')
            ORDER BY \(timestampExpression) DESC
            LIMIT ?;
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CodexStateReaderError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, maximumCandidateCount)))

        var sessions: [AISession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadID = columnString(statement, index: 0),
                  threadID.isEmpty == false else { continue }

            let rawTitle = columnString(statement, index: 1)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Codex task"
            let workspace = columnString(statement, index: 2)
            let model = columnString(statement, index: 3)
            let rolloutPath = columnString(statement, index: 4)
            let timestamp = sqlite3_column_double(statement, 5)
            let updatedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : now
            let status = rolloutPath.map { latestStatus(rolloutPath: $0) } ?? .unknown

            sessions.append(AISession(
                id: AISessionID(sourceID: Self.sourceID, sessionID: threadID),
                agentName: "Codex",
                title: title,
                workspacePath: workspace,
                modelName: model,
                status: status,
                lastActivity: updatedAt,
                isStale: false
            ))
        }

        guard sqlite3_errcode(database) == SQLITE_DONE || sqlite3_errcode(database) == SQLITE_OK else {
            throw CodexStateReaderError.queryFailed
        }
        return sessions
    }

    func latestStatus(rolloutPath: String) -> AISessionStatus {
        guard FileManager.default.fileExists(atPath: rolloutPath),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath)) else {
            return .unknown
        }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > rolloutTailByteLimit ? end - rolloutTailByteLimit : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd(), data.isEmpty == false else { return .unknown }

        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }

        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else { continue }
            switch eventType {
            case "task_started":
                return .running
            case "task_complete", "turn_aborted":
                return .completed
            case "turn_failed":
                return .failed
            default:
                continue
            }
        }
        return .unknown
    }

    static func defaultDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let root: URL
        if let configured = environment["CODEX_HOME"], configured.isEmpty == false {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        return root.appendingPathComponent("state_5.sqlite")
    }

    private func tableColumns(database: OpaquePointer, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnString(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private func timestampExpression(columns: Set<String>) -> String? {
        var expressions: [String] = []
        for millisecondColumn in ["recency_at_ms", "updated_at_ms", "created_at_ms"]
        where columns.contains(millisecondColumn) {
            expressions.append("NULLIF(\(millisecondColumn), 0) / 1000.0")
        }
        for secondColumn in ["recency_at", "updated_at", "created_at"]
        where columns.contains(secondColumn) {
            expressions.append("NULLIF(\(secondColumn), 0)")
        }
        guard expressions.isEmpty == false else { return nil }
        return "COALESCE(\(expressions.joined(separator: ", ")), 0)"
    }

    private func coalesceExpression(
        candidates: [String],
        columns: Set<String>,
        fallback: String
    ) -> String {
        let available = candidates.filter(columns.contains).map { "NULLIF(\($0), '')" }
        return "COALESCE(\((available + [fallback]).joined(separator: ", ")))"
    }

    private func columnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
}
