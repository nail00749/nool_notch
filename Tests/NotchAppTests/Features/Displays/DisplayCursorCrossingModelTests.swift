import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class DisplayCursorCrossingModelTests: XCTestCase {
    func testDefaultOffNeverInstallsListenersEvenWithUnalignedScreens() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.start(displays: f.displays)
        f.model.update(displays: f.displays)
        XCTAssertFalse(f.model.isEnabled)
        XCTAssertFalse(f.model.isActive)
        XCTAssertEqual(f.spy.startCalls, 0)
        XCTAssertEqual(f.spy.arms, 0)
    }

    func testExplicitOptInPersistsAndRecreationStillWaitsForModuleStart() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        XCTAssertTrue(f.defaults.bool(forKey: DisplayCursorCrossingModel.preferenceKey))
        XCTAssertEqual(f.spy.arms, 0)
        let nextSpy = CursorModelService()
        let next = DisplayCursorCrossingModel(defaults: f.defaults, service: nextSpy)
        defer { next.stop() }
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(next.isActive)
        next.start(displays: f.displays)
        XCTAssertTrue(next.isActive)
        XCTAssertEqual(nextSpy.arms, 1)
    }

    func testModuleStopRemovesListenersWithoutForgettingDesiredPreference() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        f.model.start(displays: f.displays)
        XCTAssertTrue(f.spy.isRunning)
        f.model.stop()
        XCTAssertFalse(f.spy.isRunning)
        XCTAssertFalse(f.model.isActive)
        XCTAssertTrue(f.model.isEnabled)
        XCTAssertTrue(f.defaults.bool(forKey: DisplayCursorCrossingModel.preferenceKey))
        f.model.update(displays: f.displays)
        XCTAssertEqual(f.spy.arms, 1, "Topology updates while the module is stopped cannot install listeners")
    }

    func testUserCanAlwaysTurnOffWithOneDisplayOrNoEligibleRoute() {
        let f = Fixture()
        defer { f.cleanup() }
        for topology in [[f.displays[0]], [f.displays[0], f.display("aligned", 3, x: 100, y: 0, width: 100, height: 100)], []] {
            f.model.start(displays: topology)
            f.model.setEnabled(true)
            XCTAssertFalse(f.model.isActive)
            f.model.setEnabled(false)
            XCTAssertFalse(f.model.isEnabled)
            XCTAssertFalse(f.defaults.bool(forKey: DisplayCursorCrossingModel.preferenceKey))
        }
        XCTAssertEqual(f.spy.arms, 0)
    }

    func testSuspendStopsAndResumeReturnsListenersForSameDesiredTopology() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        f.model.start(displays: f.displays)
        f.model.setSuspended(true)
        XCTAssertFalse(f.model.isActive)
        XCTAssertFalse(f.spy.isRunning)
        XCTAssertTrue(f.model.isEnabled)
        f.model.update(displays: f.displays)
        XCTAssertEqual(f.spy.arms, 1)
        f.model.setSuspended(false)
        XCTAssertTrue(f.model.isActive)
        XCTAssertEqual(f.spy.arms, 2)
    }

    func testFatalFailureBlocksAutomaticRetryUntilExplicitOffOn() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        f.model.start(displays: f.displays)
        f.spy.fail("Cursor permission was revoked")
        XCTAssertFalse(f.model.isActive)
        XCTAssertEqual(f.model.errorMessage, "Cursor permission was revoked")
        let calls = f.spy.startCalls
        f.model.update(displays: f.displays)
        f.model.setSuspended(true)
        f.model.setSuspended(false)
        XCTAssertEqual(f.spy.startCalls, calls)
        f.model.setEnabled(false)
        f.model.setEnabled(true)
        XCTAssertTrue(f.model.isActive)
        XCTAssertNil(f.model.errorMessage)
        XCTAssertEqual(f.spy.arms, 2)
    }

    func testReorderingSameGeometryCannotRearmFailedListenerButRealTopologyChangeCan() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        f.model.start(displays: f.displays)
        f.spy.fail("Listener failed")
        let calls = f.spy.startCalls
        f.model.update(displays: Array(f.displays.reversed()))
        XCTAssertEqual(f.spy.startCalls, calls)
        XCTAssertFalse(f.model.isActive)
        let changed = [f.displays[0], f.display("right", 2, x: 100, y: 25, width: 100, height: 60)]
        f.model.update(displays: changed)
        XCTAssertTrue(f.model.isActive)
        XCTAssertNil(f.model.errorMessage)
        XCTAssertEqual(f.spy.arms, 2)
    }

    func testLateFailureAfterOptOutOrModuleStopCannotReviveErrors() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        f.model.start(displays: f.displays)
        let late = f.spy.onFailure
        f.model.setEnabled(false)
        late?("Late failure")
        XCTAssertNil(f.model.errorMessage)
        XCTAssertFalse(f.model.isActive)
        f.model.setEnabled(true)
        f.model.stop()
        late?("Another late failure")
        XCTAssertNil(f.model.errorMessage)
        XCTAssertFalse(f.model.isActive)
    }

    func testMissingMirrorAndStandbyDisplaysNeverCreateIndependentRoutes() {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        let mirror = f.display("mirror", 2, x: 100, y: 20, width: 100, height: 60, mirror: 1)
        let standby = f.display("standby", 3, x: -100, y: 20, width: 100, height: 60, enabled: false)
        f.model.start(displays: [f.displays[0], mirror, standby])
        XCTAssertFalse(f.model.isActive)
        XCTAssertEqual(f.spy.arms, 0)
        f.model.update(displays: [])
        XCTAssertFalse(f.model.isActive)
        XCTAssertTrue(f.model.isEnabled)
    }

    func testFeatureConfigurationTrialStopsCursorAndCancelResumesIt() async {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        let config = CursorModelConfiguration(displays: f.displays)
        config.onApply = { XCTAssertFalse(f.spy.isRunning, "Stop the listener before entering synchronous display configuration") }
        let controller = DisplayRevertController(showsWindow: false)
        let feature = makeFeature(f, config, controller)
        defer { feature.stop(); controller.dismiss() }
        feature.start()
        XCTAssertTrue(f.model.isActive)
        feature.request(.mode(displayID: 1, modeID: 2), display: f.displays[0])
        XCTAssertTrue(feature.isPending)
        XCTAssertFalse(f.model.isActive)
        XCTAssertFalse(f.spy.isRunning)
        controller.revert()
        await feature.waitForOperations()
        XCTAssertFalse(feature.isPending)
        XCTAssertTrue(f.model.isActive)
        XCTAssertEqual(config.applyCount, 1)
        feature.requestArrangement(f.displays.map { DisplayPlacement(uuid: $0.id, origin: $0.frame.origin) })
        XCTAssertEqual(config.applyCount, 2)
        XCTAssertTrue(f.model.isActive)
        feature.stop()
        XCTAssertFalse(f.spy.isRunning)
        XCTAssertTrue(f.model.isEnabled)
    }

    func testFeatureSleepStopsCursorAndLocalWakeNotificationRestartsIt() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.model.setEnabled(true)
        let controller = DisplayRevertController(showsWindow: false)
        let feature = makeFeature(f, CursorModelConfiguration(displays: f.displays), controller)
        defer { feature.stop(); controller.dismiss() }
        feature.start()
        XCTAssertTrue(f.model.isActive)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        for _ in 0..<100 where f.model.isActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(f.model.isActive)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        for _ in 0..<100 where !f.model.isActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(f.model.isActive)
        feature.stop()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(f.model.isActive)
    }

    private func makeFeature(_ f: Fixture, _ config: CursorModelConfiguration,
                             _ controller: DisplayRevertController) -> DisplayFeatureModel {
        DisplayFeatureModel(service: config, brightness: CursorModelGamma(), defaults: f.defaults,
            revertController: controller,
            systemSettings: DisplaySystemSettingsModel(service: UnavailableDisplaySystemSettingsService()),
            cursorCrossing: f.model)
    }

    @MainActor
    private final class Fixture {
        let suite = "DisplayCursorCrossingModelTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let spy = CursorModelService()
        let model: DisplayCursorCrossingModel
        var displays: [DisplayInfo] {
            [display("left", 1, x: 0, y: 0, width: 100, height: 100),
             display("right", 2, x: 100, y: 20, width: 100, height: 60)]
        }
        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            model = DisplayCursorCrossingModel(defaults: defaults, service: spy)
        }
        func display(_ uuid: String, _ id: UInt32, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                     mirror: UInt32? = nil, enabled: Bool = true) -> DisplayInfo {
            let a = DisplayModeOption(id: 1, width: 100, height: 100, pixelWidth: 200, pixelHeight: 200, refreshRate: 60)
            let b = DisplayModeOption(id: 2, width: 80, height: 80, pixelWidth: 160, pixelHeight: 160, refreshRate: 60)
            return DisplayInfo(id: uuid, displayID: id, name: uuid, isBuiltin: id == 1, isMain: id == 1,
                mirrorMasterID: mirror, modes: [a, b], currentMode: a,
                frame: CGRect(x: x, y: y, width: width, height: height), isEnabled: enabled)
        }
        func cleanup() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}

@MainActor
private final class CursorModelService: DisplayCursorCrossingServing {
    var isRunning = false
    var onFailure: (@MainActor (String) -> Void)?
    var startCalls = 0
    var arms = 0
    private var topology: [DisplayCursorCrossingScreen] = []
    func start(displays: [DisplayInfo]) throws {
        startCalls += 1
        let next = displays.filter { $0.isEnabled && $0.mirrorMasterID == nil }.map {
            DisplayCursorCrossingScreen(uuid: $0.id, displayID: $0.displayID, frame: $0.frame)
        }.sorted { $0.uuid < $1.uuid }
        guard DisplayCursorCrossingGeometry.hasUnalignedEdges(in: next) else { stop(); return }
        if !isRunning || topology != next { arms += 1 }
        topology = next
        isRunning = true
    }
    func stop() { isRunning = false }
    func fail(_ message: String) { isRunning = false; onFailure?(message) }
}

@MainActor
private final class CursorModelConfiguration: DisplayConfigurationServing {
    let connected: [DisplayInfo]
    var onApply: (() -> Void)?
    var applyCount = 0
    init(displays: [DisplayInfo]) { connected = displays }
    func displays() throws -> [DisplayInfo] { connected }
    func apply(_ change: DisplayChange, permanently: Bool) throws { applyCount += 1; onApply?() }
    func snapshot() throws -> DisplayConfigurationSnapshot {
        .init(entries: connected.map { .init(displayID: $0.displayID, uuid: $0.id, mode: nil,
            origin: $0.frame.origin, mirrorMasterID: nil, mirrorMasterUUID: nil) })
    }
    func restore(_ snapshot: DisplayConfigurationSnapshot) throws {}
}

@MainActor
private final class CursorModelGamma: DisplayBrightnessServing {
    func setDimming(_ factor: Double, displayID: UInt32) throws {}
    func invalidate() {}
    func restore() {}
}
