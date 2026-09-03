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

    func testJSONRPCParserPreservesStringRequestID() {
        var buffer = Data(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread"}}"#.utf8)
        buffer.append(0x0A)

        let message = CodexAppServerClient.drainMessages(buffer: &buffer).first

        XCTAssertEqual(message?.id, .string("approval-1"))
        XCTAssertEqual(message?.method, "item/commandExecution/requestApproval")
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

    func testStateReaderCanSelectAndNamespaceCLISessions() throws {
        let fixture = try CodexStateFixture()
        defer { fixture.remove() }
        let rollout = try fixture.writeRollout(name: "cli.jsonl", events: ["task_started"])
        try fixture.insert(
            id: "cli-thread",
            source: "cli",
            archived: false,
            rolloutPath: rollout.path,
            updatedAtMilliseconds: 1_000,
            title: "CLI task"
        )

        let sessions = try CodexStateReader(
            databaseURL: fixture.databaseURL,
            sessionSourceID: "local-agents",
            acceptedThreadSources: ["cli"],
            agentName: "Codex CLI",
            sessionIDPrefix: "codex-cli:"
        ).loadSessions()

        XCTAssertEqual(sessions.map(\.id.sessionID), ["codex-cli:cli-thread"])
        XCTAssertEqual(sessions.first?.agentName, "Codex CLI")
    }

    func testHookEventAcceptsLocalAgentsWithoutExposingCommand() throws {
        let data = Data(#"{"_source":"claude-code","hook_event_name":"PermissionRequest","session_id":"session-1","cwd":"/tmp/App","tool_name":"Bash","tool_input":{"command":"git status"}}"#.utf8)

        let event = try XCTUnwrap(CodexCLIHookEvent(data: data))

        XCTAssertEqual(event.sourceID, "claude-code")
        XCTAssertTrue(event.isPermissionRequest)
        XCTAssertEqual(event.detail, "Инструмент: Bash")
        XCTAssertEqual(event.workspacePath, "/tmp/App")
    }

    func testHookConfigMergePreservesForeignEntriesAndIsIdempotent() throws {
        let existing = Data(#"{"custom":true,"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"foreign-hook"}]}]}}"#.utf8)
        let events = [(name: "PermissionRequest", timeout: 86_400)]

        let first = try CodexCLIHookInstaller.mergedHooksData(
            existing: existing,
            command: "'/tmp/nool-agent-bridge' --source codex-cli",
            events: events,
            matcher: nil
        )
        let second = try CodexCLIHookInstaller.mergedHooksData(
            existing: first,
            command: "'/tmp/nool-agent-bridge' --source codex-cli",
            events: events,
            matcher: nil
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: second) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])

        XCTAssertEqual(object["custom"] as? Bool, true)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(first, second)
    }

    func testHookConfigRemovalPreservesForeignEntries() throws {
        let existing = Data(#"{"custom":true,"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"foreign-hook"}]},{"hooks":[{"type":"command","command":"'/tmp/nool-agent-bridge' --source codex-cli"}]}]}}"#.utf8)

        let output = try CodexCLIHookInstaller.removingManagedHooksData(existing: existing)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])

        XCTAssertEqual(object["custom"] as? Bool, true)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(
            ((entries[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String),
            "foreign-hook"
        )
    }

    func testHooksFeatureEnableDisableRoundTripRestoresPriorState() {
        let original = """
        model = "gpt-5"

        [features]
        hooks = false # keep user choice
        """
        let prior = CodexCLIHookInstaller.hooksFeatureState(in: original)
        let enabled = CodexCLIHookInstaller.settingHooksFeature(in: original, to: .enabled)
        let restored = CodexCLIHookInstaller.settingHooksFeature(in: enabled, to: prior)

        XCTAssertEqual(prior, .disabled)
        XCTAssertEqual(CodexCLIHookInstaller.hooksFeatureState(in: enabled), .enabled)
        XCTAssertEqual(CodexCLIHookInstaller.hooksFeatureState(in: restored), .disabled)
        XCTAssertTrue(restored.contains("hooks = false # keep user choice"))
    }

    func testHooksFeatureRemovalRestoresAbsentState() {
        let original = "model = \"gpt-5\"\n"
        let enabled = CodexCLIHookInstaller.settingHooksFeature(in: original, to: .enabled)
        let restored = CodexCLIHookInstaller.settingHooksFeature(in: enabled, to: .absent)

        XCTAssertEqual(CodexCLIHookInstaller.hooksFeatureState(in: restored), .absent)
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
