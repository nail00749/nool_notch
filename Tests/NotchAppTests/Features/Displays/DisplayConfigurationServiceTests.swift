import CoreGraphics
import XCTest
@testable import NotchApp

final class DisplayConfigurationServiceTests: XCTestCase {
    func testCannotDisableLastIndependentScreenOrSoleMirrorMaster() {
        let main = display("main", id: 1, main: true)
        let follower = display("mirror", id: 2, master: 1)
        XCTAssertThrowsError(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [main]))
        XCTAssertThrowsError(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [main, follower]))
        XCTAssertNoThrow(try DisplayPowerPolicy.validate(displayID: 2, enabled: false, displays: [main, follower]))
    }

    func testDisabledOrNondrawableScreenCannotSatisfyLastScreenGuard() {
        let main = display("main", id: 1, main: true)
        let other = display("other", id: 2)
        let disabled = display("off", id: 3, enabled: false)
        XCTAssertThrowsError(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [main, disabled]))
        XCTAssertThrowsError(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [main, other], drawableDisplayIDs: [1]))
        XCTAssertNoThrow(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [main, other], drawableDisplayIDs: [1, 2]))
    }

    func testEnableAndAlreadyDisabledNoopDoNotNeedAnotherDrawableScreen() {
        let disabled = display("off", id: 1, enabled: false)
        XCTAssertNoThrow(try DisplayPowerPolicy.validate(displayID: 1, enabled: true, displays: [disabled]))
        XCTAssertNoThrow(try DisplayPowerPolicy.validate(displayID: 1, enabled: false, displays: [disabled]))
        XCTAssertThrowsError(try DisplayPowerPolicy.validate(displayID: 7, enabled: true, displays: [disabled]))
    }

    func testMetadataMatchesOnlyUniqueLiveHardwareAndRejectsUUIDReuse() {
        let signature = DisplayHardwareFingerprint(vendor: 10, model: 20, serial: 30, isBuiltin: false)
        let record = DisplayManagedRecord(display: display("original", id: 1), fingerprint: signature)
        XCTAssertEqual(DisplayManagedRecord.match(in: [record], fingerprint: signature, liveUUID: nil, allFingerprints: [signature]), record)
        XCTAssertNil(DisplayManagedRecord.match(in: [record], fingerprint: signature, liveUUID: "different", allFingerprints: [signature]))
        XCTAssertNil(DisplayManagedRecord.match(in: [record], fingerprint: signature, liveUUID: nil, allFingerprints: [signature, signature]))
        XCTAssertNil(DisplayManagedRecord.match(in: [], fingerprint: signature, liveUUID: nil, allFingerprints: [signature]))
        let reusedSlot = DisplayHardwareFingerprint(vendor: 10, model: 20, serial: 99, isBuiltin: false)
        XCTAssertNil(DisplayManagedRecord.match(in: [record], fingerprint: reusedSlot, liveUUID: nil, allFingerprints: [reusedSlot]))
    }

    func testEmptyOrSeriallessExternalSlotIsNotRecoverable() {
        XCTAssertFalse(DisplayHardwareFingerprint(vendor: 0, model: 0, serial: 0, isBuiltin: false).isRecoverable)
        XCTAssertFalse(DisplayHardwareFingerprint(vendor: 10, model: 20, serial: 0, isBuiltin: false).isRecoverable)
        XCTAssertFalse(DisplayHardwareFingerprint(vendor: .max, model: .max, serial: .max, isBuiltin: false).isRecoverable)
        XCTAssertTrue(DisplayHardwareFingerprint(vendor: 10, model: 20, serial: 0, isBuiltin: true).isRecoverable)
    }

    func testSnapshotEnabledDefaultsPreserveExistingCallers() {
        let entry = DisplayConfigurationSnapshot.Entry(displayID: 1, uuid: "one", mode: nil,
                                                       origin: .zero, mirrorMasterID: nil, mirrorMasterUUID: nil)
        XCTAssertTrue(entry.isEnabled)
        XCTAssertFalse(entry.wasManagedDisabled)
        XCTAssertTrue(display("one", id: 1).isEnabled)
    }

    func testMetadataPreservesRestoreOwnershipAndMigratesExistingManagedRecords() throws {
        let fingerprint = DisplayHardwareFingerprint(vendor: 10, model: 20, serial: 30, isBuiltin: false)
        let record = DisplayManagedRecord(display: display("original", id: 1), fingerprint: fingerprint, restoreOnStop: false)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertFalse(try JSONDecoder().decode(DisplayManagedRecord.self, from: encoded).restoreOnStop)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "restoreOnStop")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertTrue(try JSONDecoder().decode(DisplayManagedRecord.self, from: legacyData).restoreOnStop)
        let snapshot = DisplayConfigurationSnapshot.Entry(displayID: 1, uuid: "original", mode: nil, origin: .zero,
                                                           mirrorMasterID: nil, mirrorMasterUUID: nil,
                                                           isEnabled: false, wasManagedDisabled: true)
        XCTAssertTrue(snapshot.wasManagedDisabled)
        XCTAssertFalse(snapshot.isEnabled)
    }

    func testArrangementRequiresCompleteUniqueActiveMasterSet() {
        let main = display("main", id: 1, main: true)
        let other = display("other", id: 2)
        let follower = display("follower", id: 3, master: 1)
        let disabled = display("off", id: 4, enabled: false)
        let valid = [placement("main", x: 0), placement("other", x: 100)]
        XCTAssertNoThrow(try DisplayArrangementPolicy.validate(valid, displays: [main, other, follower, disabled]))
        XCTAssertThrowsError(try DisplayArrangementPolicy.validate([placement("main", x: 0)], displays: [main, other]))
        XCTAssertThrowsError(try DisplayArrangementPolicy.validate([placement("main", x: 0), placement("main", x: 100)], displays: [main, other]))
        XCTAssertThrowsError(try DisplayArrangementPolicy.validate(valid + [placement("off", x: 200)], displays: [main, other, disabled]))
    }

    func testArrangementRejectsOverlapGapCornerOnlyAndInvalidCoordinates() {
        let screens = [display("main", id: 1, main: true), display("other", id: 2)]
        for origin in [CGPoint(x: 99, y: 0), CGPoint(x: 101, y: 0), CGPoint(x: 100, y: 100),
                       CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 100.5, y: 0),
                       CGPoint(x: CGFloat(Int32.max) + 1, y: 0)] {
            XCTAssertThrowsError(try DisplayArrangementPolicy.validate([placement("main", x: 0), .init(uuid: "other", origin: origin)], displays: screens))
        }
        XCTAssertThrowsError(try DisplayArrangementPolicy.validate([placement("main", x: 100), placement("other", x: 200)], displays: screens))
    }

    func testArrangementAcceptsNegativeOriginsAndConnectedChain() {
        let screens = [display("main", id: 1, main: true), display("left", id: 2), display("bottom", id: 3)]
        let placements = [placement("main", x: 0), placement("left", x: -100), .init(uuid: "bottom", origin: CGPoint(x: -100, y: 100))]
        XCTAssertNoThrow(try DisplayArrangementPolicy.validate(placements, displays: screens))
    }

    private func placement(_ uuid: String, x: CGFloat) -> DisplayPlacement { .init(uuid: uuid, origin: CGPoint(x: x, y: 0)) }

    private func display(_ uuid: String, id: UInt32, main: Bool = false, master: UInt32? = nil, enabled: Bool = true) -> DisplayInfo {
        .init(id: uuid, displayID: id, name: uuid, isBuiltin: false, isMain: main, mirrorMasterID: master,
              modes: [], currentMode: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100), isEnabled: enabled)
    }
}
