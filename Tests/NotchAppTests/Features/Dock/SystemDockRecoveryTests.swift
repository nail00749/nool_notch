import Foundation
import Darwin
import XCTest
import NotchCore
@testable import NotchApp

final class SystemDockRecoveryTests: XCTestCase {
    func testTypesAndMissingRoundTripExactly() throws {
        let values: [SystemDockValue] = [.bool(true), .integer(1), .real(1), .string("value"),
            .data(Data([1, 2])), .date(Date(timeIntervalSince1970: 42)), .array([.bool(false)]),
            .dictionary(["nested": .integer(12)])]
        for value in values {
            XCTAssertEqual(try SystemDockValue(propertyList: value.propertyList), value)
            XCTAssertEqual(try JSONDecoder().decode(SystemDockValue.self, from: JSONEncoder().encode(value)), value)
        }
        XCTAssertNotEqual(SystemDockPreference.value(.bool(true)), .value(.integer(1)))
        XCTAssertNotEqual(SystemDockPreference.value(.integer(1)), .value(.real(1)))
        XCTAssertNotEqual(SystemDockPreference.missing, .value(.bool(false)))
    }

    func testPrepareIsDurableBeforeAnyPreferenceWrite() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let prepared = try f.engine.prepare(owner: f.owner)
        XCTAssertEqual(try f.engine.journal(), prepared)
        XCTAssertTrue(f.backend.events.isEmpty)
        XCTAssertEqual(prepared.original["autohide-delay"], .missing)
    }

    func testNoHelperRefusesBeforeWrites() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let prepared = try f.engine.prepare(owner: f.owner)
        XCTAssertThrowsError(try f.engine.apply(token: prepared.token))
        XCTAssertTrue(f.backend.events.isEmpty)
        _ = try f.engine.restore(token: prepared.token)
        XCTAssertNil(try f.engine.journal())
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testSuccessfulRestoreRestoresValueAndDeletesPreviouslyMissingKey() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        XCTAssertEqual(f.backend.values, SystemDockRecoveryEngine.writes)
        XCTAssertEqual(try f.engine.restore(token: token).conflicts, [])
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertNil(try f.engine.journal())
        XCTAssertEqual(f.backend.events.filter { $0 == "restart" }.count, 2)
    }

    func testNondefaultIntegerDelayAndMalformedButValidPlistArePreserved() throws {
        let original: [String: SystemDockPreference] = ["autohide": .value(.string("foreign")),
                                                       "autohide-delay": .value(.integer(27))]
        let f = try Fixture(original: original)
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        _ = try f.engine.restore(token: token)
        XCTAssertEqual(f.backend.values, original)
    }

    func testForeignChangeIsPreservedAndReportedWhileOtherKeyRestores() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        f.backend.values["autohide-delay"] = .value(.real(2.5))
        XCTAssertEqual(try f.engine.restore(token: token).conflicts, ["autohide-delay"])
        XCTAssertEqual(f.backend.values["autohide"], f.original["autohide"])
        XCTAssertEqual(f.backend.values["autohide-delay"], .value(.real(2.5)))
        XCTAssertNil(try f.engine.journal())
    }

    func testForeignChangeBeforeFirstWriteDoesNotGetOverwrittenByCleanup() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        f.backend.values["autohide"] = .value(.bool(true))
        XCTAssertThrowsError(try f.engine.apply(token: token))
        _ = try f.engine.restore(token: token)
        XCTAssertEqual(f.backend.values["autohide"], .value(.bool(true)))
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testPartialWriteFailureRollsBackBeforeReturning() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        f.backend.failWriteOnce = "autohide-delay"
        XCTAssertThrowsError(try f.engine.apply(token: token))
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertNil(try f.engine.journal())
    }

    func testRestartFailureRollsBackAndRestartsOriginalConfiguration() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        f.backend.restartFailures = 1
        XCTAssertThrowsError(try f.engine.apply(token: token))
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertNil(try f.engine.journal())
        XCTAssertEqual(f.backend.events.filter { $0 == "restart" }.count, 2)
    }

    func testRestoreFailureKeepsJournalForRetry() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        f.backend.failWriteOnce = "autohide"
        XCTAssertThrowsError(try f.engine.restore(token: token))
        XCTAssertNotNil(try f.engine.journal())
        _ = try f.engine.restore(token: token)
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertNil(try f.engine.journal())
    }

    func testFailedRestoreRestartIsRetriedEvenWhenValuesAlreadyRestored() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        f.backend.restartFailures = 1
        XCTAssertThrowsError(try f.engine.restore(token: token))
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertNotNil(try f.engine.journal())
        _ = try f.engine.restore(token: token)
        XCTAssertNil(try f.engine.journal())
        XCTAssertEqual(f.backend.events.filter { $0 == "restart" }.count, 3)
    }

    func testCrashRecoveryRefusesLiveOwnerThenRestoresAfterExit() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        XCTAssertThrowsError(try f.engine.restore(onlyIfOwnerExited: true))
        XCTAssertEqual(f.backend.values, SystemDockRecoveryEngine.writes)
        f.identities.set(nil, pid: f.owner.pid)
        _ = try f.engine.restore(onlyIfOwnerExited: true)
        XCTAssertEqual(f.backend.values, f.original)
    }

    func testPIDReuseDoesNotKeepDeadOwnersLeaseAlive() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        var reused = f.owner
        reused.startSeconds += 1
        f.identities.set(reused, pid: reused.pid)
        _ = try f.engine.restore(onlyIfOwnerExited: true)
        XCTAssertEqual(f.backend.values, f.original)
    }

    func testReusedHelperPIDCannotAuthorizeMutation() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        var reused = f.helper
        reused.startMicroseconds += 1
        f.identities.set(reused, pid: reused.pid)
        XCTAssertThrowsError(try f.engine.apply(token: token))
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testOldHelperTokenCannotRestoreNewOwnerJournal() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let oldToken = try f.ready()
        _ = try f.engine.restore(token: oldToken)
        let newToken = try f.ready()
        try f.engine.apply(token: newToken)
        XCTAssertThrowsError(try f.engine.restore(token: oldToken))
        XCTAssertEqual(try f.engine.journal()?.token, newToken)
        XCTAssertEqual(f.backend.values, SystemDockRecoveryEngine.writes)
    }

    func testSecondPrepareDoesNotReplaceRecoverySnapshot() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let first = try f.engine.prepare(owner: f.owner)
        XCTAssertThrowsError(try f.engine.prepare(owner: f.owner))
        XCTAssertEqual(try f.engine.journal(), first)
    }

    func testJournalAndLockHavePrivatePermissions() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try f.ready()
        for component in ["journal.json", "lock"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: f.directory.appendingPathComponent(component).path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: f.directory.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testJournalSymlinkAndWorldReadableFileRefused() throws {
        for symlink in [true, false] {
            let f = try Fixture()
            defer { f.cleanup() }
            _ = try f.ready()
            let url = f.directory.appendingPathComponent("journal.json")
            if symlink {
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
            } else { XCTAssertEqual(chmod(url.path, 0o644), 0) }
            XCTAssertThrowsError(try f.engine.journal())
            XCTAssertTrue(f.backend.events.isEmpty)
        }
    }

    func testCorruptedJournalNeverWritesPreferences() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try f.ready()
        try Data("{invalid".utf8).write(to: f.directory.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try f.engine.restore())
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testConcurrentNormalAndCrashRestoreSerializeToOneCleanup() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        f.identities.set(nil, pid: f.owner.pid)
        let group = DispatchGroup()
        let outcomes = Results()
        for _ in 0 ..< 2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try f.engine.restore(token: token, onlyIfOwnerExited: true); outcomes.record(success: true) }
                catch { outcomes.record(success: false) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(outcomes.successCount, 2)
        XCTAssertEqual(f.backend.values, f.original)
        XCTAssertEqual(f.backend.events.filter { $0 == "restart" }.count, 2)
        XCTAssertNil(try f.engine.journal())
    }

    func testLiveProcessIdentityIncludesKernelBirthTime() throws {
        let live = try XCTUnwrap(SystemDockProcessIdentity.live(getpid()))
        XCTAssertEqual(live.pid, getpid())
        XCTAssertEqual(live.uid, getuid())
        XCTAssertGreaterThan(live.startSeconds, 0)
        XCTAssertNil(SystemDockProcessIdentity.live(-1))
    }

    func testRecoveryBackoffContinuesAfterMoreThanFiveFailures() throws {
        var retry = SystemDockRecoveryRetryPolicy()
        XCTAssertEqual((0 ..< 9).map { _ in retry.nextDelay() }, [1, 2, 4, 8, 16, 30, 30, 30, 30])
        let f = try Fixture()
        defer { f.cleanup() }
        let token = try f.ready()
        try f.engine.apply(token: token)
        f.identities.set(nil, pid: f.owner.pid)
        f.backend.restartFailures = 7
        for _ in 0 ..< 7 { XCTAssertThrowsError(try f.engine.restore(token: token, onlyIfOwnerExited: true)) }
        XCTAssertNotNil(try f.engine.journal())
        _ = try f.engine.restore(token: token, onlyIfOwnerExited: true)
        XCTAssertNil(try f.engine.journal())
        XCTAssertEqual(f.backend.values, f.original)
    }

    func testFailedStartupRecoveryRemainsPendingThenRetryClearsStatus() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        XCTAssertEqual(f.engine.recoveryStatus(), .none)
        let token = try f.ready()
        try f.engine.apply(token: token)
        XCTAssertEqual(f.engine.recoveryStatus(), .anotherOwner)
        XCTAssertEqual(f.engine.recoveryStatus(ownedToken: token), .owned)
        f.identities.set(nil, pid: f.owner.pid)
        f.backend.restartFailures = 1
        XCTAssertThrowsError(try f.engine.restore(onlyIfOwnerExited: true))
        XCTAssertEqual(f.engine.recoveryStatus(), .stale)
        XCTAssertTrue(f.engine.recoveryStatus().needsRecovery)
        _ = try f.engine.restore(onlyIfOwnerExited: true)
        XCTAssertEqual(f.engine.recoveryStatus(), .none)
    }

    func testUnreadableJournalIsPendingWithoutPretendingToOwnIt() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try f.ready()
        try Data("{invalid".utf8).write(to: f.directory.appendingPathComponent("journal.json"))
        XCTAssertEqual(f.engine.recoveryStatus(), .unreadable)
        XCTAssertTrue(f.engine.recoveryStatus().needsRecovery)
        XCTAssertTrue(f.backend.events.isEmpty)
    }

    func testIndependentHelperRestoresFakePreferencesAfterParentSIGKILL() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = project.appendingPathComponent(".build/debug/NoolDockRecovery")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("NoolDockRecovery product must be built before the independent helper fixture")
        }
        let directory = URL(fileURLWithPath: "/private/tmp/nool-system-dock-process-\(UUID().uuidString)", isDirectory: true)
        let parent = Process(), output = Pipe()
        var helperIdentity: SystemDockProcessIdentity?
        defer {
            if parent.isRunning { kill(parent.processIdentifier, SIGKILL); parent.waitUntilExit() }
            if let helperIdentity, SystemDockProcessIdentity.live(helperIdentity.pid) == helperIdentity {
                kill(helperIdentity.pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        parent.executableURL = executable
        parent.arguments = ["--fixture-parent", directory.path]
        parent.standardOutput = output
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        let fd = output.fileHandleForReading.fileDescriptor
        XCTAssertEqual(fcntl(fd, F_SETFL, O_NONBLOCK), 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var ready = Data()
        while !ready.contains(10) && parent.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { ready.append(contentsOf: bytes.prefix(count)) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let message = String(decoding: ready, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.hasPrefix("ACTIVE "), let pid = Int32(message.dropFirst(7)) else {
            XCTFail("Fake parent did not activate: \(message)"); return
        }
        helperIdentity = SystemDockProcessIdentity.live(pid)
        let file = directory.appendingPathComponent("fixture-preferences.json")
        let active = try JSONDecoder().decode([String: SystemDockPreference].self, from: Data(contentsOf: file))
        XCTAssertEqual(active, SystemDockRecoveryEngine.writes)
        XCTAssertEqual(kill(parent.processIdentifier, SIGKILL), 0)
        parent.waitUntilExit()
        let recoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
        let journal = directory.appendingPathComponent("journal.json")
        while FileManager.default.fileExists(atPath: journal.path) && ProcessInfo.processInfo.systemUptime < recoveryDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        let restored = try JSONDecoder().decode([String: SystemDockPreference].self, from: Data(contentsOf: file))
        XCTAssertEqual(restored, ["autohide": .value(.bool(false)), "autohide-delay": .missing])
    }
}

private final class Fixture: @unchecked Sendable {
    let directory: URL
    let owner = SystemDockProcessIdentity(pid: 42, uid: getuid(), startSeconds: 5, startMicroseconds: 10)
    let helper = SystemDockProcessIdentity(pid: 43, uid: getuid(), startSeconds: 6, startMicroseconds: 11)
    let backend: FakeDockBackend
    let identities = FakeDockIdentities()
    let engine: SystemDockRecoveryEngine
    let original: [String: SystemDockPreference]

    init(original: [String: SystemDockPreference] = ["autohide": .value(.bool(false)), "autohide-delay": .missing]) throws {
        self.original = original
        directory = URL(fileURLWithPath: "/private/tmp/nool-system-dock-tests-\(UUID().uuidString)", isDirectory: true)
        backend = FakeDockBackend(original)
        let lookup = identities
        engine = SystemDockRecoveryEngine(store: .init(directory: directory), backend: backend,
                                          identity: { lookup.get($0) })
        identities.set(owner, pid: owner.pid)
        identities.set(helper, pid: helper.pid)
    }

    func ready() throws -> UUID {
        let journal = try engine.prepare(owner: owner)
        try engine.registerHelper(token: journal.token, helper: helper)
        return journal.token
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class FakeDockBackend: SystemDockPreferenceBackend, @unchecked Sendable {
    var values: [String: SystemDockPreference]
    var events: [String] = []
    var failWriteOnce: String?
    var restartFailures = 0
    init(_ values: [String: SystemDockPreference]) { self.values = values }
    func read(_ key: String) throws -> SystemDockPreference { values[key] ?? .missing }
    func write(_ value: SystemDockPreference, for key: String) throws {
        events.append("write:\(key)")
        if failWriteOnce == key { failWriteOnce = nil; throw SystemDockRecoveryError.operationFailed }
        values[key] = value
    }
    func restartDock() throws {
        events.append("restart")
        if restartFailures > 0 { restartFailures -= 1; throw SystemDockRecoveryError.operationFailed }
    }
}

private final class FakeDockIdentities: @unchecked Sendable {
    let lock = NSLock()
    private var identities: [Int32: SystemDockProcessIdentity] = [:]
    func get(_ pid: Int32) -> SystemDockProcessIdentity? { lock.withLock { identities[pid] } }
    func set(_ value: SystemDockProcessIdentity?, pid: Int32) { lock.withLock { identities[pid] = value } }
}

private final class Results: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    var successCount: Int { lock.withLock { count } }
    func record(success: Bool) { lock.withLock { if success { count += 1 } } }
}

@MainActor
final class SystemDockControllerTests: XCTestCase {
    func testInitializationDoesNotRunAnyOperation() async {
        let operations = FakeSystemDockOperations()
        let controller = SystemDockController(operations: operations)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isBusy)
        let calls = await operations.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testModuleStopRestoreWaitsForInFlightEnable() async {
        let operations = FakeSystemDockOperations(holdEnable: true)
        let controller = SystemDockController(operations: operations)
        let enable = Task { await controller.setEnabled(true) }
        await operations.waitForEnable()
        let restore = Task { await controller.restore() }
        await Task.yield()
        XCTAssertTrue(controller.isBusy)
        await operations.releaseEnable()
        await enable.value
        await restore.value
        let calls = await operations.calls
        XCTAssertEqual(calls, [.enable, .restore])
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isBusy)
    }

    func testRecoveryNeverRunsOverAnActiveReplacement() async {
        let operations = FakeSystemDockOperations()
        let controller = SystemDockController(operations: operations)
        await controller.setEnabled(true)
        await controller.recoverIfNeeded()
        let calls = await operations.calls
        XCTAssertEqual(calls, [.enable])
        XCTAssertTrue(controller.isActive)
    }

    func testRecoveryFromStartupNeverEnablesReplacement() async {
        let operations = FakeSystemDockOperations()
        let controller = SystemDockController(operations: operations)
        await controller.recoverIfNeeded()
        let calls = await operations.calls
        XCTAssertEqual(calls, [.recover])
        XCTAssertFalse(controller.isActive)
    }

    func testStartupFailureExposesPendingRecoveryUntilExplicitRetrySucceeds() async {
        let operations = FailedStartupDockOperations()
        let controller = SystemDockController(operations: operations)
        await controller.recoverIfNeeded()
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(controller.recoveryPending)
        XCTAssertEqual(controller.errorMessage, "retry required")
        await controller.restore()
        XCTAssertFalse(controller.recoveryPending)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.errorMessage)
    }
}

private actor FailedStartupDockOperations: SystemDockOperating {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        switch operation {
        case .recover: .init(active: false, error: "retry required", recoveryPending: true)
        case .restore: .init(active: false)
        case .enable: .init(active: true)
        }
    }
}

private actor FakeSystemDockOperations: SystemDockOperating {
    private(set) var calls: [SystemDockOperation] = []
    let holdEnable: Bool
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    init(holdEnable: Bool = false) { self.holdEnable = holdEnable }
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        calls.append(operation)
        if operation == .enable, holdEnable {
            await withCheckedContinuation { continuation in
                release = continuation
                started?.resume(); started = nil
            }
        }
        return .init(active: operation == .enable)
    }
    func waitForEnable() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseEnable() { release?.resume(); release = nil }
}
