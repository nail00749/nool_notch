import XCTest
@testable import NotchApp

final class DisplayReferencePresetServiceTests: XCTestCase {
    private let target = DisplayHardwareTarget(uuid: "reference", displayID: 42, isBuiltin: true)

    func testNativeIdentityRequiresExactly16BytesAndNeverUsesNamesOrSlotIndices() {
        let a = DisplayReferencePresetCatalog.identifier(Data(repeating: 1, count: 16))
        XCTAssertEqual(a, "native:" + String(repeating: "01", count: 16))
        XCTAssertNotEqual(a, DisplayReferencePresetCatalog.identifier(Data(repeating: 2, count: 16)))
        XCTAssertNil(DisplayReferencePresetCatalog.identifier(Data(repeating: 1, count: 15)))
        XCTAssertNil(DisplayReferencePresetCatalog.identifier("0"))
        XCTAssertNil(DisplayReferencePresetCatalog.identifier(NSNumber(value: 0)))
    }

    func testInvalidWritableSlotsAreIgnoredWhileValidMissingIdentityFailsClosed() throws {
        XCTAssertNil(try DisplayReferencePresetCatalog.option(isValid: false, uniqueID: nil, name: "Empty slot", metadata: [:]))
        XCTAssertThrowsError(try DisplayReferencePresetCatalog.option(isValid: true, uniqueID: nil, name: "Preset", metadata: [:]))
    }

    func testKnownNumericRestrictionFlagsAndUnknownMetadataRemainDistinct() throws {
        let option = try XCTUnwrap(DisplayReferencePresetCatalog.option(isValid: true,
            uniqueID: Data(repeating: 3, count: 16), name: "Reference", metadata: [
                "PresetHostDisableNightShift": NSNumber(value: 1), "PresetHostDisableAutoBrightness": NSNumber(value: 0)]))
        XCTAssertEqual(option.allowsNightShift, false)
        XCTAssertEqual(option.allowsAutoBrightness, true)
        XCTAssertNil(DisplayReferencePresetCatalog.allowed(disabled: "false"))
        XCTAssertNil(DisplayReferencePresetCatalog.allowed(disabled: NSNumber(value: 2)))
        XCTAssertNil(DisplayReferencePresetCatalog.allowed(disabled: nil))
    }

    func testDuplicateOrMissingSelectedIDRejectsUnreadableCatalog() {
        let a = DisplayReferencePresetOption(id: "a", name: "A")
        XCTAssertThrowsError(try DisplayReferencePresetCatalog.state(options: [a, a], selectedID: "a"))
        XCTAssertThrowsError(try DisplayReferencePresetCatalog.state(options: [a], selectedID: "missing"))
        XCTAssertThrowsError(try DisplayReferencePresetCatalog.state(options: [], selectedID: "a"))
    }

    func testDefaultCatalogIsReadWithoutMutatingNativeSelection() throws {
        let runtime = Runtime(), driver = driver(runtime)
        let state = try driver.read(target)
        XCTAssertEqual(state?.selectedID, "original")
        XCTAssertEqual(state?.options.count, 2)
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testUnsupportedAndUncataloguedSelectionsNeverWrite() throws {
        let runtime = Runtime(), driver = driver(runtime)
        runtime.unsupported = true
        XCTAssertNil(try driver.read(target))
        XCTAssertThrowsError(try driver.select("other", for: target, active: { true }))
        runtime.unsupported = false
        XCTAssertThrowsError(try driver.select("unknown", for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testNativeFalseSetterAfterPartialMutationRestoresCapturedOriginal() {
        let runtime = Runtime(), driver = driver(runtime)
        runtime.failNextWrite = true
        XCTAssertThrowsError(try driver.select("other", for: target, active: { true }))
        XCTAssertEqual(runtime.selected, "original")
        XCTAssertEqual(runtime.writes, ["other", "original"])
    }

    func testUnconfirmedReadbackRestoresOriginalWithBoundedAttempts() {
        let runtime = Runtime(), driver = driver(runtime)
        runtime.ignoreDesired = true
        XCTAssertThrowsError(try driver.select("other", for: target, active: { true }))
        XCTAssertEqual(runtime.selected, "original")
        XCTAssertEqual(runtime.writes, ["other"])
        XCTAssertLessThanOrEqual(runtime.readCount, 5)
    }

    func testCancellationAfterNativeWriteRestoresBeforeReturning() {
        let runtime = Runtime(), driver = driver(runtime)
        XCTAssertThrowsError(try driver.select("other", for: target, active: { runtime.writes.isEmpty })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(runtime.selected, "original")
        XCTAssertEqual(runtime.writes, ["other", "original"])
    }

    func testFailedRecoveryRemainsAnExplicitRecoveryFailure() {
        let runtime = Runtime(), driver = driver(runtime)
        runtime.failNextWrite = true
        runtime.failRecovery = true
        XCTAssertThrowsError(try driver.select("other", for: target, active: { true })) { error in
            guard case DisplayReferencePresetError.recoveryFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(runtime.writes, ["other", "original"])
    }

    func testIdentityFailureBeforeWriteCannotSelectAnything() {
        let runtime = Runtime()
        let driver = SystemDisplayReferencePresetDriver(runtime: runtime, resolve: { _, _ in throw DisplayReferencePresetError.disconnected })
        XCTAssertThrowsError(try driver.select("other", for: target, active: { true }))
        XCTAssertTrue(runtime.writes.isEmpty)
    }

    func testReadbackFollowsUniqueUUIDRemappingWithoutRepeatingWrite() throws {
        let runtime = Runtime()
        let driver = SystemDisplayReferencePresetDriver(runtime: runtime, resolve: { target, follow in
            .init(uuid: target.uuid, displayID: follow ? 84 : target.displayID, isBuiltin: target.isBuiltin)
        })
        XCTAssertEqual(try driver.select("other", for: target, active: { true }).selectedID, "other")
        XCTAssertEqual(runtime.writeIDs, [42])
        XCTAssertTrue(runtime.readIDs.contains(84))
    }

    @MainActor
    func testAsyncServiceCancellationAwaitsIndependentRecovery() async {
        let runtime = Runtime()
        runtime.writeStarted = DispatchSemaphore(value: 0)
        runtime.writeGate = DispatchSemaphore(value: 0)
        let service = DynamicDisplayReferencePresetService(driver: driver(runtime))
        let target = target
        let selecting = Task { try await service.select("other", for: target) }
        for _ in 0..<1000 {
            if runtime.consumeWriteStarted() { break }
            await Task.yield()
        }
        selecting.cancel()
        runtime.writeGate!.signal()
        do { _ = try await selecting.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(runtime.selected, "original")
        XCTAssertEqual(runtime.writes, ["other", "original"])
    }

    private func driver(_ runtime: Runtime) -> SystemDisplayReferencePresetDriver {
        .init(runtime: runtime, attempts: 2, resolve: { target, _ in target })
    }

    private final class Runtime: DisplayReferencePresetRuntime {
        var selected = "original"
        var writes: [String] = []
        var writeIDs: [UInt32] = []
        var readIDs: [UInt32] = []
        var readCount = 0
        var unsupported = false
        var failNextWrite = false
        var failRecovery = false
        var ignoreDesired = false
        var writeStarted: DispatchSemaphore?
        var writeGate: DispatchSemaphore?
        func consumeWriteStarted() -> Bool { writeStarted?.wait(timeout: .now()) == .success }
        func state(_ target: DisplayHardwareTarget) throws -> DisplayReferencePresetState? {
            readCount += 1; readIDs.append(target.displayID)
            if unsupported { return nil }
            return .init(options: [.init(id: "original", name: "Default"), .init(id: "other", name: "Other")], selectedID: selected)
        }
        func select(_ id: String, for target: DisplayHardwareTarget) throws {
            writes.append(id); writeIDs.append(target.displayID)
            if id == "other" { writeStarted?.signal(); _ = writeGate?.wait(timeout: .now() + 2) }
            if id == "original", failRecovery { throw DisplayReferencePresetError.notApplied }
            if !ignoreDesired || id == "original" { selected = id }
            if failNextWrite { failNextWrite = false; throw DisplayReferencePresetError.notApplied }
        }
    }
}
