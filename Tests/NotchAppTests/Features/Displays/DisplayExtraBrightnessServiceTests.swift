import AppKit
import XCTest
@testable import NotchApp

final class DisplayExtraBrightnessServiceTests: XCTestCase {
    func testMissingFirstDrawableOrPresentationExpiresWithoutWallClockSleeps() {
        let health = DisplayExtraBrightnessPresentationHealth(startedAt: 10)
        XCTAssertFalse(health.hasExpired(at: 10.64))
        XCTAssertTrue(health.hasExpired(at: 10.66))
    }

    func testPresentationWatchdogTracksLastFrameRatherThanStart() {
        var health = DisplayExtraBrightnessPresentationHealth(startedAt: 10)
        health.presented(at: 10.5)
        XCTAssertFalse(health.hasExpired(at: 11.1))
        XCTAssertTrue(health.hasExpired(at: 11.2))
    }

    func testHealthyWorkerPresentationAvoidsFalseTimeoutAfterMainActorStall() {
        var health = DisplayExtraBrightnessPresentationHealth(startedAt: 10)
        health.presented(at: 10.1)
        XCTAssertTrue(health.hasExpired(at: 11))
        XCTAssertFalse(health.hasExpired(at: 11, latestWorkerPresentation: 10.9))
        XCTAssertTrue(health.hasExpired(at: 12, latestWorkerPresentation: 10.9))
    }

    @MainActor func testCapabilityIsCachedAndNoOverlayExistsByDefault() {
        let rig = ExtraBrightnessTestRig()
        let service = rig.service()
        service.reconcile([rig.target])
        rig.lookups = 0
        XCTAssertTrue(service.capability(for: rig.target).isSupported)
        XCTAssertFalse(service.capability(for: rig.target).isEnabled)
        XCTAssertEqual(rig.lookups, 0)
        XCTAssertTrue(rig.overlays.isEmpty)
    }

    @MainActor func testEnableWaitsForPresentationAndRepeatedEnableIsIdempotent() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        try service.setEnabled(true, for: rig.target)
        XCTAssertEqual(rig.overlays.count, 1)
        XCTAssertFalse(service.capability(for: rig.target).isEnabled)
        rig.overlays[0].present()
        XCTAssertTrue(service.capability(for: rig.target).isEnabled)
        XCTAssertEqual(service.presentedFrameCount, 1)
    }

    @MainActor func testStopClosesPendingOverlayAndIgnoresLatePresentation() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        service.stop()
        XCTAssertEqual(rig.overlays[0].closes, 1)
        rig.overlays[0].present()
        XCTAssertFalse(service.capability(for: rig.target).isEnabled)
        XCTAssertEqual(service.presentedFrameCount, 0)
    }

    @MainActor func testRenderingFailureClosesAndPreventsReplacementWorkers() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        rig.overlays[0].fail()
        XCTAssertEqual(rig.overlays[0].closes, 1)
        XCTAssertFalse(service.capability(for: rig.target).isSupported)
        service.reconcile([rig.target])
        XCTAssertThrowsError(try service.setEnabled(true, for: rig.target))
        XCTAssertEqual(rig.overlays.count, 1)
    }

    @MainActor func testDisconnectAndNumericIDRemappingCloseExistingSurface() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        let replacement = DisplayHardwareTarget(uuid: rig.target.uuid, displayID: 12, isBuiltin: true)
        service.reconcile([replacement])
        XCTAssertEqual(rig.overlays[0].closes, 1)
        XCTAssertFalse(service.capability(for: rig.target).isSupported)
        XCTAssertThrowsError(try service.setEnabled(true, for: rig.target))
    }

    @MainActor func testMissingLiveIdentityAndExternalSDRDisplayDoNotCreateWindow() {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        rig.connected = false
        service.reconcile([rig.target])
        XCTAssertFalse(service.capability(for: rig.target).isSupported)
        XCTAssertThrowsError(try service.setEnabled(true, for: rig.target))
        rig.connected = true
        rig.headroom = 1
        let external = DisplayHardwareTarget(uuid: "external", displayID: 2, isBuiltin: false)
        service.reconcile([external])
        XCTAssertFalse(service.capability(for: external).isSupported)
        XCTAssertTrue(service.capability(for: external).unavailableReason?.contains("HDR") == true)
        XCTAssertThrowsError(try service.setEnabled(true, for: external))
        XCTAssertTrue(rig.overlays.isEmpty)
    }

    @MainActor func testExternalHDRDisplayWithLiveHeadroomUsesItsActualIdentity() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        let external = DisplayHardwareTarget(uuid: "external", displayID: 2, isBuiltin: false)
        service.reconcile([external])
        XCTAssertTrue(service.capability(for: external).isSupported)
        try service.setEnabled(true, for: external)
        XCTAssertEqual(rig.createdTargets, [external])
        rig.overlays[0].present()
        XCTAssertTrue(service.capability(for: external).isEnabled)
    }

    @MainActor func testDuplicateUUIDAndNonEDRScreenRemainUnavailable() {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target, rig.target])
        XCTAssertFalse(service.capability(for: rig.target).isSupported)
        rig.headroom = 1
        service.reconcile([rig.target])
        XCTAssertFalse(service.capability(for: rig.target).isSupported)
        XCTAssertTrue(rig.overlays.isEmpty)
    }

    @MainActor func testGainClampsToMildLimitAndScreenHeadroom() throws {
        let rig = ExtraBrightnessTestRig()
        rig.headroom = 1.1
        let service = rig.service(gain: 99)
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        XCTAssertEqual(rig.gains, [1.1])
    }

    @MainActor func testDisableWhileNativeDrawableIsStuckDoesNotSpawnReplacementWorker() throws {
        let rig = ExtraBrightnessTestRig(), service = rig.service()
        service.reconcile([rig.target])
        try service.setEnabled(true, for: rig.target)
        rig.overlays[0].hasPendingWork = true
        try service.setEnabled(false, for: rig.target)
        XCTAssertThrowsError(try service.setEnabled(true, for: rig.target))
        XCTAssertEqual(rig.overlays.count, 1)
        rig.overlays[0].hasPendingWork = false
        try service.setEnabled(true, for: rig.target)
        XCTAssertEqual(rig.overlays.count, 2)
    }
}

@MainActor private final class ExtraBrightnessTestRig {
    let target = DisplayHardwareTarget(uuid: "builtin", displayID: 1, isBuiltin: true)
    var connected = true
    var headroom = 4.0
    var lookups = 0
    var overlays: [ExtraBrightnessTestOverlay] = []
    var gains: [Double] = []
    var createdTargets: [DisplayHardwareTarget] = []

    func service(gain: Double = 1.25) -> MetalDisplayExtraBrightnessService {
        MetalDisplayExtraBrightnessService(gain: gain, screenLookup: { [self] target in
            lookups += 1
            guard connected else { return nil }
            return .init(target: target, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                potentialHeadroom: headroom, currentHeadroom: 1)
        }, makeOverlay: { [self] screen, gain, presented, failed in
            gains.append(gain)
            createdTargets.append(screen.target)
            let overlay = ExtraBrightnessTestOverlay(present: presented, fail: failed)
            overlays.append(overlay)
            return overlay
        })
    }
}

@MainActor private final class ExtraBrightnessTestOverlay: DisplayExtraBrightnessRendering {
    var hasPendingWork = false
    var closes = 0
    let present: @MainActor () -> Void
    let fail: @MainActor () -> Void
    init(present: @escaping @MainActor () -> Void, fail: @escaping @MainActor () -> Void) {
        self.present = present; self.fail = fail
    }
    func start() throws {}
    func close() { closes += 1 }
}
