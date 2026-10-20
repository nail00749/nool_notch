import XCTest
@testable import NotchApp

@MainActor
final class DisplayHDRFeatureModelTests: XCTestCase {
    func testRefreshDistinguishesSupportedExternalFromBuiltinXDR() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.refreshHDR()
        for _ in 0..<100 {
            if f.model.hdrState(for: f.external).value != nil,
               f.model.hdrState(for: f.builtin).unavailableReason?.contains("XDR") == true { break }
            await Task.yield()
        }
        XCTAssertEqual(f.model.hdrState(for: f.external).value, false)
        XCTAssertNil(f.model.hdrState(for: f.builtin).value)
        XCTAssertTrue(f.model.hdrState(for: f.builtin).unavailableReason?.contains("XDR") == true)
        await f.cleanup()
    }

    func testConfirmationVerifiesDesiredStateWithoutApplyingPlaceholderMainChange() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.requestHDR(true, for: f.external)
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.controller.isPresented)
        XCTAssertEqual(f.controller.secondsRemaining, 15)
        let current = await f.hdr.current()
        XCTAssertEqual(current, true)
        f.controller.confirm()
        await f.model.waitForOperations()
        XCTAssertFalse(f.model.isPending)
        XCTAssertTrue(f.configuration.applied.isEmpty, "HDR's placeholder DisplayChange must never move the main display")
        XCTAssertEqual(f.configuration.restoreCount, 0)
        XCTAssertTrue(f.profiles.writes.isEmpty, "Keeping HDR must retain its native HDR profile")
        let restores = await f.hdr.restores()
        XCTAssertEqual(restores, [])
        await f.cleanup()
    }

    func testCancelRestoresHDRBeforeModesProfileAndSoftwareAppearance() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        f.model.setDimming(0.7, for: f.external)
        await f.model.requestHDR(true, for: f.external)
        XCTAssertEqual(f.configuration.connected.first?.currentMode?.id, 2)
        XCTAssertEqual(f.profiles.selected[f.external.id], "hdr")
        f.controller.revert()
        await f.model.waitForOperations()
        XCTAssertFalse(f.model.isPending)
        let current = await f.hdr.current()
        XCTAssertEqual(current, false)
        XCTAssertEqual(f.configuration.connected.first?.currentMode?.id, 1)
        XCTAssertEqual(f.profiles.selected[f.external.id], "original")
        XCTAssertEqual(f.model.dimming(for: f.external), 0.7, accuracy: 0.001)
        XCTAssertEqual(f.gamma.values.last(where: { $0.id == f.external.displayID })?.value, 0.7)
        let restore = f.log.events.firstIndex(of: "hdr.restore")!
        XCTAssertLessThan(restore, f.log.events.firstIndex(of: "config.restore")!)
        XCTAssertLessThan(restore, f.log.events.firstIndex(of: "profile.write")!)
        XCTAssertGreaterThan(f.gamma.invalidations, 0)
        await f.cleanup()
    }

    func testFailedTransitionUsesExplicitRecoveryAndRestoresCapturedState() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.hdr.configure(failSet: true)
        await f.model.requestHDR(true, for: f.external)
        let restores = await f.hdr.restores(), current = await f.hdr.current()
        XCTAssertEqual(restores, [false])
        XCTAssertEqual(current, false)
        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertEqual(f.profiles.selected[f.external.id], "original")
        XCTAssertFalse(f.model.isPending)
        XCTAssertNotNil(f.model.errorMessage)
        await f.cleanup()
    }

    func testStoppingDuringHeldWriteWaitsForWriteThenRestoresOriginal() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.hdr.holdNextWrite()
        let requesting = Task { await f.model.requestHDR(true, for: f.external) }
        for _ in 0..<1000 { if await f.hdr.isHolding { break }; await Task.yield() }
        let holding = await f.hdr.isHolding
        XCTAssertTrue(holding)
        XCTAssertTrue(f.model.isApplyingPreset)
        f.model.stop()
        XCTAssertFalse(f.model.enabled)
        await f.hdr.completeWrite()
        await requesting.value
        await f.model.waitForOperations()
        let current = await f.hdr.current(), restores = await f.hdr.restores()
        XCTAssertEqual(current, false)
        XCTAssertEqual(restores, [false])
        XCTAssertEqual(f.configuration.restoreCount, 1)
        XCTAssertEqual(f.profiles.selected[f.external.id], "original")
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.isApplyingPreset)
        XCTAssertFalse(f.controller.isPresented)
        await f.cleanup()
    }

    func testReusedNumericDisplayIDIsRejectedBeforeAnyHDRWrite() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        let d = f.external
        f.configuration.connected[0] = DisplayInfo(id: "replacement", displayID: d.displayID, name: "Other",
            isBuiltin: false, isMain: false, mirrorMasterID: nil, modes: d.modes, currentMode: d.currentMode)
        await f.model.requestHDR(true, for: d)
        let writes = await f.hdr.writes()
        XCTAssertEqual(writes, [])
        XCTAssertEqual(f.configuration.snapshotCount, 0)
        XCTAssertFalse(f.model.isPending)
        await f.cleanup()
    }

    func testFailedHDRRestoreKeepsSnapshotForExplicitRetry() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.requestHDR(true, for: f.external)
        await f.hdr.configure(failRestore: true)
        f.controller.revert()
        await f.model.waitForOperations()
        XCTAssertTrue(f.model.isPending)
        XCTAssertTrue(f.model.rollbackFailed)
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertNotNil(f.model.errorMessage)
        let beforeRetry = await f.hdr.current()
        XCTAssertEqual(beforeRetry, true)
        await f.hdr.configure(failRestore: false)
        f.model.cancelChange()
        await f.model.waitForOperations()
        XCTAssertFalse(f.model.isPending)
        XCTAssertFalse(f.model.rollbackFailed)
        let current = await f.hdr.current(), restores = await f.hdr.restores()
        XCTAssertEqual(current, false)
        XCTAssertEqual(restores, [false, false])
        await f.cleanup()
    }

    func testPendingTrialBlocksOtherDisplayAndSystemMutations() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.requestHDR(true, for: f.external)
        await f.model.requestHDR(false, for: f.external)
        f.model.request(.main(displayID: f.external.displayID), display: f.external)
        f.model.setDimming(0.2, for: f.external)
        await f.model.systemSettings.setNightShift(true)
        let writes = await f.hdr.writes()
        let systemWrites = await f.system.writeCount
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(systemWrites, 0)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertEqual(f.model.dimming(for: f.external), 1)
        await f.cleanup()
    }

    func testStableUUIDAllowsConfirmationAfterHDRReassignsRuntimeID() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.configuration.remapAfterHDR = true
        f.model.start()
        await f.model.requestHDR(true, for: f.external)
        XCTAssertEqual(f.configuration.connected.first?.displayID, 84)
        XCTAssertTrue(f.model.isPending)
        f.controller.confirm()
        await f.model.waitForOperations()
        XCTAssertFalse(f.model.isPending)
        XCTAssertTrue(f.configuration.applied.isEmpty)
        XCTAssertEqual(f.configuration.restoreCount, 0)
        await f.cleanup()
    }

    func testHeldOldIDReadCannotLeaveCachedStateStaleAfterUUIDRemaps() async {
        let f = Fixture()
        defer { f.scheduleCleanup() }
        f.model.start()
        await f.model.refreshHDR()
        for _ in 0..<1000 {
            if f.model.hdrState(for: f.external).value == false { break }
            await Task.yield()
        }
        XCTAssertEqual(f.model.hdrState(for: f.external).value, false)
        await f.hdr.holdNextRead(displayID: f.external.displayID)
        let obsolete = Task { await f.model.refreshHDR() }
        for _ in 0..<1000 { if await f.hdr.isReadHeld { break }; await Task.yield() }
        let held = await f.hdr.isReadHeld
        XCTAssertTrue(held)
        let d = f.external
        let remapped = DisplayInfo(id: d.id, displayID: 84, name: d.name, isBuiltin: d.isBuiltin,
            isMain: d.isMain, mirrorMasterID: d.mirrorMasterID, modes: d.modes, currentMode: d.currentMode, frame: d.frame)
        f.configuration.connected[0] = remapped
        await f.hdr.setReadValue(true, displayID: 84)
        f.model.refresh()
        await f.model.refreshHDR()
        await f.hdr.completeRead()
        await obsolete.value
        for _ in 0..<1000 {
            if f.model.hdrState(for: remapped).value == true { break }
            await Task.yield()
        }
        let readIDs = await f.hdr.readIDs()
        XCTAssertTrue(readIDs.contains(84))
        XCTAssertEqual(f.model.hdrState(for: remapped).value, true, "The old ID's captured false result must not overwrite the fresh true state")
        await f.cleanup()
    }

    @MainActor
    private final class Fixture {
        let suite = "DisplayHDRFeatureModelTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let external: DisplayInfo
        let builtin: DisplayInfo
        let log = HDRModelLog()
        let configuration: HDRModelConfiguration
        let profiles: HDRModelProfiles
        let gamma = HDRModelGamma()
        let system = HDRModelSystem()
        let hdr: HDRModelService
        let controller = DisplayRevertController(showsWindow: false)
        let model: DisplayFeatureModel

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let mode = DisplayModeOption(id: 1, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 120)
            external = DisplayInfo(id: "external", displayID: 42, name: "External", isBuiltin: false, isMain: false,
                mirrorMasterID: nil, modes: [mode], currentMode: mode, frame: CGRect(x: 1800, y: 0, width: 2560, height: 1440))
            builtin = DisplayInfo(id: "builtin", displayID: 1, name: "Builtin", isBuiltin: true, isMain: true,
                mirrorMasterID: nil, modes: [mode], currentMode: mode, frame: CGRect(x: 0, y: 0, width: 1800, height: 1200))
            configuration = HDRModelConfiguration(displays: [external, builtin], log: log)
            profiles = HDRModelProfiles(log: log)
            let configuration = configuration, profiles = profiles
            hdr = HDRModelService(log: log) { target, enabled in
                if enabled { configuration.applyHDRSideEffects(uuid: target.uuid); profiles.selected[target.uuid] = "hdr" }
            }
            model = DisplayFeatureModel(service: configuration, brightness: gamma, defaults: defaults,
                revertController: controller, colorProfiles: profiles,
                systemSettings: DisplaySystemSettingsModel(service: system), hdr: hdr)
        }

        func cleanup() async {
            await hdr.configure(failRestore: false)
            await hdr.completeWrite()
            await hdr.completeRead()
            model.stop()
            await model.waitForOperations()
            controller.dismiss()
            defaults.removePersistentDomain(forName: suite)
        }

        func scheduleCleanup() { Task { await cleanup() } }
    }
}

@MainActor
private final class HDRModelLog {
    var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor HDRModelSystem: DisplaySystemSettingsServing {
    private(set) var writeCount = 0
    func read(_ control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool? { false }
    func write(_ enabled: Bool, control: DisplaySystemControl, target: DisplayHardwareTarget?) async throws -> Bool {
        writeCount += 1
        return enabled
    }
}

private actor HDRModelService: DisplayHDRServing {
    private var value = false
    private var failSet = false
    private var failRestore = false
    private var hold = false
    private var pending: CheckedContinuation<Void, Never>?
    private var heldReadID: UInt32?
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var reads: [UInt32] = []
    private var readValues: [UInt32: Bool] = [:]
    private var requested: [Bool] = []
    private var restored: [Bool] = []
    private let log: HDRModelLog
    private let didWrite: @MainActor @Sendable (DisplayHardwareTarget, Bool) -> Void
    init(log: HDRModelLog, didWrite: @escaping @MainActor @Sendable (DisplayHardwareTarget, Bool) -> Void) {
        self.log = log; self.didWrite = didWrite
    }
    func read(_ target: DisplayHardwareTarget) async throws -> Bool? {
        reads.append(target.displayID)
        let captured: Bool? = target.isBuiltin ? nil : readValues[target.displayID] ?? value
        if heldReadID == target.displayID {
            heldReadID = nil
            await withCheckedContinuation { pendingRead = $0 }
        }
        return captured
    }
    func setHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        requested.append(enabled)
        if hold { hold = false; await withCheckedContinuation { pending = $0 } }
        value = enabled
        await didWrite(target, enabled)
        if failSet { throw DisplayHDRError.notApplied }
        return value
    }
    func restoreHDR(_ enabled: Bool, for target: DisplayHardwareTarget) async throws -> Bool {
        restored.append(enabled)
        await log.record("hdr.restore")
        if failRestore { throw DisplayHDRError.notApplied }
        value = enabled
        return enabled
    }
    func configure(failSet: Bool? = nil, failRestore: Bool? = nil) {
        if let failSet { self.failSet = failSet }; if let failRestore { self.failRestore = failRestore }
    }
    func holdNextWrite() { hold = true }
    func holdNextRead(displayID: UInt32) { heldReadID = displayID }
    func setReadValue(_ value: Bool, displayID: UInt32) { readValues[displayID] = value }
    func completeRead() { let continuation = pendingRead; pendingRead = nil; continuation?.resume() }
    var isReadHeld: Bool { pendingRead != nil }
    func readIDs() -> [UInt32] { reads }
    func completeWrite() { let continuation = pending; pending = nil; continuation?.resume() }
    var isHolding: Bool { pending != nil }
    func current() -> Bool { value }
    func writes() -> [Bool] { requested }
    func restores() -> [Bool] { restored }
}

@MainActor
private final class HDRModelConfiguration: DisplayConfigurationServing {
    var connected: [DisplayInfo]
    var applied: [DisplayChange] = []
    var snapshotCount = 0
    var restoreCount = 0
    var remapAfterHDR = false
    private var captured: [DisplayInfo] = []
    private let log: HDRModelLog
    init(displays: [DisplayInfo], log: HDRModelLog) { connected = displays; self.log = log }
    func displays() throws -> [DisplayInfo] { connected }
    func apply(_ change: DisplayChange, permanently: Bool) throws { applied.append(change) }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        snapshotCount += 1
        captured = connected
        return .init(entries: connected.map { .init(displayID: $0.displayID, uuid: $0.id, mode: nil,
            origin: $0.frame.origin, mirrorMasterID: nil, mirrorMasterUUID: nil) })
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {
        log.record("config.restore")
        restoreCount += 1
        connected = captured
    }
    func applyHDRSideEffects(uuid: String) {
        guard let i = connected.firstIndex(where: { $0.id == uuid }) else { return }
        let d = connected[i], changed = DisplayModeOption(id: 2, width: 2560, height: 1440,
            pixelWidth: 5120, pixelHeight: 1440, refreshRate: 60)
        connected[i] = DisplayInfo(id: d.id, displayID: remapAfterHDR ? 84 : d.displayID, name: d.name,
            isBuiltin: d.isBuiltin, isMain: d.isMain, mirrorMasterID: nil, modes: [changed], currentMode: changed, frame: d.frame)
    }
}

@MainActor
private final class HDRModelProfiles: DisplayColorProfileServing {
    var selected: [String: String] = ["external": "original", "builtin": "factory"]
    var writes: [String] = []
    private let log: HDRModelLog
    init(log: HDRModelLog) { self.log = log }
    func state(for display: DisplayInfo) async throws -> DisplayColorProfileState {
        .init(options: ["factory", "original", "hdr"].map { .init(id: $0, name: $0) }, selectedID: selected[display.id] ?? "factory")
    }
    func setProfile(_ profileID: String, for display: DisplayInfo) async throws {
        log.record("profile.write")
        writes.append(profileID)
        selected[display.id] = profileID
    }
}

@MainActor
private final class HDRModelGamma: DisplayBrightnessServing {
    var values: [(value: Double, id: UInt32)] = []
    var invalidations = 0
    func setDimming(_ factor: Double, displayID: UInt32) throws { values.append((factor, displayID)) }
    func invalidate() { invalidations += 1 }
    func restore() {}
}
