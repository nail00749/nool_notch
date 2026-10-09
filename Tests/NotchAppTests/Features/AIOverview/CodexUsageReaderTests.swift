import Foundation
import SQLite3
import XCTest
@testable import NotchApp

final class CodexUsageReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCumulativeUsageDeduplicatesAndKeepsModelChanges() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [
            context("first"), usage(100, cached: 20, output: 30, lastInput: 10, lastOutput: 3),
            usage(100, cached: 20, output: 30, lastInput: 10, lastOutput: 3),
            context("second"), usage(150, cached: 30, output: 40),
        ])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(snapshot.events.map(\.model), ["first", "second"])
        XCTAssertEqual(snapshot.events.map(\.inputTokens), [10, 50])
        XCTAssertEqual(snapshot.events.map(\.cachedInputTokens), [0, 10])
        XCTAssertEqual(snapshot.events.map(\.outputTokens), [3, 10])
        XCTAssertEqual(snapshot.events.map(\.totalTokens), [13, 60])
    }

    func testResetUsesLastSampleAndReasoningIsNotAdditional() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [usage(100, output: 50, lastInput: 20, lastOutput: 10),
            usage(10, output: 5, lastInput: 10, lastOutput: 5), usage(20, output: 9)])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertEqual(snapshot.events.map(\.totalTokens), [30, 15, 14])
    }

    func testArchivedAndTopLevelSourcesAreIncludedButOtherSourcesExcluded() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        for source in ["vscode", "appServer", "cli", "subagent", "{\"subagent\":{}}"] {
            try fixture.session(source, source: source, archived: 1, records: [usage(10, lastInput: 10)])
        }
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertEqual(snapshot.scannedSessionCount, 3)
        XCTAssertEqual(snapshot.events.count, 3)
    }

    func testCutoffAndFutureEventsDoNotContributeButMaintainBaseline() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [
            usage(100, lastInput: 100, at: now.addingTimeInterval(-31 * 86_400)),
            usage(110), usage(120, at: now.addingTimeInterval(100)),
        ])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertEqual(snapshot.events.map(\.inputTokens), [10])
    }

    func testTailDoesNotUseDatabaseModelAndReportsPartial() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        let records = [context("old"), usage(100, lastInput: 10), usage(110, lastInput: 10)]
        try fixture.session("a", records: records)
        let lastSize = try JSONSerialization.data(withJSONObject: records.last!).count + 1
        let reader = CodexUsageReader(databaseURL: fixture.database, rolloutByteLimit: lastSize + 3)
        let snapshot = try reader.load(now: now)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.model, "unknown")
        XCTAssertEqual(snapshot.events.first?.inputTokens, 10)
    }

    func testOutsidePathAndSymlinkEscapeAreRejected() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("{}\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = fixture.root.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try fixture.session("outside", path: outside, records: [])
        try fixture.session("link", path: link, records: [])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.scannedSessionCount, 0)
        XCTAssertEqual(snapshot.skippedSessionCount, 2)
    }

    func testCandidateAndTotalByteBudgetsReportPartial() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [usage(10, lastInput: 10)])
        try fixture.session("b", records: [usage(10, lastInput: 10)])
        let limited = try CodexUsageReader(databaseURL: fixture.database, maximumCandidateCount: 1).load(now: now)
        XCTAssertTrue(limited.isPartial)
        XCTAssertEqual(limited.scannedSessionCount, 1)
        let bytes = try CodexUsageReader(databaseURL: fixture.database, totalByteLimit: 5).load(now: now)
        XCTAssertTrue(bytes.isPartial)
        XCTAssertTrue(bytes.events.isEmpty)
        XCTAssertEqual(bytes.skippedSessionCount, 1)
    }

    func testInvalidCountersAndOversizedRecordsAreSkipped() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [usage(1, cached: 2), usage(1_000_000_000_001),
                                          usage(10, lastInput: 10)])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.events.count, 1)
        let oversized = try CodexUsageReader(databaseURL: fixture.database, recordByteLimit: 10).load(now: now)
        XCTAssertTrue(oversized.isPartial)
        XCTAssertTrue(oversized.events.isEmpty)
    }

    func testUnavailableAndUnsupportedSchemaAreDistinctFromEmptyData() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        XCTAssertTrue(try fixture.reader.load(now: now).events.isEmpty)
        XCTAssertThrowsError(try CodexUsageReader(databaseURL: fixture.root.appendingPathComponent("missing.sqlite")).load()) {
            XCTAssertEqual($0 as? AIUsageReaderError, .databaseUnavailable)
        }
        try fixture.execute("DROP TABLE threads")
        XCTAssertThrowsError(try fixture.reader.load()) {
            XCTAssertEqual($0 as? AIUsageReaderError, .unsupportedSchema)
        }
    }

    func testCancellationIsPropagated() async throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        let instant = now
        let task = Task { () throws -> AIUsageSnapshot in
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.reader.load(now: instant)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Wrong error") }
    }

    func testMillisecondSchemaAndFractionalTimestamp() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.execute("ALTER TABLE threads RENAME COLUMN updated_at TO updated_at_ms")
        var record = usage(10, lastInput: 10)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        record["timestamp"] = fractional.string(from: now.addingTimeInterval(-0.5))
        try fixture.session("a", records: [record])
        try fixture.execute("UPDATE threads SET updated_at_ms = \(Int(now.timeIntervalSince1970 * 1000))")
        XCTAssertEqual(try fixture.reader.load(now: now).events.count, 1)
    }

    func testMissingLastBaselineSkipsHistoricalTotal() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [usage(500_000), usage(500_010)])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.events.map(\.inputTokens), [10])
    }

    func testModelRequiresContextAndMissingContextModelResetsIt() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [usage(10, lastInput: 10), context("known"), usage(20),
            ["type": "turn_context", "payload": [:]], usage(30)])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertEqual(snapshot.events.map(\.model), ["unknown", "known", "unknown"])
    }

    func testProjectChangesFollowTurnContext() throws {
        let fixture = try Fixture(now: now)
        defer { fixture.remove() }
        try fixture.session("a", records: [
            ["type": "turn_context", "payload": ["model": "model", "cwd": "/first/app"]],
            usage(10, lastInput: 10),
            ["type": "turn_context", "payload": ["model": "model", "cwd": "/second/app"]],
            usage(30)
        ])
        let snapshot = try fixture.reader.load(now: now)
        XCTAssertEqual(snapshot.events.map(\.project), ["/first/app", "/second/app"])
        XCTAssertEqual(snapshot.events.map(\.inputTokens), [10, 20])
    }

    private func context(_ model: String) -> [String: Any] {
        ["type": "turn_context", "payload": ["model": model]]
    }

    private func usage(_ input: Int64, cached: Int64 = 0, output: Int64 = 0,
                       lastInput: Int64? = nil, lastOutput: Int64 = 0, at: Date? = nil) -> [String: Any] {
        var info: [String: Any] = ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
            "output_tokens": output, "reasoning_output_tokens": output, "total_tokens": input + output]]
        if let lastInput {
            info["last_token_usage"] = ["input_tokens": lastInput, "cached_input_tokens": 0,
                                       "output_tokens": lastOutput, "reasoning_output_tokens": lastOutput]
        }
        return ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: at ?? now),
                "payload": ["type": "token_count", "info": info]]
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let database: URL
        let now: Date
        var reader: CodexUsageReader { CodexUsageReader(databaseURL: database) }

        init(now: Date) throws {
            self.now = now
            root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-tests-" + UUID().uuidString)
            database = root.appendingPathComponent("state_5.sqlite")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, model TEXT, source TEXT, updated_at INTEGER, archived INTEGER)")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func execute(_ sql: String) throws {
            var connection: OpaquePointer?
            guard sqlite3_open(database.path, &connection) == SQLITE_OK else { throw AIUsageReaderError.queryFailed }
            defer { sqlite3_close(connection) }
            guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw AIUsageReaderError.queryFailed }
        }

        func session(_ id: String, source: String = "vscode", archived: Int = 0,
                     path: URL? = nil, records: [[String: Any]]) throws {
            let rollout = path ?? root.appendingPathComponent(UUID().uuidString + ".jsonl")
            if path == nil {
                var data = Data()
                for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
                try data.write(to: rollout)
            }
            func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "''") + "'" }
            try execute("INSERT INTO threads VALUES (\(quote(id)), \(quote(rollout.path)), '/projects/demo', 'fallback', \(quote(source)), \(Int(now.timeIntervalSince1970)), \(archived))")
        }
    }
}
