import CoreGraphics
import XCTest
@testable import NotchApp

@MainActor
final class DisplayDisconnectPolicyTests: XCTestCase {
    func testIdleRefreshUsesOnePowerSnapshotWithoutSkippingEmergencyRecovery() throws {
        let rig = DisconnectPolicyTestRig()
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.readCount, 1)
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.readCount, 2)
    }

    func testDefaultPolicyDoesNotAdoptExternalDisabledState() throws {
        let rig = DisconnectPolicyTestRig()
        rig.devices[0] = rig.device("a", enabled: false)
        rig.records = [rig.record("a", owned: false)]
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.controller.state.policy, .restoreOnExit)
        XCTAssertTrue(rig.calls.isEmpty)
        try rig.controller.confirm(states: ["a": false], devices: rig.devices, ownedUUIDs: [])
        try rig.controller.setPolicy(.keepDisabled, devices: rig.devices)
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
    }

    func testOptInAdoptsOnlyCurrentSessionConfirmedOwnedDisabledScreen() throws {
        let rig = DisconnectPolicyTestRig()
        rig.devices[0] = rig.device("a", enabled: false)
        rig.devices[1] = rig.device("b", enabled: false)
        try rig.controller.confirm(states: ["a": false], devices: rig.devices, ownedUUIDs: ["a"])
        try rig.controller.setPolicy(.keepDisabled, devices: rig.devices)
        XCTAssertEqual(rig.controller.keptDisconnectedUUIDs, ["a"])
        XCTAssertTrue(rig.calls.isEmpty)
        // Prior session confirmation never adopts unknown saved metadata.
        rig.controller.endSession()
        try rig.controller.setPolicy(.restoreOnExit, devices: rig.devices)
        try rig.controller.setPolicy(.keepDisabled, devices: rig.devices)
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
    }

    func testConfirmedStateUpdatesIntentWithoutRepeatingNativePowerCall() throws {
        let rig = DisconnectPolicyTestRig(policy: .keepDisabled)
        rig.devices[0] = rig.device("a", enabled: false)
        try rig.controller.confirm(states: ["a": false], devices: rig.devices, ownedUUIDs: ["a"])
        XCTAssertEqual(rig.controller.keptDisconnectedUUIDs, ["a"])
        XCTAssertEqual(rig.saved.count, 1)
        XCTAssertTrue(rig.calls.isEmpty)
    }

    func testBatchConfirmationCommitsOnceAndRejectsAllBeforeAnySave() throws {
        let rig = DisconnectPolicyTestRig(policy: .keepDisabled)
        rig.devices = [rig.device("a", enabled: false), rig.device("b", enabled: false)]
        XCTAssertThrowsError(try rig.controller.confirm(states: ["a": false, "b": true], devices: rig.devices, ownedUUIDs: ["a", "b"]))
        XCTAssertTrue(rig.saved.isEmpty)
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
        try rig.controller.confirm(states: ["a": false, "b": false], devices: rig.devices, ownedUUIDs: ["a", "b"])
        XCTAssertEqual(rig.saved.count, 1)
        XCTAssertEqual(rig.controller.keptDisconnectedUUIDs, ["a", "b"])
    }

    func testFailedAtomicSaveDoesNotChangePolicyIntentOrSessionOwnership() throws {
        let rig = DisconnectPolicyTestRig()
        rig.devices[0] = rig.device("a", enabled: false)
        rig.failSave = true
        XCTAssertThrowsError(try rig.controller.confirm(states: ["a": false], devices: rig.devices, ownedUUIDs: ["a"]))
        rig.failSave = false
        try rig.controller.setPolicy(.keepDisabled, devices: rig.devices)
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
        rig.failSave = true
        XCTAssertThrowsError(try rig.controller.setPolicy(.restoreOnExit, devices: rig.devices))
        XCTAssertEqual(rig.controller.state.policy, .keepDisabled)
    }

    func testTemporaryEnableDoesNotEraseIntentAndExplicitConfirmationDoes() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        // A temporary enable trial only changes native state/recovery cache.
        rig.devices[0] = rig.device("a", enabled: true)
        XCTAssertEqual(rig.controller.keptDisconnectedUUIDs, ["a"])
        XCTAssertTrue(rig.controller.retains(rig.record("a")))
        let restarted = DisplayDisconnectPolicyController(state: rig.controller.state, save: { _ in })
        XCTAssertEqual(restarted.keptDisconnectedUUIDs, ["a"])
        try rig.controller.confirm(states: ["a": true], devices: rig.devices, ownedUUIDs: [])
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
        XCTAssertFalse(rig.controller.retains(rig.record("a")))
    }

    func testStartupRecoversUnconfirmedOwnedScreenBeforeApplyingKeptIntent() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.devices = [rig.device("a", enabled: true), rig.device("b", enabled: false)]
        rig.records = [rig.record("a"), rig.record("b")]
        XCTAssertTrue(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["b:on", "a:off"])
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.calls.count, 2)
    }

    func testSuccessfulOrFailedWakeReapplyIsBoundedUntilExplicitWakeReset() throws {
        for failure in [false, true] {
            let rig = DisconnectPolicyTestRig(kept: ["a"])
            rig.failNative = failure
            if failure { XCTAssertThrowsError(try rig.reconcile()) }
            else { XCTAssertTrue(try rig.reconcile()) }
            rig.devices.removeAll { $0.display.id == "a" }
            rig.devices.append(rig.device("a", enabled: true))
            XCTAssertFalse(try rig.reconcile())
            XCTAssertEqual(rig.calls, ["a:off"])
            rig.controller.resetAttempts()
            if failure { XCTAssertThrowsError(try rig.reconcile()) }
            else { XCTAssertTrue(try rig.reconcile()) }
            XCTAssertEqual(rig.calls, ["a:off", "a:off"])
        }
    }

    func testMissingStartupRecordRecoversOnReconnectButNewManualOffDoesNot() throws {
        let rig = DisconnectPolicyTestRig()
        rig.records = [rig.record("a")]
        rig.devices = [rig.device("b", enabled: true)]
        XCTAssertFalse(try rig.reconcile())
        rig.devices.append(rig.device("a", enabled: false))
        XCTAssertTrue(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:on"])
        // A fresh user trial after launch is outside the startup snapshot.
        rig.records = [rig.record("b")]
        rig.devices.removeAll { $0.display.id == "b" }
        rig.devices.append(rig.device("b", enabled: false))
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:on"])
    }

    func testFailedStartupRecoveryRetriesOnlyAfterPhysicalTopologyChanges() throws {
        let rig = DisconnectPolicyTestRig()
        rig.devices[0] = rig.device("a", enabled: false)
        rig.records = [rig.record("a")]
        rig.failedUUIDs = ["a"]
        XCTAssertThrowsError(try rig.reconcile())
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:on"])
        rig.failedUUIDs = []
        rig.devices.append(rig.device("new-peer", enabled: true, serial: 900))
        XCTAssertTrue(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:on", "a:on"])
    }

    func testRepeatedReconnectWithSameNumericIDGetsFreshPhysicalEpoch() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        XCTAssertTrue(try rig.reconcile())
        for _ in 0..<2 {
            rig.devices.removeAll { $0.display.id == "a" }
            XCTAssertFalse(try rig.reconcile())
            rig.devices.append(rig.device("a", enabled: true))
            XCTAssertTrue(try rig.reconcile())
        }
        XCTAssertEqual(rig.calls, ["a:off", "a:off", "a:off"])
    }

    func testNumericIDRemapDoesNotGrantRetryOnUnchangedPhysicalTopology() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.failedUUIDs = ["a"]
        XCTAssertThrowsError(try rig.reconcile())
        rig.devices[0] = rig.device("a", enabled: true, displayID: 77)
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:off"])
    }

    func testNativePowerIdentityRejectsReusedSlotAndBindsCurrentNumericID() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        let expected = rig.controller.state.intents["a"]!
        XCTAssertNoThrow(try DisplayPowerIdentity.resolve(expected, displayID: 1, devices: rig.devices))
        rig.devices[0] = rig.device("a", enabled: true, serial: 999)
        XCTAssertThrowsError(try DisplayPowerIdentity.resolve(expected, displayID: 1, devices: rig.devices))
        rig.devices[0] = rig.device("a", enabled: true, displayID: 77)
        XCTAssertThrowsError(try DisplayPowerIdentity.resolve(expected, displayID: 1, devices: rig.devices))
        XCTAssertNoThrow(try DisplayPowerIdentity.resolve(expected, displayID: 77, devices: rig.devices))
    }

    func testNeverDisablesLastIndependentDrawableOrCountsMirroredFollower() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.devices = [rig.device("a", enabled: true), rig.device("b", enabled: true, mirror: 1)]
        XCTAssertFalse(try rig.reconcile())
        XCTAssertTrue(rig.calls.isEmpty)
        XCTAssertEqual(rig.controller.safetyEnabledUUIDs, ["a"])
    }

    func testZeroOutputRecoveryPrefersOwnedBuiltinAndIgnoresPhantomSurvivor() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a", "b"])
        rig.devices = [rig.device("a", enabled: false), rig.device("b", enabled: false), rig.fallback()]
        rig.records = [rig.record("a"), rig.record("b")]
        XCTAssertTrue(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:on"])
        XCTAssertEqual(rig.controller.safetyEnabledUUIDs, ["a"])
        XCTAssertEqual(rig.controller.keptDisconnectedUUIDs, ["a", "b"])
        XCTAssertFalse(try rig.reconcile())
    }

    func testAllPhysicalDisplaysAsleepSkipsStartupRecoveryAndKeptReapply() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.devices = [rig.device("a", enabled: false, asleep: true), rig.device("b", enabled: false, asleep: true), rig.fallback()]
        rig.records = [rig.record("a"), rig.record("b")]
        XCTAssertFalse(try rig.reconcile())
        XCTAssertTrue(rig.calls.isEmpty)
        rig.devices[0] = rig.device("a", enabled: false)
        rig.devices[1] = rig.device("b", enabled: false)
        XCTAssertTrue(try rig.reconcile())
        // Sleeping refresh did not consume the one-time startup recovery.
        XCTAssertEqual(rig.calls.first, "b:on")
    }

    func testEmergencyRecoveryTriesNextOwnedScreenAfterFailureOrSilentNoop() throws {
        for silent in [false, true] {
            let rig = DisconnectPolicyTestRig(kept: ["a", "b"])
            rig.devices = [rig.device("a", enabled: false), rig.device("b", enabled: false), rig.fallback()]
            rig.records = [rig.record("a"), rig.record("b")]
            if silent { rig.silentUUIDs = ["a"] }
            else { rig.failedUUIDs = ["a"] }
            XCTAssertThrowsError(try rig.reconcile())
            XCTAssertEqual(rig.calls, ["a:on", "b:on"])
            XCTAssertTrue(rig.devices.contains { $0.display.id == "b" && $0.isDrawable })
            XCTAssertFalse(try rig.reconcile())
            XCTAssertEqual(rig.calls.count, 2)
        }
    }

    func testSilentDisableDoesNotClaimSuccessOrRetryForever() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.silentUUIDs = ["a"]
        XCTAssertThrowsError(try rig.reconcile())
        XCTAssertFalse(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:off"])
    }

    func testPolicyRestoreClearsIntentWithoutImmediateNativeEnable() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        XCTAssertTrue(rig.controller.retains(rig.record("a")))
        try rig.controller.setPolicy(.restoreOnExit, devices: rig.devices)
        XCTAssertTrue(rig.controller.keptDisconnectedUUIDs.isEmpty)
        XCTAssertFalse(rig.controller.retains(rig.record("a")))
        XCTAssertTrue(rig.calls.isEmpty)
        XCTAssertEqual(rig.saved.last?.policy, .restoreOnExit)
    }

    func testReusedUUIDOrAmbiguousHardwareNeverReceivesAutomaticDisable() throws {
        for kind in 0...2 {
            let rig = DisconnectPolicyTestRig(kept: ["a"])
            if kind == 0 { rig.devices[0] = rig.device("a", enabled: true, serial: 999) }
            if kind == 1 { rig.devices.append(rig.device("duplicate", enabled: true, serial: 101, builtin: true)) }
            if kind == 2 { rig.devices[0] = rig.device("a", enabled: true, liveUUID: "different") }
            XCTAssertFalse(try rig.reconcile())
            XCTAssertTrue(rig.calls.isEmpty)
        }
    }

    func testMissingLiveUUIDUsesOnlyUniqueMatchingLiveHardware() throws {
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        rig.devices[0] = rig.device("a", enabled: true, liveUUID: nil)
        XCTAssertTrue(try rig.reconcile())
        XCTAssertEqual(rig.calls, ["a:off"])
    }

    func testStoreRoundTripIsSingleValueAndCorruptInputFallsBackSafely() throws {
        let suite = "DisplayDisconnectPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DisplayDisconnectPolicyStore(defaults: defaults)
        let rig = DisconnectPolicyTestRig(kept: ["a"])
        try store.save(rig.controller.state)
        XCTAssertEqual(store.load(), rig.controller.state)
        XCTAssertNotNil(defaults.data(forKey: DisplayDisconnectPolicyStore.key))
        defaults.set(Data("invalid".utf8), forKey: DisplayDisconnectPolicyStore.key)
        XCTAssertEqual(store.load(), DisplayDisconnectPolicyState())
    }
}

@MainActor
private final class DisconnectPolicyTestRig {
    var devices: [DisplayDisconnectDevice] = []
    var records: [DisplayManagedRecord] = []
    var calls: [String] = [], saved: [DisplayDisconnectPolicyState] = []
    var failSave = false, failNative = false
    var readCount = 0
    var failedUUIDs: Set<String> = [], silentUUIDs: Set<String> = []
    let initial: DisplayDisconnectPolicyState
    lazy var controller = DisplayDisconnectPolicyController(state: initial) { [unowned self] state in
        if self.failSave { throw TestFailure.failed }
        self.saved.append(state)
    }
    enum TestFailure: Error { case failed }

    init(policy: DisplayDisconnectPolicy = .restoreOnExit, kept: [String] = []) {
        var intents: [String: DisplayDisconnectIntent] = [:]
        for uuid in kept {
            intents[uuid] = DisplayDisconnectIntent(uuid: uuid, name: uuid,
                fingerprint: DisplayHardwareFingerprint(vendor: 10, model: uuid == "a" ? 1 : 2,
                    serial: uuid == "a" ? 101 : 102, isBuiltin: uuid == "a"))
        }
        initial = DisplayDisconnectPolicyState(policy: kept.isEmpty ? policy : .keepDisabled, intents: intents)
        devices = [device("a", enabled: true), device("b", enabled: true)]
    }

    func device(_ uuid: String, enabled: Bool, asleep: Bool = false, mirror: UInt32? = nil,
                serial: UInt32? = nil, builtin: Bool? = nil, liveUUID: String?? = .some(.some("default")),
                displayID: UInt32? = nil) -> DisplayDisconnectDevice {
        let id: UInt32 = displayID ?? (uuid == "a" ? 1 : uuid == "b" ? 2 : 3)
        let isBuiltin = builtin ?? (uuid == "a")
        let fingerprint = DisplayHardwareFingerprint(vendor: 10, model: isBuiltin ? 1 : 2,
            serial: serial ?? (uuid == "a" ? 101 : 102), isBuiltin: isBuiltin)
        let actualUUID: String? = liveUUID.flatMap { $0 } == "default" ? uuid : liveUUID.flatMap { $0 }
        return DisplayDisconnectDevice(display: DisplayInfo(id: uuid, displayID: id, name: uuid,
            isBuiltin: isBuiltin, isMain: id == 1, mirrorMasterID: mirror, modes: [], currentMode: nil, isEnabled: enabled),
            fingerprint: fingerprint, liveUUID: actualUUID, isActive: enabled, isAsleep: asleep)
    }

    func record(_ uuid: String, owned: Bool = true) -> DisplayManagedRecord {
        let current = device(uuid, enabled: false)
        return DisplayManagedRecord(display: current.display, fingerprint: current.fingerprint, restoreOnStop: owned)
    }

    func fallback() -> DisplayDisconnectDevice {
        DisplayDisconnectDevice(display: DisplayInfo(id: "phantom", displayID: 9, name: "phantom", isBuiltin: false,
            isMain: true, mirrorMasterID: nil, modes: [], currentMode: nil),
            fingerprint: DisplayHardwareFingerprint(vendor: 0x756E6B6E, model: 0x76697274, serial: 0, isBuiltin: false),
            liveUUID: "phantom", isActive: true, isAsleep: false)
    }

    func reconcile() throws -> Bool {
        try controller.reconcile(read: { self.readCount += 1; return self.devices }, recoveryRecords: { self.records }) { intent, enabled in
            let uuid = intent.uuid
            self.calls.append("\(uuid):\(enabled ? "on" : "off")")
            if self.failNative || self.failedUUIDs.contains(uuid) { throw TestFailure.failed }
            if self.silentUUIDs.contains(uuid) { return }
            let old = self.devices.first { $0.display.id == uuid }!
            self.devices.removeAll { $0.display.id == uuid }
            self.devices.append(self.device(uuid, enabled: enabled, serial: old.fingerprint.serial, builtin: old.fingerprint.isBuiltin))
            if enabled { self.records.removeAll { $0.uuid == uuid } }
            else if !self.records.contains(where: { $0.uuid == uuid }) { self.records.append(self.record(uuid)) }
        }
    }
}
