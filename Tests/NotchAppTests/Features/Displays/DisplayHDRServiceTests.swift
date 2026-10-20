import XCTest
@testable import NotchApp

final class DisplayHDRServiceTests: XCTestCase {
    private let target = DisplayHardwareTarget(uuid: "test", displayID: 42, isBuiltin: false)

    @MainActor
    func testInjectedWatchdogBoundsStuckReadAndRejectsFurtherWork() async {
        let runtime = BlockingRuntime()
        defer { runtime.gate.signal() }
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        let service = DynamicDisplayHDRService(executor: DisplayHardwareExecutor(timeout: 0.03), driver: driver)
        let start = ContinuousClock.now
        do {
            _ = try await service.read(target)
            XCTFail("The blocked driver must time out")
        } catch {
            guard case DisplayHDRError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        do {
            _ = try await service.setHDR(true, for: target)
            XCTFail("The tripped executor must reject subsequent writes")
        } catch {
            guard case DisplayHDRError.timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor
    func testFullExecutorReportsHDRBusyAndCancellationPassesThrough() async {
        let runtime = BlockingRuntime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        let executor = DisplayHardwareExecutor(timeout: 10)
        let service = DynamicDisplayHDRService(executor: executor, driver: driver)
        let target = target
        let requests = (0..<16).map { _ in Task { try await service.read(target) } }
        defer { requests.forEach { $0.cancel() }; runtime.gate.signal() }
        for _ in 0..<1000 { if executor.pendingRequestCount == 16 { break }; await Task.yield() }
        XCTAssertEqual(executor.pendingRequestCount, 16)
        do {
            _ = try await service.setHDR(true, for: target)
            XCTFail("A full executor must reject the write")
        } catch {
            guard case DisplayHDRError.busy = error else { return XCTFail("Unexpected error: \(error)") }
        }
        requests.forEach { $0.cancel() }
        runtime.gate.signal()
        for request in requests {
            do { _ = try await request.value; XCTFail("Cancellation must not become an HDR error") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    @MainActor
    func testNativeHDRFailurePassesThroughExecutorMappingUnchanged() async {
        let runtime = Runtime()
        runtime.readError = DisplayHDRError.notApplied
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        let service = DynamicDisplayHDRService(driver: driver)
        do {
            _ = try await service.read(target)
            XCTFail("The native failure must be preserved")
        } catch {
            guard case DisplayHDRError.notApplied = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSelectorABIRequiresVoidSetterAndExactBoolArgument() {
        XCTAssertTrue(DisplayHDRSelectorABI.matches(returnType: "v", arguments: ["@", ":", "B"], expectedReturn: "v", parameters: ["B"]))
        XCTAssertFalse(DisplayHDRSelectorABI.matches(returnType: "B", arguments: ["@", ":", "B"], expectedReturn: "v", parameters: ["B"]))
        XCTAssertFalse(DisplayHDRSelectorABI.matches(returnType: "v", arguments: ["@", ":", "i"], expectedReturn: "v", parameters: ["B"]))
        XCTAssertFalse(DisplayHDRSelectorABI.matches(returnType: "@", arguments: ["@", ":", "i"], expectedReturn: "@", parameters: []))
    }

    func testBuiltinHasNoHDRToggleAndDoesNotReachPrivateRuntime() throws {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        let builtin = DisplayHardwareTarget(uuid: "builtin", displayID: 1, isBuiltin: true)
        XCTAssertNil(try driver.read(builtin))
        XCTAssertThrowsError(try driver.setHDR(true, for: builtin, active: { true }))
        XCTAssertEqual(runtime.reads, [])
        XCTAssertEqual(runtime.writes, [])
    }

    func testMissingOrUnsupportedRuntimeRemainsUnsupported() throws {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        runtime.value = nil
        XCTAssertNil(try driver.read(target))
        runtime.value = .init(supported: false, enabled: false, preferred: false)
        XCTAssertNil(try driver.read(target))
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testUnsettledActualAndPreferredStateCannotBeReadOrMutated() {
        let runtime = Runtime()
        runtime.value = .init(supported: true, enabled: false, preferred: true)
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        XCTAssertThrowsError(try driver.read(target))
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testSetterRequiresNativeActualStateRatherThanPreferenceAlone() {
        let runtime = Runtime()
        runtime.applyActual = false
        var pauses = 0
        let driver = SystemDisplayHDRDriver(runtime: runtime, attempts: 3, resolve: { target, _ in target }, pause: { pauses += 1 })
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertEqual(runtime.writes, [42])
        XCTAssertEqual(runtime.reads.count, 4)
        XCTAssertEqual(pauses, 2)
    }

    func testExplicitRecoveryCanRestoreOriginalAfterPartiallyAppliedTransition() throws {
        let runtime = Runtime()
        runtime.applyActual = false
        let driver = SystemDisplayHDRDriver(runtime: runtime, attempts: 1, resolve: { target, _ in target })
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertThrowsError(try driver.setHDR(false, for: target, active: { true }))
        runtime.applyActual = true
        XCTAssertFalse(try driver.restoreHDR(false, for: target, active: { true }))
        XCTAssertEqual(runtime.value, .init(supported: true, enabled: false, preferred: false))
        XCTAssertEqual(runtime.writes, [42, 42])
    }

    func testRecoveryStillRejectsReusedNumericIDBeforeRuntimeAccess() {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { _, allowReassignment in
            XCTAssertFalse(allowReassignment)
            throw DisplayHDRError.disconnected
        })
        XCTAssertThrowsError(try driver.restoreHDR(false, for: target, active: { true }))
        XCTAssertTrue(runtime.reads.isEmpty)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testSwitchVerifiesNativeStateWithFreshUUIDResolvedNumericID() throws {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, reassigned in
            DisplayHardwareTarget(uuid: target.uuid, displayID: reassigned ? 84 : target.displayID, isBuiltin: false)
        })
        XCTAssertTrue(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertEqual(runtime.writes, [42])
        XCTAssertEqual(runtime.reads, [42, 84])
    }

    func testTransientReconfigurationRetriesOnlyReadbackAndNeverWritesAgain() throws {
        let runtime = Runtime()
        var reassignments = 0
        let driver = SystemDisplayHDRDriver(runtime: runtime, attempts: 3, resolve: { target, allow in
            if allow { reassignments += 1; if reassignments == 1 { throw DisplayHDRError.disconnected } }
            return target
        })
        XCTAssertTrue(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertEqual(runtime.writes, [42])
        XCTAssertEqual(reassignments, 2)
    }

    func testDisconnectedOriginalTargetNeverReadsOrWritesPrivateRuntime() {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { _, _ in throw DisplayHDRError.disconnected })
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertTrue(runtime.reads.isEmpty)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testTargetReplacedAfterInitialReadDoesNotMutate() {
        let runtime = Runtime()
        var validations = 0
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in
            validations += 1
            if validations == 2 { throw DisplayHDRError.disconnected }
            return target
        })
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testNoChangeAvoidsUnnecessaryModeSwitch() throws {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        XCTAssertFalse(try driver.setHDR(false, for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testCancellationDoesNotWriteAndStopsReadbackPolling() {
        let runtime = Runtime()
        let driver = SystemDisplayHDRDriver(runtime: runtime, resolve: { target, _ in target })
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { false }))
        XCTAssertTrue(runtime.writes.isEmpty)
        XCTAssertThrowsError(try driver.setHDR(true, for: target, active: { runtime.writes.isEmpty }))
        XCTAssertEqual(runtime.writes, [42])
        XCTAssertEqual(runtime.reads, [42])
    }

    private final class Runtime: DisplayHDRRuntime {
        var value: DisplayHDRNativeState? = .init(supported: true, enabled: false, preferred: false)
        var applyActual = true
        var readError: Error?
        var reads: [UInt32] = []
        var writes: [UInt32] = []
        func state(_ target: DisplayHardwareTarget) throws -> DisplayHDRNativeState? {
            if let readError { throw readError }
            reads.append(target.displayID)
            return value
        }
        func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) throws {
            writes.append(target.displayID)
            value = .init(supported: true, enabled: applyActual ? enabled : value!.enabled, preferred: enabled)
        }
    }

    private final class BlockingRuntime: DisplayHDRRuntime {
        let gate = DispatchSemaphore(value: 0)
        func state(_ target: DisplayHardwareTarget) throws -> DisplayHDRNativeState? {
            _ = gate.wait(timeout: .now() + 2)
            return .init(supported: true, enabled: false, preferred: false)
        }
        func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) throws { XCTFail("No write after a timeout") }
    }
}
