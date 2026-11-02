import Foundation
import XCTest
@testable import NotchApp

final class MonitorPanelAccessTests: XCTestCase {
    func testSharedManagerAndNativeLockABIsRejectUnexpectedSignatures() {
        XCTAssertTrue(MonitorPanelAccessABI.matches(returnType: "@", arguments: ["@", ":"], expectedReturn: "@"))
        XCTAssertTrue(MonitorPanelAccessABI.matches(returnType: "v", arguments: ["@", ":"], expectedReturn: "v"))
        for (result, arguments) in [("v", ["@", ":"]), ("@", ["#", ":"]), ("@", ["@", ":", "@"]),
                                    ("@", ["@"]), ("^v", ["@", ":"])] {
            XCTAssertFalse(MonitorPanelAccessABI.matches(returnType: result, arguments: arguments, expectedReturn: "@"))
        }
        XCTAssertFalse(MonitorPanelAccessABI.matches(returnType: "B", arguments: ["@", ":"], expectedReturn: "v"))
    }

    func testTwoClientsShareSingleFactoryAndSerializeAllNativeAccess() {
        let probe = Probe()
        let access = MonitorPanelAccess {
            probe.created()
            return .init(manager: FakeManager(), lockAccess: { probe.acquired() }, unlockAccess: { probe.released() })
        }
        let hdrClient: @Sendable () -> Void = {
            access.withManager { manager in
                probe.enter(manager)
                defer { probe.leave() }
                Thread.sleep(forTimeInterval: 0.0002)
            }
        }
        let referencePresetClient: @Sendable () -> Void = {
            access.withManager { manager in
                probe.enter(manager)
                defer { probe.leave() }
                Thread.sleep(forTimeInterval: 0.0002)
            }
        }
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if index.isMultiple(of: 2) { hdrClient() } else { referencePresetClient() }
        }
        let state = probe.snapshot
        XCTAssertEqual(state.creations, 1)
        XCTAssertEqual(state.identifiers.count, 1)
        XCTAssertEqual(state.maximumActive, 1)
        XCTAssertEqual(state.entered, 128)
        XCTAssertEqual(state.active, 0)
        XCTAssertEqual(state.acquired, 128)
        XCTAssertEqual(state.released, 128)
        XCTAssertFalse(state.accessViolation)
    }

    func testThrownOperationReleasesBothNativeAndProcessGates() throws {
        enum Failure: Error { case expected }
        let probe = Probe()
        let access = MonitorPanelAccess {
            probe.created()
            return .init(manager: FakeManager(), lockAccess: { probe.acquired() }, unlockAccess: { probe.released() })
        }
        XCTAssertThrowsError(try access.withManager { manager -> Int in
            probe.enter(manager)
            defer { probe.leave() }
            throw Failure.expected
        })
        XCTAssertEqual(probe.snapshot.acquired, 1)
        XCTAssertEqual(probe.snapshot.released, 1)
        let value = access.withManager { manager in
            probe.enter(manager)
            defer { probe.leave() }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(probe.snapshot.creations, 1)
        XCTAssertEqual(probe.snapshot.acquired, 2)
        XCTAssertEqual(probe.snapshot.released, 2)
        XCTAssertFalse(probe.snapshot.accessViolation)
    }

    func testManagerRemainsAliveBetweenCallsAndIsOwnedByTheAccessObject() {
        let lifetime = LifetimeProbe()
        var access: MonitorPanelAccess? = MonitorPanelAccess {
            let manager = FakeManager()
            lifetime.set(manager)
            return .init(manager: manager)
        }
        XCTAssertFalse(lifetime.isAlive)
        autoreleasepool {
            access!.withManager { manager in XCTAssertNotNil(manager) }
        }
        XCTAssertTrue(lifetime.isAlive, "The owner retains the shared manager beyond each native-call pool")
        autoreleasepool { access = nil }
        XCTAssertFalse(lifetime.isAlive)
    }

    func testUnavailableFactoryIsNotRepeatedAcrossClients() {
        let probe = Probe()
        let access = MonitorPanelAccess { probe.created(); return nil }
        for _ in 0..<20 {
            XCTAssertTrue(access.withManager { $0 == nil })
        }
        XCTAssertEqual(probe.snapshot.creations, 1)
    }

    private final class FakeManager: NSObject {}

    private final class LifetimeProbe {
        private weak var manager: NSObject?
        func set(_ value: NSObject) { manager = value }
        var isAlive: Bool { manager != nil }
    }

    private final class Probe: @unchecked Sendable {
        struct Snapshot: Sendable {
            var creations = 0
            var active = 0
            var maximumActive = 0
            var entered = 0
            var acquired = 0
            var released = 0
            var nativeHeld = false
            var accessViolation = false
            var identifiers: Set<ObjectIdentifier> = []
        }
        private let lock = NSLock()
        private var state = Snapshot()
        var snapshot: Snapshot { lock.withLock { state } }
        func created() { lock.withLock { state.creations += 1 } }
        func acquired() {
            lock.withLock {
                if state.nativeHeld { state.accessViolation = true }
                state.nativeHeld = true
                state.acquired += 1
            }
        }
        func released() {
            lock.withLock {
                if !state.nativeHeld || state.active != 0 { state.accessViolation = true }
                state.nativeHeld = false
                state.released += 1
            }
        }
        func enter(_ manager: NSObject?) {
            lock.withLock {
                if !state.nativeHeld { state.accessViolation = true }
                state.active += 1
                state.maximumActive = max(state.maximumActive, state.active)
                state.entered += 1
                if let manager { state.identifiers.insert(ObjectIdentifier(manager)) }
            }
        }
        func leave() { lock.withLock { state.active -= 1 } }
    }
}
