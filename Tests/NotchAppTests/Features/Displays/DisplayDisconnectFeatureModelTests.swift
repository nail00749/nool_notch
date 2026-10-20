import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class DisplayDisconnectFeatureModelTests: XCTestCase {
    func testPartiallyAppliedPowerFailureRestoresSnapshotWithoutPromotingIntent() async {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.model.start()
        f.configuration.failApplyAfterMutation = true
        f.model.setDisplayEnabled(false, for: f.external)

        XCTAssertEqual(f.configuration.applied, [.enabled(displayID: f.external.displayID, enabled: false)])
        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertTrue(f.configuration.connected[1].isEnabled)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.rollbackFailed)
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        XCTAssertEqual(f.model.errorMessage, "Power commit failed after mutation")
        await f.cleanup()
    }

    func testPartialPowerFailureRetainsRecoveryWhenRestoreFailsAndCancelCanRetry() async {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.model.start()
        f.configuration.failApplyAfterMutation = true
        f.configuration.failRestore = true
        f.model.setDisplayEnabled(false, for: f.external)

        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertFalse(f.configuration.connected[1].isEnabled)
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.model.rollbackFailed)
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        XCTAssertTrue(f.model.errorMessage?.contains("Power commit failed after mutation") == true)
        XCTAssertTrue(f.model.errorMessage?.contains("Snapshot restore failed") == true)

        f.configuration.failRestore = false
        f.model.cancelChange()
        await f.model.waitForOperations()
        XCTAssertEqual(f.configuration.restoreCount, 2)
        XCTAssertTrue(f.configuration.connected[1].isEnabled)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.rollbackFailed)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        await f.cleanup()
    }

    func testManualDisconnectDoesNotPromoteIntentUntilConfirmation() async {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.model.start()
        f.model.setDisplayEnabled(false, for: f.external)
        XCTAssertTrue(f.model.isPending)
        XCTAssertEqual(f.controller.secondsRemaining, 15)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        f.controller.confirm()
        XCTAssertFalse(f.model.isPending)
        XCTAssertEqual(f.configuration.confirmations, ["external": false])
        XCTAssertTrue(f.model.isKeptDisconnected(for: f.external))
        await f.cleanup()
    }

    func testCancelledPowerTrialPreservesOriginalDisconnectIntent() async {
        let f = Fixture(disabled: true, kept: true)
        defer { f.cleanupLater() }
        f.model.start()
        f.model.setDisplayEnabled(true, for: f.external)
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.contains("external"))
        f.controller.revert()
        XCTAssertFalse(f.model.isPending)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.contains("external"))
        XCTAssertFalse(f.configuration.connected[1].isEnabled)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        await f.cleanup()
    }

    func testExplicitEnableClearsIntentOnlyAfterConfirmation() async {
        let f = Fixture(disabled: true, kept: true)
        defer { f.cleanupLater() }
        f.model.start()
        f.model.setDisplayEnabled(true, for: f.external)
        XCTAssertTrue(f.model.isKeptDisconnected(for: f.external))
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        f.controller.confirm()
        XCTAssertFalse(f.model.isKeptDisconnected(for: f.external))
        XCTAssertEqual(f.configuration.confirmations, ["external": true])
        await f.cleanup()
    }

    func testPresetTrialDoesNotCommitIntentAndConfirmationUsesSingleAtomicBatch() async throws {
        let f = Fixture()
        defer { f.cleanupLater() }
        let id = try f.installDisconnectPreset()
        f.recreateModel()
        f.model.start()
        await f.model.applyPreset(id: id)
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.configuration.batches.isEmpty)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        f.controller.confirm()
        await f.model.waitForOperations()
        XCTAssertEqual(f.configuration.batches, [["builtin": true, "external": false]])
        XCTAssertTrue(f.configuration.confirmations.isEmpty, "Preset confirmation must use the batch boundary")
        XCTAssertTrue(f.model.isKeptDisconnected(for: f.external))
        await f.cleanup()
    }

    func testFailedAtomicPresetConfirmationRestoresConfigurationWithoutPartialIntent() async throws {
        let f = Fixture()
        defer { f.cleanupLater() }
        let id = try f.installDisconnectPreset()
        f.recreateModel()
        f.model.start()
        await f.model.applyPreset(id: id)
        f.configuration.failBatch = true
        f.controller.confirm()
        await f.model.waitForOperations()
        XCTAssertFalse(f.model.isPending)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.isEmpty)
        XCTAssertTrue(f.configuration.connected[1].isEnabled)
        XCTAssertTrue(f.configuration.confirmations.isEmpty)
        XCTAssertNotNil(f.model.errorMessage)
        await f.cleanup()
    }

    func testPendingAndStandaloneAsyncBusyStateBlockPolicyChangesAndReconciliation() async {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.model.start()
        f.model.setDisplayEnabled(false, for: f.external)
        let duringTrial = f.configuration.reconcileCount
        f.model.setDisconnectPolicy(.restoreOnExit)
        f.model.refresh()
        XCTAssertEqual(f.configuration.disconnectPolicy, .keepDisabled)
        XCTAssertEqual(f.configuration.reconcileCount, duringTrial)
        f.controller.revert()
        await f.model.refreshColorProfiles()
        f.profiles.holdNextSet = true
        let changing = Task { await f.model.selectColorProfile("alternate", for: f.external) }
        for _ in 0..<1000 where f.profiles.pendingSet == nil { await Task.yield() }
        XCTAssertNotNil(f.profiles.pendingSet)
        XCTAssertTrue(f.model.isApplyingPreset)
        XCTAssertFalse(f.model.isPending)
        let duringBusy = f.configuration.reconcileCount
        f.model.setDisconnectPolicy(.restoreOnExit)
        f.model.refresh()
        XCTAssertEqual(f.configuration.disconnectPolicy, .keepDisabled)
        XCTAssertEqual(f.configuration.reconcileCount, duringBusy)
        f.profiles.release()
        await changing.value
        await f.cleanup()
    }

    func testModuleStopDelegatesRestorationWithoutForceEnablingKeptDisplay() async {
        let f = Fixture(disabled: true, kept: true)
        defer { f.cleanupLater() }
        f.model.start()
        f.model.stop()
        XCTAssertEqual(f.configuration.restoreManagedCount, 1)
        XCTAssertFalse(f.configuration.connected[1].isEnabled)
        XCTAssertTrue(f.configuration.keptDisconnectedUUIDs.contains("external"))
        XCTAssertTrue(f.configuration.applied.isEmpty)
        await f.cleanup()
    }

    func testReconciliationStopsCursorAndExtraBeforeNativeChangeAndRereadsFreshStateEvenOnError() async {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.cursor.setEnabled(true)
        f.model.start()
        await f.model.setExtraBrightness(true, for: f.external)
        XCTAssertTrue(f.cursorSpy.isRunning)
        XCTAssertTrue(f.extra.active)
        f.configuration.nextReconcile = {
            XCTAssertFalse(f.cursorSpy.isRunning)
            XCTAssertFalse(f.extra.active)
            f.configuration.setPower("external", false)
        }
        f.configuration.failReconcileAfterChange = true
        f.model.refresh()
        XCTAssertEqual(f.model.displays.first(where: { $0.id == "external" })?.isEnabled, false)
        XCTAssertEqual(f.model.errorMessage, "Reconciliation failed")
        XCTAssertEqual(f.configuration.changedReconcileCount, 1)
        await f.cleanup()
    }

    func testSleepSkipsReconcileAndWakeResetsAttemptsBeforeFreshReconcile() async throws {
        let f = Fixture()
        defer { f.cleanupLater() }
        f.model.start()
        XCTAssertGreaterThan(f.configuration.reconcileCount, 0)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        let sleeping = f.configuration.reconcileCount
        f.model.refresh()
        XCTAssertEqual(f.configuration.reconcileCount, sleeping)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<100 where f.configuration.resetCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.configuration.resetCount, 1)
        XCTAssertGreaterThan(f.configuration.reconcileCount, sleeping)
        XCTAssertEqual(f.configuration.lifecycle.suffix(2), ["reset", "reconcile"])
        await f.cleanup()
    }

    func testSafetyEnabledKeepDisplayEnabledClearsIntentWithoutNativeTrial() async {
        let f = Fixture(kept: true)
        defer { f.cleanupLater() }
        f.configuration.safetyEnabledUUIDs = ["external"]
        f.model.start()
        XCTAssertTrue(f.model.isSafetyEnabled(for: f.external))
        XCTAssertTrue(f.model.isKeptDisconnected(for: f.external))
        f.model.keepDisplayEnabled(f.external)
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertEqual(f.configuration.snapshotCount, 0)
        XCTAssertEqual(f.configuration.confirmations, ["external": true])
        XCTAssertFalse(f.model.isKeptDisconnected(for: f.external))
        XCTAssertFalse(f.model.isSafetyEnabled(for: f.external))
        await f.cleanup()
    }

    @MainActor
    private final class Fixture {
        let suite = "DisplayDisconnectFeatureModelTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let external: DisplayInfo
        let builtin: DisplayInfo
        let configuration: DisconnectModelConfiguration
        let profiles = DisconnectModelProfiles()
        let cursorSpy = DisconnectModelCursor()
        let extra = DisconnectModelExtra()
        let controller = DisplayRevertController(showsWindow: false)
        let cursor: DisplayCursorCrossingModel
        var model: DisplayFeatureModel!
        init(disabled: Bool = false, kept: Bool = false) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let mode = DisplayModeOption(id: 1, width: 100, height: 100, pixelWidth: 200, pixelHeight: 200, refreshRate: 60)
            builtin = DisplayInfo(id: "builtin", displayID: 1, name: "Builtin", isBuiltin: true, isMain: true,
                mirrorMasterID: nil, modes: [mode], currentMode: mode, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            external = DisplayInfo(id: "external", displayID: 2, name: "External", isBuiltin: false, isMain: false,
                mirrorMasterID: nil, modes: [mode], currentMode: mode,
                frame: CGRect(x: 100, y: 20, width: 100, height: 60), isEnabled: !disabled)
            configuration = DisconnectModelConfiguration(displays: [builtin, external])
            if kept { configuration.keptDisconnectedUUIDs = ["external"] }
            cursor = DisplayCursorCrossingModel(defaults: defaults, service: cursorSpy)
            recreateModel()
        }
        func recreateModel() {
            model = DisplayFeatureModel(service: configuration, brightness: DisconnectModelGamma(), defaults: defaults,
                revertController: controller, colorProfiles: profiles,
                systemSettings: DisplaySystemSettingsModel(service: UnavailableDisplaySystemSettingsService()),
                extraBrightness: extra, cursorCrossing: cursor)
        }
        func installDisconnectPreset() throws -> UUID {
            let preset = DisplayPreset(name: "Disconnect", displays: [
                .init(stableUUID: builtin.id, isMain: true, useSoftwareBrightness: true),
                .init(stableUUID: external.id, enabled: false, origin: external.frame.origin, useSoftwareBrightness: true)
            ])
            try DisplayPresetStore(defaults: defaults).save([preset])
            return preset.id
        }
        func cleanup() async {
            profiles.release()
            model.stop()
            await model.waitForOperations()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }
        func cleanupLater() { Task { await cleanup() } }
    }
}

private struct DisconnectModelFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
private final class DisconnectModelConfiguration: DisplayConfigurationServing {
    var supportsDisplayPower: Bool { true }
    var disconnectPolicy: DisplayDisconnectPolicy = .keepDisabled
    var keptDisconnectedUUIDs: Set<String> = []
    var safetyEnabledUUIDs: Set<String> = []
    var connected: [DisplayInfo]
    var applied: [DisplayChange] = []
    var confirmations: [String: Bool] = [:]
    var batches: [[String: Bool]] = []
    var snapshotCount = 0
    var restoreCount = 0
    var restoreManagedCount = 0
    var reconcileCount = 0
    var changedReconcileCount = 0
    var resetCount = 0
    var lifecycle: [String] = []
    var failBatch = false
    var failApplyAfterMutation = false
    var failRestore = false
    var failReconcileAfterChange = false
    var nextReconcile: (() -> Void)?
    private var captured: [DisplayInfo] = []
    init(displays: [DisplayInfo]) { connected = displays }
    func displays() throws -> [DisplayInfo] { connected }
    func setPower(_ uuid: String, _ enabled: Bool) {
        guard let index = connected.firstIndex(where: { $0.id == uuid }) else { return }
        let d = connected[index]
        connected[index] = DisplayInfo(id: d.id, displayID: d.displayID, name: d.name, isBuiltin: d.isBuiltin,
            isMain: d.isMain, mirrorMasterID: d.mirrorMasterID, modes: d.modes, currentMode: d.currentMode,
            frame: d.frame, isEnabled: enabled)
    }
    func apply(_ change: DisplayChange, permanently: Bool) throws {
        applied.append(change)
        if case .enabled(let id, let value) = change, let d = connected.first(where: { $0.displayID == id }) { setPower(d.id, value) }
        if failApplyAfterMutation { throw DisconnectModelFailure(errorDescription: "Power commit failed after mutation") }
    }
    func applyPreset(_ preset: DisplayPreset, permanently: Bool) throws {
        for entry in preset.displays { setPower(entry.stableUUID, entry.enabled) }
    }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        snapshotCount += 1
        captured = connected
        return .init(entries: connected.map { .init(displayID: $0.displayID, uuid: $0.id, mode: nil,
            origin: $0.frame.origin, mirrorMasterID: nil, mirrorMasterUUID: nil, isEnabled: $0.isEnabled) })
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {
        restoreCount += 1
        if failRestore { throw DisconnectModelFailure(errorDescription: "Snapshot restore failed") }
        connected = captured
    }
    func restoreManagedDisplays() throws {
        restoreManagedCount += 1
        for d in connected where !d.isEnabled && !keptDisconnectedUUIDs.contains(d.id) { setPower(d.id, true) }
    }
    func setDisconnectPolicy(_ policy: DisplayDisconnectPolicy) throws { disconnectPolicy = policy }
    func confirmPowerState(uuid: String, enabled: Bool) throws {
        confirmations[uuid] = enabled
        updateIntent(uuid, enabled)
    }
    func confirmPowerStates(_ states: [String: Bool]) throws {
        batches.append(states)
        if failBatch { throw DisconnectModelFailure(errorDescription: "Atomic confirmation failed") }
        for (uuid, enabled) in states { updateIntent(uuid, enabled) }
    }
    private func updateIntent(_ uuid: String, _ enabled: Bool) {
        if enabled { keptDisconnectedUUIDs.remove(uuid); safetyEnabledUUIDs.remove(uuid) }
        else if disconnectPolicy == .keepDisabled { keptDisconnectedUUIDs.insert(uuid) }
    }
    func reconcileDisconnectIntents(beforeChanging: @MainActor () -> Void) throws -> Bool {
        reconcileCount += 1
        lifecycle.append("reconcile")
        guard let change = nextReconcile else { return false }
        nextReconcile = nil
        beforeChanging()
        changedReconcileCount += 1
        change()
        if failReconcileAfterChange { throw DisconnectModelFailure(errorDescription: "Reconciliation failed") }
        return true
    }
    func resetDisconnectReconciliationAttempts() { resetCount += 1; lifecycle.append("reset") }
}

@MainActor
private final class DisconnectModelProfiles: DisplayColorProfileServing {
    var holdNextSet = false
    var pendingSet: CheckedContinuation<Void, Never>?
    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState {
        .init(options: [.init(id: "factory", name: "Factory"), .init(id: "alternate", name: "Alternate")], selectedID: "factory")
    }
    func setProfile(_ profileID: String, for display: DisplayInfo) async throws {
        if holdNextSet { holdNextSet = false; await withCheckedContinuation { pendingSet = $0 } }
    }
    func release() { let continuation = pendingSet; pendingSet = nil; continuation?.resume() }
}

@MainActor
private final class DisconnectModelCursor: DisplayCursorCrossingServing {
    var isRunning = false
    var onFailure: (@MainActor (String) -> Void)?
    func start(displays: [DisplayInfo]) throws { isRunning = true }
    func stop() { isRunning = false }
}

@MainActor
private final class DisconnectModelExtra: DisplayExtraBrightnessServing {
    var active = false
    var onStateChange: (@MainActor () -> Void)?
    func capability(for target: DisplayHardwareTarget) -> DisplayExtraBrightnessCapability {
        .init(isSupported: true, isEnabled: active, unavailableReason: nil)
    }
    func setEnabled(_ enabled: Bool, for target: DisplayHardwareTarget) throws { active = enabled }
    func stop() { active = false }
    func reconcile(_ targets: [DisplayHardwareTarget]) {}
}

@MainActor
private final class DisconnectModelGamma: DisplayBrightnessServing {
    func setDimming(_ factor: Double, displayID: UInt32) throws {}
    func invalidate() {}
    func restore() {}
}
