import XCTest
@testable import NotchApp

@MainActor
final class DisplayAdvancedFeatureModelTests: XCTestCase {
    func testReferenceSelectionKeepsNativeResultWithoutPlaceholderCGChangeOrConfirmation() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.selectReferencePreset("cinema", for: f.display)

        XCTAssertEqual(f.model.referencePresetState(for: f.display)?.selectedID, "cinema")
        XCTAssertEqual(f.profiles.selectedID, "native")
        XCTAssertTrue(f.profiles.writes.isEmpty, "A successful native preset retains its own ColorSync profile")
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertEqual(f.configuration.restoreCount, 0)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.isApplyingPreset)
        XCTAssertFalse(f.controller.isPresented)
        let restores = await f.reference.restores()
        XCTAssertTrue(restores.isEmpty)
        await f.cleanup()
    }

    func testFailedReferenceSelectionRestoresOriginalBeforeConfigurationAndProfiles() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        f.model.setDimming(0.7, for: f.display)
        await f.reference.configure(failSelect: true)
        await f.model.selectReferencePreset("cinema", for: f.display)

        let selected = await f.reference.current(), restored = await f.reference.restores()
        XCTAssertEqual(selected, "xdr")
        XCTAssertEqual(restored, ["xdr"])
        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertEqual(f.profiles.selectedID, "original")
        XCTAssertEqual(f.model.dimming(for: f.display), 0.7, accuracy: 0.001)
        XCTAssertEqual(f.gamma.values.last, 0.7)
        XCTAssertFalse(f.model.isPending)
        XCTAssertNotNil(f.model.errorMessage)
        if let reference = f.log.events.firstIndex(of: "reference.restore"),
           let configuration = f.log.events.firstIndex(of: "configuration.restore"),
           let profile = f.log.events.firstIndex(of: "profile.write") {
            XCTAssertLessThan(reference, configuration)
            XCTAssertLessThan(reference, profile)
        } else { XCTFail("Recovery must restore all three captured layers") }
        await f.cleanup()
    }

    func testStopDuringHeldReferenceWriteWaitsThenRestoresOriginal() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.reference.holdNextSelect()
        let operation = Task { await f.model.selectReferencePreset("cinema", for: f.display) }
        await waitUntil { await f.reference.isSelectHeld }
        XCTAssertTrue(f.model.isApplyingPreset)
        f.model.stop()
        await f.reference.completeSelect()
        await operation.value
        await f.model.waitForOperations()

        let selected = await f.reference.current(), restored = await f.reference.restores()
        XCTAssertEqual(selected, "xdr")
        XCTAssertEqual(restored, ["xdr"])
        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertEqual(f.profiles.selectedID, "original")
        XCTAssertFalse(f.model.enabled)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.controller.isPresented)
        await f.cleanup()
    }

    func testFailedReferenceRecoveryRetainsRetryAndIgnoresConfirm() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.reference.configure(failSelect: true, failRestore: true)
        await f.model.selectReferencePreset("cinema", for: f.display)
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.model.rollbackFailed)
        XCTAssertFalse(f.controller.isPresented)
        let before = await f.reference.selections()
        f.model.confirmChange()
        await f.model.waitForOperations()
        let after = await f.reference.selections()
        XCTAssertEqual(after, before)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertTrue(f.model.isPending)

        await f.reference.configure(failRestore: false)
        f.model.cancelChange()
        await f.model.waitForOperations()
        let selected = await f.reference.current()
        XCTAssertEqual(selected, "xdr")
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.rollbackFailed)
        await f.cleanup()
    }

    func testReferenceSelectionRejectsReusedNumericIDBeforeNativeWrite() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        f.configuration.connected = [f.remapped(uuid: "different-screen", displayID: f.display.displayID)]
        await f.model.selectReferencePreset("cinema", for: f.display)
        let selections = await f.reference.selections()
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(f.configuration.snapshotCount, 0)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        await f.cleanup()
    }

    func testOldIDAdvancedReadCannotOverwriteRemappedUUIDCache() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.refreshAdvancedSettings()
        await waitUntil { f.model.referencePresetState(for: f.display)?.selectedID == "xdr" }
        await f.reference.holdNextRead(displayID: f.display.displayID)
        let obsolete = Task { await f.model.refreshAdvancedSettings() }
        await waitUntil { await f.reference.isReadHeld }
        let remapped = f.remapped(uuid: f.display.id, displayID: 84)
        await f.reference.setReadValue("cinema", displayID: remapped.displayID)
        f.configuration.connected = [remapped]
        f.model.refresh()
        await f.model.refreshAdvancedSettings()
        await f.reference.completeRead()
        await obsolete.value
        await waitUntil { await f.reference.readIDs().contains(84) }
        let readIDs = await f.reference.readIDs()
        // A remap can coalesce one final refresh after publishing the new cached value.
        // Read both UI predicates together after the last actor hop.
        await waitUntil {
            f.model.referencePresetState(for: remapped)?.selectedID == "cinema" &&
                !f.model.isAdvancedSettingsLoading(for: remapped)
        }
        XCTAssertTrue(readIDs.contains(84))
        XCTAssertEqual(f.model.referencePresetState(for: remapped)?.selectedID, "cinema")
        XCTAssertFalse(f.model.isAdvancedSettingsLoading(for: remapped))
        await f.cleanup()
    }

    func testSmoothDiscoveryNeverInstallsAndExplicitCommandReturnsReconnectState() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.refreshAdvancedSettings()
        await waitUntil { f.model.smoothScalingState(for: f.display) != nil }
        let before = await f.smooth.writes()
        XCTAssertTrue(before.isEmpty)
        await f.model.setSmoothScaling(true, for: f.display)

        let writes = await f.smooth.writes()
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(f.model.smoothScalingState(for: f.display)?.isEnabled, true)
        XCTAssertEqual(f.model.smoothScalingState(for: f.display)?.needsReconnect, true)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.controller.isPresented)
        await f.cleanup()
    }

    func testSmoothMutationIsBlockedByPendingTrialAndConcurrentOperation() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        f.model.request(.mode(displayID: f.display.displayID, modeID: 2), display: f.display)
        XCTAssertTrue(f.model.isPending)
        await f.model.setSmoothScaling(true, for: f.display)
        var writes = await f.smooth.writes()
        XCTAssertTrue(writes.isEmpty)
        f.model.cancelChange()
        await f.model.waitForOperations()

        await f.reference.holdNextSelect()
        let operation = Task { await f.model.selectReferencePreset("cinema", for: f.display) }
        await waitUntil { await f.reference.isSelectHeld }
        await f.model.setSmoothScaling(true, for: f.display)
        writes = await f.smooth.writes()
        XCTAssertTrue(writes.isEmpty)
        await f.reference.completeSelect()
        await operation.value
        await f.cleanup()
    }

    func testStopDuringSmoothInstallationDoesNotPromptAgainToUndoPersistentIntent() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.smooth.holdNextWrite()
        let operation = Task { await f.model.setSmoothScaling(true, for: f.display) }
        await waitUntil { await f.smooth.isHolding }
        f.model.stop()
        await f.smooth.completeWrite()
        await operation.value
        await f.model.waitForOperations()

        let writes = await f.smooth.writes(), enabled = await f.smooth.currentValue()
        XCTAssertEqual(writes, [true], "Stopping must not issue a second administrator operation")
        XCTAssertTrue(enabled)
        XCTAssertFalse(f.model.enabled)
        XCTAssertFalse(f.model.isApplyingPreset)
        XCTAssertFalse(f.model.isPending)
        await f.cleanup()
    }

    func testSmoothMutationRejectsOldUUIDIDAfterRefreshAndWhenStopped() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        f.configuration.connected = [f.remapped(uuid: f.display.id, displayID: 84)]
        f.model.refresh()
        await f.model.setSmoothScaling(true, for: f.display)
        f.model.stop()
        await f.model.setSmoothScaling(true, for: f.configuration.connected[0])
        let writes = await f.smooth.writes()
        XCTAssertTrue(writes.isEmpty)
        await f.cleanup()
    }

    func testReferenceFailureRestoresFreshHardwareBrightnessInsteadOfOlderUICache() async {
        let hardware = AdvancedModelHardware(value: 0.8)
        let f = Fixture(hardware: hardware)
        defer { f.scheduleCleanup() }
        f.model.start()
        await waitUntil { f.model.isHardwareBrightness(for: f.display) }
        XCTAssertEqual(f.model.dimming(for: f.display), 0.8, accuracy: 0.001)
        await hardware.setValue(0.4)
        await f.reference.configure(failSelect: true)
        await f.model.selectReferencePreset("cinema", for: f.display)

        let writes = await hardware.writes()
        XCTAssertEqual(writes.last, 0.4, "Recovery must capture actual brightness changed outside the app")
        XCTAssertFalse(writes.contains(0.8), "A stale UI cache must never overwrite newer hardware brightness")
        XCTAssertEqual(f.profiles.selectedID, "original")
        XCTAssertFalse(f.model.isPending)
        await f.cleanup()
    }

    func testFreshHardwareReadFailureAbortsBeforeReferenceSelection() async {
        let hardware = AdvancedModelHardware(value: 0.8)
        let f = Fixture(hardware: hardware)
        defer { f.scheduleCleanup() }
        f.model.start()
        await waitUntil { f.model.isHardwareBrightness(for: f.display) }
        await hardware.setReadFailure(true)
        await f.model.selectReferencePreset("cinema", for: f.display)

        let selections = await f.reference.selections(), writes = await hardware.writes()
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertEqual(f.configuration.restoreCount, 0)
        XCTAssertFalse(f.model.isPending)
        XCTAssertNotNil(f.model.errorMessage)
        await f.cleanup()
    }

    func testReferencePresetAutoBrightnessCapabilityBlocksWritesAndReenablesReads() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.selectReferencePreset("cinema", for: f.display)
        await f.systemModel.refresh()
        XCTAssertNil(f.systemModel.autoBrightness(for: f.display).value)
        XCTAssertNotNil(f.systemModel.autoBrightness(for: f.display).unavailableReason)
        await f.systemModel.setAutoBrightness(true, for: f.display)
        let writes = await f.systemService.writeCount()
        XCTAssertEqual(writes, 0, "Known native preset metadata must block unsupported auto-brightness writes")

        await f.model.selectReferencePreset("xdr", for: f.display)
        await f.systemModel.refresh()
        XCTAssertEqual(f.systemModel.autoBrightness(for: f.display).value, false,
                       "Selecting a preset that allows auto brightness restores the native reading")
        await f.cleanup()
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Advanced display model did not reach expected state")
    }

    @MainActor
    private final class Fixture {
        let suite = "DisplayAdvancedFeatureModelTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let display: DisplayInfo
        let configuration: AdvancedModelConfiguration
        let log = AdvancedModelLog()
        let profiles: AdvancedModelProfiles
        let gamma = AdvancedModelGamma()
        let reference: AdvancedModelReference
        let smooth = AdvancedModelSmoothScaling()
        let systemService = AdvancedModelSystem()
        let systemModel: DisplaySystemSettingsModel
        let controller = DisplayRevertController(showsWindow: false)
        let model: DisplayFeatureModel

        init(hardware: AdvancedModelHardware? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let modes = [DisplayModeOption(id: 1, width: 1800, height: 1200, pixelWidth: 3600, pixelHeight: 2400, refreshRate: 120),
                         DisplayModeOption(id: 2, width: 1500, height: 1000, pixelWidth: 3000, pixelHeight: 2000, refreshRate: 120)]
            display = DisplayInfo(id: "builtin-xdr", displayID: 42, name: "Test XDR", isBuiltin: true, isMain: true,
                                  mirrorMasterID: nil, modes: modes, currentMode: modes[0],
                                  frame: CGRect(x: 0, y: 0, width: 1800, height: 1200))
            configuration = AdvancedModelConfiguration(display: display, log: log)
            profiles = AdvancedModelProfiles(log: log)
            systemModel = DisplaySystemSettingsModel(service: systemService)
            let profiles = profiles
            reference = AdvancedModelReference(log: log) { profiles.selectedID = "native" }
            model = DisplayFeatureModel(service: configuration, brightness: gamma, defaults: defaults,
                                        revertController: controller, hardware: hardware, colorProfiles: profiles, systemSettings: systemModel,
                                        referencePresets: reference, smoothScaling: smooth)
        }

        func remapped(uuid: String, displayID: UInt32) -> DisplayInfo {
            DisplayInfo(id: uuid, displayID: displayID, name: display.name, isBuiltin: display.isBuiltin,
                        isMain: display.isMain, mirrorMasterID: nil, modes: display.modes, currentMode: display.currentMode, frame: display.frame)
        }

        func cleanup() async {
            await reference.configure(failRestore: false)
            await reference.completeSelect()
            await reference.completeRead()
            await smooth.completeWrite()
            model.stop()
            await model.waitForOperations()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        func scheduleCleanup() { Task { await cleanup() } }
    }
}

@MainActor
private final class AdvancedModelLog {
    var events: [String] = []
}

private actor AdvancedModelReference: DisplayReferencePresetServing {
    private var value = "xdr"
    private var selected: [String] = []
    private var restored: [String] = []
    private var failSelect = false
    private var failRestore = false
    private var holdSelect = false
    private var pendingSelect: CheckedContinuation<Void, Never>?
    private var heldReadID: UInt32?
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var valuesByID: [UInt32: String] = [:]
    private var reads: [UInt32] = []
    private let log: AdvancedModelLog
    private let didSelect: @MainActor @Sendable () -> Void
    init(log: AdvancedModelLog, didSelect: @escaping @MainActor @Sendable () -> Void) {
        self.log = log; self.didSelect = didSelect
    }
    func read(_ target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState? {
        reads.append(target.displayID)
        let captured = state(selectedID: valuesByID[target.displayID] ?? value)
        if heldReadID == target.displayID {
            heldReadID = nil
            await withCheckedContinuation { pendingRead = $0 }
        }
        return captured
    }
    func select(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState {
        selected.append(presetID)
        if holdSelect { holdSelect = false; await withCheckedContinuation { pendingSelect = $0 } }
        value = presetID
        await didSelect()
        if failSelect { throw DisplayReferencePresetError.notApplied }
        return state(selectedID: value)
    }
    func restore(_ presetID: String, for target: DisplayHardwareTarget) async throws -> DisplayReferencePresetState {
        restored.append(presetID)
        await MainActor.run { log.events.append("reference.restore") }
        if failRestore { throw DisplayReferencePresetError.recoveryFailed }
        value = presetID
        return state(selectedID: value)
    }
    private func state(selectedID: String) -> DisplayReferencePresetState {
        .init(options: [.init(id: "xdr", name: "Apple XDR Display", allowsNightShift: true, allowsAutoBrightness: true),
                        .init(id: "cinema", name: "Cinema", allowsNightShift: false, allowsAutoBrightness: false)], selectedID: selectedID)
    }
    func configure(failSelect: Bool? = nil, failRestore: Bool? = nil) {
        if let failSelect { self.failSelect = failSelect }; if let failRestore { self.failRestore = failRestore }
    }
    func holdNextSelect() { holdSelect = true }
    func completeSelect() { let continuation = pendingSelect; pendingSelect = nil; continuation?.resume() }
    var isSelectHeld: Bool { pendingSelect != nil }
    func holdNextRead(displayID: UInt32) { heldReadID = displayID }
    func completeRead() { let continuation = pendingRead; pendingRead = nil; continuation?.resume() }
    var isReadHeld: Bool { pendingRead != nil }
    func setReadValue(_ value: String, displayID: UInt32) { valuesByID[displayID] = value }
    func readIDs() -> [UInt32] { reads }
    func current() -> String { value }
    func selections() -> [String] { selected }
    func restores() -> [String] { restored }
}

private actor AdvancedModelSmoothScaling: DisplaySmoothScalingServing {
    private var enabled = false
    private var requested: [Bool] = []
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    func read(_ target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState? { state }
    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> DisplaySmoothScalingState {
        requested.append(enabled)
        if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        self.enabled = enabled
        return state
    }
    private var state: DisplaySmoothScalingState {
        .init(isEnabled: enabled, canModify: true, needsReconnect: enabled, detail: enabled ? "Переподключите дисплей" : "")
    }
    func holdNextWrite() { hold = true }
    func completeWrite() { let continuation = pending; pending = nil; continuation?.resume() }
    var isHolding: Bool { pending != nil }
    func writes() -> [Bool] { requested }
    func currentValue() -> Bool { enabled }
}

private actor AdvancedModelHardware: DisplayHardwareBrightnessServing {
    private var value: Double
    private var failRead = false
    private var requested: [Double] = []
    init(value: Double) { self.value = value }
    func read(_ target: DisplayHardwareTarget) async throws -> DisplayHardwareBrightnessReading? {
        if failRead { throw ReadFailure() }
        return .init(value: value, backend: .ddc)
    }
    func write(_ value: Double, to target: DisplayHardwareTarget, backend: DisplayHardwareBackend) async throws {
        requested.append(value)
        self.value = value
    }
    func setValue(_ value: Double) { self.value = value }
    func setReadFailure(_ fail: Bool) { failRead = fail }
    func writes() -> [Double] { requested }
    private struct ReadFailure: LocalizedError {
        var errorDescription: String? { "Fresh hardware read failed" }
    }
}

private actor AdvancedModelSystem: DisplaySystemSettingsServing {
    private var requestedWrites = 0
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? { false }
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        requestedWrites += 1
        return enabled
    }
    func writeCount() -> Int { requestedWrites }
}

@MainActor
private final class AdvancedModelConfiguration: DisplayConfigurationServing {
    var connected: [DisplayInfo]
    var applied: [DisplayChange] = []
    var restoreCount = 0
    var snapshotCount = 0
    let original: DisplayInfo
    let log: AdvancedModelLog
    init(display: DisplayInfo, log: AdvancedModelLog) { connected = [display]; original = display; self.log = log }
    func displays() throws -> [DisplayInfo] { connected }
    func apply(_ change: DisplayChange, permanently: Bool) throws { applied.append(change) }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        snapshotCount += 1
        return .init(entries: [.init(displayID: original.displayID, uuid: original.id, mode: nil,
                                    origin: original.frame.origin, mirrorMasterID: nil, mirrorMasterUUID: nil)])
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {
        restoreCount += 1
        log.events.append("configuration.restore")
        connected = [original]
    }
}

@MainActor
private final class AdvancedModelProfiles: DisplayColorProfileServing {
    var selectedID = "original"
    var writes: [String] = []
    let log: AdvancedModelLog
    init(log: AdvancedModelLog) { self.log = log }
    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState {
        .init(options: [.init(id: "original", name: "Original"), .init(id: "native", name: "Native")], selectedID: selectedID)
    }
    func setProfile(_ profileID: String, for display: DisplayInfo) async throws {
        writes.append(profileID); selectedID = profileID; log.events.append("profile.write")
    }
}

@MainActor
private final class AdvancedModelGamma: DisplayBrightnessServing {
    var values: [Double] = []
    func setDimming(_ factor: Double, displayID: UInt32) throws { values.append(factor) }
    func invalidate() {}
    func restore() {}
}
