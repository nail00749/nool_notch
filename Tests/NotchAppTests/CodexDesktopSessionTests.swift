import Foundation
import SQLite3
import XCTest
@testable import NotchApp

final class CodexDesktopSessionTests: XCTestCase {
    func testJSONRPCParserBuffersPartialLines() {
        var buffer = Data(#"{"method":"thread/status/changed","params":{"threadId":"a"}}"#.utf8)
        XCTAssertTrue(CodexAppServerClient.drainMessages(buffer: &buffer).isEmpty)

        buffer.append(0x0A)
        buffer.append(Data(#"{"method":"thread/closed","params":{"threadId":"b"}}"#.utf8))
        let first = CodexAppServerClient.drainMessages(buffer: &buffer)

        XCTAssertEqual(first.map(\.method), ["thread/status/changed"])
        XCTAssertFalse(buffer.isEmpty)

        buffer.append(0x0A)
        XCTAssertEqual(CodexAppServerClient.drainMessages(buffer: &buffer).map(\.method), ["thread/closed"])
        XCTAssertTrue(buffer.isEmpty)
    }

    @MainActor
    func testCodexStatusMappingUsesAttentionFlags() {
        XCTAssertEqual(
            CodexDesktopSessionSource.status(from: .object([
                "type": .string("active"),
                "activeFlags": .array([.string("waitingOnApproval")])
            ])),
            .waitingForApproval
        )
        XCTAssertEqual(
            CodexDesktopSessionSource.status(from: .object([
                "type": .string("active"),
                "activeFlags": .array([.string("waitingOnUserInput")])
            ])),
            .waitingForInput
        )
        XCTAssertEqual(
            CodexDesktopSessionSource.status(from: .object(["type": .string("idle")])),
            .completed
        )
    }

    func testStateReaderIncludesDesktopAndExcludesCLIAndArchived() throws {
        let fixture = try CodexStateFixture()
        defer { fixture.remove() }
        let runningRollout = try fixture.writeRollout(
            name: "running.jsonl",
            events: ["task_started"]
        )
        let completedRollout = try fixture.writeRollout(
            name: "completed.jsonl",
            events: ["task_started", "task_complete"]
        )
        try fixture.insert(
            id: "desktop-running",
            source: "vscode",
            archived: false,
            rolloutPath: runningRollout.path,
            updatedAtMilliseconds: 2_000_000,
            title: "Running task"
        )
        try fixture.insert(
            id: "desktop-complete",
            source: "appServer",
            archived: false,
            rolloutPath: completedRollout.path,
            updatedAtMilliseconds: 1_000_000,
            title: "Complete task"
        )
        try fixture.insert(
            id: "cli",
            source: "cli",
            archived: false,
            rolloutPath: runningRollout.path,
            updatedAtMilliseconds: 3_000_000,
            title: "CLI"
        )
        try fixture.insert(
            id: "archived",
            source: "vscode",
            archived: true,
            rolloutPath: runningRollout.path,
            updatedAtMilliseconds: 4_000_000,
            title: "Archived"
        )

        let sessions = try CodexStateReader(databaseURL: fixture.databaseURL).loadSessions()

        XCTAssertEqual(sessions.map(\.id.sessionID), ["desktop-running", "desktop-complete"])
        XCTAssertEqual(sessions.map(\.status), [.running, .completed])
        XCTAssertEqual(sessions.first?.workspaceName, "NotchApp")
    }

    @MainActor
    func testOpenBuildsExactThreadURL() async {
        let recorder = CodexURLRecorder()
        let source = CodexDesktopSessionSource(
            urlOpener: { url in recorder.urls.append(url); return true },
            applicationActivator: { _ in false }
        )

        let opened = await source.open(sessionID: "thread id")
        XCTAssertTrue(opened)
        XCTAssertEqual(recorder.urls.first?.absoluteString, "codex://threads/thread%20id")
    }
}

@MainActor
private final class CodexURLRecorder {
    var urls: [URL] = []
}

private final class CodexStateFixture {
    let directoryURL: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchApp-CodexTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directoryURL.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw CodexStateReaderError.databaseUnavailable
        }
        try execute("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                cwd TEXT,
                archived INTEGER,
                source TEXT,
                updated_at_ms INTEGER,
                title TEXT,
                model TEXT
            );
            """)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func remove() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func writeRollout(name: String, events: [String]) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        let lines = events.map { event in
            #"{"type":"event_msg","payload":{"type":"\#(event)"}}"#
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: url)
        return url
    }

    func insert(
        id: String,
        source: String,
        archived: Bool,
        rolloutPath: String,
        updatedAtMilliseconds: Int64,
        title: String
    ) throws {
        guard let database else { throw CodexStateReaderError.databaseUnavailable }
        let sql = """
            INSERT INTO threads
            (id, rollout_path, cwd, archived, source, updated_at_ms, title, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CodexStateReaderError.queryFailed }
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, index: 1)
        bind(rolloutPath, to: statement, index: 2)
        bind("/tmp/NotchApp", to: statement, index: 3)
        sqlite3_bind_int(statement, 4, archived ? 1 : 0)
        bind(source, to: statement, index: 5)
        sqlite3_bind_int64(statement, 6, updatedAtMilliseconds)
        bind(title, to: statement, index: 7)
        bind("gpt", to: statement, index: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CodexStateReaderError.queryFailed
        }
    }

    private func execute(_ sql: String) throws {
        guard let database,
              sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CodexStateReaderError.queryFailed
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
