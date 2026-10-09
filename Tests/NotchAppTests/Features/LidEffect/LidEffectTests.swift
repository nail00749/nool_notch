import AppKit
import XCTest
@testable import NotchApp

final class LidEffectPolicyTests: XCTestCase {
    func testProgressIsBoundedAndIncreasesAsLidCloses() {
        XCTAssertEqual(LidEffectPolicy.progress(angle: 90, startAngle: 70), 0)
        XCTAssertEqual(LidEffectPolicy.progress(angle: 70, startAngle: 70), 0)
        XCTAssertEqual(LidEffectPolicy.progress(angle: 40, startAngle: 70), 0.5)
        XCTAssertEqual(LidEffectPolicy.progress(angle: 10, startAngle: 70), 1)
        XCTAssertEqual(LidEffectPolicy.progress(angle: 0, startAngle: 70), 1)
        for angle in [Double.nan, .infinity, -1, 181] {
            XCTAssertEqual(LidEffectPolicy.progress(angle: angle, startAngle: 70), 0)
        }
        XCTAssertEqual(LidEffectPolicy.progress(angle: nil, startAngle: 70), 0)
    }

    func testPreviewReturnsToZeroAndPreferencesSanitizeCorruptValues() {
        XCTAssertEqual(LidEffectPolicy.previewProgress(elapsed: 0), 0)
        XCTAssertEqual(LidEffectPolicy.previewProgress(elapsed: 1.5), 1)
        XCTAssertEqual(LidEffectPolicy.previewProgress(elapsed: 3), 0)
        XCTAssertEqual(LidEffectPolicy.previewProgress(elapsed: .nan), 0)
        let value = LidEffectPreferences(enabled: true, startAngle: .nan, blurRadius: 500, dimming: -1).sanitized
        XCTAssertEqual(value.startAngle, 70)
        XCTAssertEqual(value.blurRadius, 40)
        XCTAssertEqual(value.dimming, 0)
    }
}

@MainActor
final class LidEffectControllerTests: XCTestCase {
    func testModulePausePreservesPreferencesAndDoesNotResumeOnWake() async throws {
        let fixture = Fixture(screen: try XCTUnwrap(NSScreen.main), allowed: true)
        fixture.controller.start()
        fixture.enable()
        let oldCallback = try XCTUnwrap(fixture.sensor.callback)
        fixture.controller.pause()
        fixture.controller.resume()
        oldCallback(.angle(40))
        await fixture.controller.waitForStop()
        XCTAssertTrue(fixture.controller.preferences.enabled)
        XCTAssertEqual(fixture.sensor.starts, 1)
        XCTAssertNil(fixture.controller.angle)
        XCTAssertEqual(fixture.renderer.starts, 0)
        fixture.controller.start()
        XCTAssertEqual(fixture.sensor.starts, 2)
        XCTAssertEqual(fixture.permission.requests, 0)
        await fixture.finish()
    }

    func testDisabledStartupAndPreviewNeverRequestPermissionImplicitly() async {
        let fixture = Fixture()
        fixture.controller.start()
        fixture.controller.preview()
        await fixture.controller.waitForStop()
        XCTAssertEqual(fixture.permission.requests, 0)
        XCTAssertEqual(fixture.sensor.starts, 0)
        XCTAssertEqual(fixture.renderer.starts, 0)
        XCTAssertFalse(fixture.controller.isPreviewing)
        fixture.controller.requestCapturePermission()
        XCTAssertEqual(fixture.permission.requests, 1)
        await fixture.finish()
    }

    func testEnabledPreferencePersistsWithoutStartingCaptureOrRequestingAccess() async {
        let fixture = Fixture()
        fixture.controller.start()
        fixture.enable()
        await fixture.controller.waitForStop()
        XCTAssertEqual(fixture.permission.requests, 0)
        XCTAssertEqual(fixture.renderer.starts, 0)
        let restored = LidEffectController(defaults: fixture.defaults, sensor: FakeSensor(),
                                           renderer: FakeRenderer(), permission: FakePermission(), screenProvider: { nil })
        XCTAssertTrue(restored.preferences.enabled)
        restored.stop()
        await restored.waitForStop()
        await fixture.finish()
    }

    func testSuspendIgnoresOldSensorCallbacksAndResumeStartsFresh() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let fixture = Fixture(screen: screen, allowed: true)
        fixture.controller.start()
        fixture.enable()
        let oldCallback = try XCTUnwrap(fixture.sensor.callback)
        oldCallback(.angle(40))
        await fixture.controller.waitForStop()
        XCTAssertEqual(fixture.renderer.starts, 1)
        XCTAssertEqual(fixture.renderer.progress, 0.5)
        fixture.controller.suspend()
        XCTAssertEqual(fixture.renderer.progress, 0)
        oldCallback(.angle(0))
        await fixture.controller.waitForStop()
        XCTAssertNil(fixture.controller.angle)
        XCTAssertGreaterThan(fixture.renderer.stops, 0)
        fixture.controller.resume()
        XCTAssertEqual(fixture.sensor.starts, 2)
        oldCallback(.angle(0))
        XCTAssertNil(fixture.controller.angle)
        fixture.sensor.callback?(.angle(50))
        await fixture.controller.waitForStop()
        XCTAssertEqual(fixture.renderer.starts, 2)
        await fixture.finish()
    }

    func testDisableWhileCaptureStartsCannotResurrectOverlay() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let fixture = Fixture(screen: screen, allowed: true)
        fixture.renderer.delayStart = true
        fixture.controller.start()
        fixture.enable()
        fixture.sensor.callback?(.angle(40))
        for _ in 0..<100 where fixture.renderer.pendingStart == nil { await Task.yield() }
        XCTAssertNotNil(fixture.renderer.pendingStart)
        var preferences = fixture.controller.preferences
        preferences.enabled = false
        fixture.controller.setPreferences(preferences)
        fixture.renderer.completeStart()
        await fixture.controller.waitForStop()
        XCTAssertEqual(fixture.renderer.progress, 0)
        XCTAssertEqual(fixture.renderer.stops, 1)
        await fixture.finish()
    }

    func testUnavailableAndRevokedPermissionClearOverlay() async throws {
        let fixture = Fixture(screen: try XCTUnwrap(NSScreen.main), allowed: true)
        fixture.controller.start()
        fixture.enable()
        fixture.sensor.callback?(.angle(40))
        await fixture.controller.waitForStop()
        fixture.sensor.callback?(.unavailable("Disconnected"))
        XCTAssertEqual(fixture.renderer.progress, 0)
        await fixture.controller.waitForStop()
        fixture.sensor.callback?(.angle(40))
        await fixture.controller.waitForStop()
        fixture.permission.allowed = false
        fixture.controller.refreshPermission()
        XCTAssertEqual(fixture.renderer.progress, 0)
        await fixture.controller.waitForStop()
        XCTAssertFalse(fixture.controller.hasCapturePermission)
        await fixture.finish()
    }

    func testMissingFirstReadingTimesOutAndLateReplyIsIgnored() async throws {
        let fixture = Fixture(screen: try XCTUnwrap(NSScreen.main), allowed: true)
        fixture.controller.start()
        fixture.enable()
        let callback = try XCTUnwrap(fixture.sensor.callback)
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertTrue(fixture.controller.sensorStatus.contains("не ответил"))
        callback(.angle(40))
        await fixture.controller.waitForStop()
        XCTAssertNil(fixture.controller.angle)
        XCTAssertEqual(fixture.renderer.starts, 0)
        await fixture.finish()
    }

    func testStaleSensorReadingExpiresWithoutMoreCallbacks() async throws {
        let fixture = Fixture(screen: try XCTUnwrap(NSScreen.main), allowed: true)
        fixture.controller.start()
        fixture.enable()
        fixture.sensor.callback?(.angle(40))
        await fixture.controller.waitForStop()
        XCTAssertGreaterThan(fixture.renderer.progress, 0)
        try await Task.sleep(for: .milliseconds(1400))
        await fixture.controller.waitForStop()
        XCTAssertNil(fixture.controller.angle)
        XCTAssertEqual(fixture.renderer.progress, 0)
        await fixture.finish()
    }

    func testPreviewEndsAutomaticallyWithoutEnablingFeature() async throws {
        let fixture = Fixture(screen: try XCTUnwrap(NSScreen.main), allowed: true)
        fixture.controller.start()
        fixture.controller.preview()
        XCTAssertTrue(fixture.controller.isPreviewing)
        try await Task.sleep(for: .milliseconds(3200))
        await fixture.controller.waitForStop()
        XCTAssertFalse(fixture.controller.isPreviewing)
        XCTAssertFalse(fixture.controller.preferences.enabled)
        XCTAssertEqual(fixture.permission.requests, 0)
        XCTAssertEqual(fixture.renderer.starts, 1)
        XCTAssertEqual(fixture.renderer.progress, 0)
        await fixture.finish()
    }

    @MainActor
    private final class Fixture {
        let suite = "LidEffectTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let sensor = FakeSensor()
        let renderer = FakeRenderer()
        let permission = FakePermission()
        let controller: LidEffectController

        init(screen: NSScreen? = nil, allowed: Bool = false) {
            defaults = UserDefaults(suiteName: suite)!
            permission.allowed = allowed
            controller = LidEffectController(defaults: defaults, sensor: sensor, renderer: renderer,
                                             permission: permission, screenProvider: { screen })
        }
        func enable() {
            var preferences = controller.preferences
            preferences.enabled = true
            controller.setPreferences(preferences)
        }
        func finish() async {
            controller.stop()
            await controller.waitForStop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private final class FakePermission: LidCapturePermissionProviding {
        var allowed = false
        var requests = 0
        func isAllowed() -> Bool { allowed }
        func request() -> Bool { requests += 1; return allowed }
    }

    private final class FakeSensor: LidAngleProviding {
        var callback: (@MainActor @Sendable (LidSensorReading) -> Void)?
        var starts = 0
        func start(_ onReading: @escaping @MainActor @Sendable (LidSensorReading) -> Void) {
            starts += 1
            callback = onReading
        }
        func stop() { callback = nil }
    }

    private final class FakeRenderer: LidEffectRendering {
        var onFailure: (@MainActor (String) -> Void)?
        var starts = 0
        var stops = 0
        var progress: Double = 0
        var delayStart = false
        var pendingStart: CheckedContinuation<Void, Never>?
        func start(screen: NSScreen) async throws {
            starts += 1
            if delayStart { await withCheckedContinuation { pendingStart = $0 } }
        }
        func completeStart() { pendingStart?.resume(); pendingStart = nil }
        func update(progress: Double, blurRadius: Double, dimming: Double) { self.progress = progress }
        func stop() async { stops += 1; progress = 0 }
    }
}
