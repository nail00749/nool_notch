import Foundation
import CoreFoundation
import SQLite3

enum AIUsageReaderError: Error, Equatable, Sendable {
    case databaseUnavailable
    case unsupportedSchema
    case queryFailed
}

/// Reads only usage counters from local rollouts. It never persists conversation content.
struct CodexUsageReader: Sendable {
    let databaseURL: URL
    let maximumCandidateCount: Int
    let rolloutByteLimit: Int
    let totalByteLimit: Int
    let recordByteLimit: Int

    init(
        databaseURL: URL = CodexStateReader.defaultDatabaseURL(),
        maximumCandidateCount: Int = 200,
        rolloutByteLimit: Int = 8 * 1_024 * 1_024,
        totalByteLimit: Int = 64 * 1_024 * 1_024,
        recordByteLimit: Int = 1_024 * 1_024
    ) {
        self.databaseURL = databaseURL
        self.maximumCandidateCount = max(1, min(maximumCandidateCount, 200))
        self.rolloutByteLimit = max(1, rolloutByteLimit)
        self.totalByteLimit = max(1, totalByteLimit)
        self.recordByteLimit = max(1, recordByteLimit)
    }

    func load(now: Date = .now) throws -> AIUsageSnapshot {
        try Task.checkCancellation()
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw AIUsageReaderError.databaseUnavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 150)
        // LIMIT bounds results, not SQLite's scan/sort work before the first row.
        let queryDeadline = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        queryDeadline.initialize(to: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        sqlite3_progress_handler(database, 1_000, { context in
            guard let context else { return 1 }
            let deadline = context.assumingMemoryBound(to: UInt64.self).pointee
            return Task.isCancelled || DispatchTime.now().uptimeNanoseconds > deadline ? 1 : 0
        }, queryDeadline)
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            queryDeadline.deinitialize(count: 1)
            queryDeadline.deallocate()
        }
        let columns = try tableColumns(database)
        guard Set(["id", "rollout_path", "cwd", "model", "source"]).isSubset(of: columns) else {
            throw AIUsageReaderError.unsupportedSchema
        }
        let timestamp: String
        if columns.contains("updated_at_ms"), columns.contains("updated_at") {
            timestamp = "COALESCE(NULLIF(updated_at_ms, 0) / 1000.0, updated_at)"
        } else if columns.contains("updated_at_ms") {
            timestamp = "updated_at_ms / 1000.0"
        } else if columns.contains("updated_at") {
            timestamp = "updated_at"
        } else { throw AIUsageReaderError.unsupportedSchema }
        // Match the 30 local calendar-day buckets, including DST boundaries.
        let cutoff = Calendar.current.date(byAdding: .day, value: -29,
                                           to: Calendar.current.startOfDay(for: now))
            ?? now.addingTimeInterval(-31 * 86_400)
        let query = """
        SELECT id, rollout_path, cwd, model FROM threads
        WHERE source IN ('vscode', 'appServer', 'cli') AND \(timestamp) >= ?
        ORDER BY \(timestamp) DESC, id ASC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AIUsageReaderError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(maximumCandidateCount + 1))
        let root = databaseURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        var events: [AIUsageEvent] = []
        var partial = false
        var scanned = 0
        var skipped = 0
        var budget = totalByteLimit
        func step() -> Int32 {
            queryDeadline.pointee = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            return sqlite3_step(statement)
        }
        var result = step()
        while result == SQLITE_ROW {
            try Task.checkCancellation()
            if scanned + skipped == maximumCandidateCount {
                partial = true
                break
            }
            guard let id = string(statement, 0), !id.isEmpty,
                  let path = string(statement, 1), !path.isEmpty, budget > 0 else {
                skipped += 1; partial = true
                result = step(); continue
            }
            let project = string(statement, 2) ?? ""
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root + "/"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                skipped += 1; partial = true
                result = step(); continue
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let limit = min(rolloutByteLimit, budget)
                let count = Int(min(size, UInt64(limit)))
                let start = size - UInt64(count)
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: count) ?? Data()
                budget -= data.count
                scanned += 1
                if start > 0 || data.count != count { partial = true }
                let parsed = try parse(data, truncated: start > 0, sessionID: id,
                                       project: project, cutoff: cutoff, now: now)
                events.append(contentsOf: parsed.events)
                partial = partial || parsed.partial
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1; partial = true }
            result = step()
        }
        try Task.checkCancellation()
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw AIUsageReaderError.queryFailed }
        return AIUsageSnapshot(events: events.sorted { $0.date < $1.date }, loadedAt: now,
                               isPartial: partial, scannedSessionCount: scanned, skippedSessionCount: skipped)
    }

    private struct Counters: Equatable {
        let input: Int64
        let cached: Int64
        let output: Int64

        init?(_ object: Any?) {
            guard let object = object as? [String: Any],
                  let input = Self.integer(object["input_tokens"]),
                  let cached = Self.integer(object["cached_input_tokens"]),
                  let output = Self.integer(object["output_tokens"]),
                  cached <= input, input <= Int64.max - output else { return nil }
            self.input = input; self.cached = cached; self.output = output
        }

        private init(input: Int64, cached: Int64, output: Int64) {
            self.input = input; self.cached = cached; self.output = output
        }

        func increment(from old: Counters) -> Counters? {
            guard input >= old.input, cached >= old.cached, output >= old.output else { return nil }
            let delta = Counters(input: input - old.input, cached: cached - old.cached, output: output - old.output)
            return delta.cached <= delta.input ? delta : nil
        }

        static func integer(_ value: Any?) -> Int64? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let integer = Int64(number.stringValue), integer >= 0,
                  integer <= 1_000_000_000_000 else { return nil }
            return integer
        }
    }

    private func parse(_ data: Data, truncated: Bool, sessionID: String, project: String,
                       cutoff: Date, now: Date) throws -> (events: [AIUsageEvent], partial: Bool) {
        var model = "unknown"
        var currentProject = project
        var previous: Counters?
        var partial = false
        var events: [AIUsageEvent] = []
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let usageNeedle = Data("\"token_count\"".utf8)
        let contextNeedle = Data("\"turn_context\"".utf8)
        var offset = data.startIndex
        if truncated {
            guard let newline = data.firstIndex(of: 10) else { return ([], true) }
            offset = data.index(after: newline)
        }
        var lineNumber = 0
        while offset < data.endIndex {
            try Task.checkCancellation()
            let end = data[offset...].firstIndex(of: 10) ?? data.endIndex
            defer { offset = end < data.endIndex ? data.index(after: end) : end }
            lineNumber += 1
            guard end - offset <= recordByteLimit else { partial = true; continue }
            if end == offset { continue }
            // Do not decode ordinary conversation/tool records, even transiently.
            let range = offset..<end
            guard data.range(of: usageNeedle, in: range) != nil ||
                    data.range(of: contextNeedle, in: range) != nil else { continue }
            guard let record = try? JSONSerialization.jsonObject(with: data[offset..<end]) as? [String: Any],
                  let type = record["type"] as? String else { partial = true; continue }
            guard type == "turn_context" || type == "event_msg" else { continue }
            guard let payload = record["payload"] as? [String: Any] else {
                if type == "turn_context" { model = "unknown" }
                partial = true; continue
            }
            if type == "turn_context" {
                model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
                if let cwd = payload["cwd"] as? String { currentProject = cwd }
                continue
            }
            guard payload["type"] as? String == "token_count" else { continue }
            // A null info token_count is a rate-limit update, with no usage sample.
            if payload["info"] is NSNull { continue }
            guard let info = payload["info"] as? [String: Any],
                  let total = Counters(info["total_token_usage"]) else { partial = true; continue }
            let last = Counters(info["last_token_usage"])
            let usage: Counters?
            if let previous {
                if previous == total { continue }
                if let increment = total.increment(from: previous) { usage = increment }
                else { usage = last; partial = true }
            } else {
                usage = last
                if total != last { partial = true }
            }
            previous = total
            guard let usage,
                  let timestamp = record["timestamp"] as? String,
                  let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else {
                partial = true; continue
            }
            guard date >= cutoff, date <= now, usage.input + usage.output > 0 else { continue }
            events.append(AIUsageEvent(id: "\(sessionID):\(timestamp):\(lineNumber)", date: date,
                                       sessionID: sessionID, model: model, project: currentProject,
                                       inputTokens: usage.input, cachedInputTokens: usage.cached, outputTokens: usage.output))
        }
        return (events, partial)
    }

    private func tableColumns(_ database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw AIUsageReaderError.queryFailed }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let column = string(statement, 1) { columns.insert(column) }
        }
        return columns
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
