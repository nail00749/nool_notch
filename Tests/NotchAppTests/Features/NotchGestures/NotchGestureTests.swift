import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class NotchGestureTests: XCTestCase {
    func testSettingsDefaultOffAndPersistIndependentOptions() throws {
        let suite = "NotchGestureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotchGestureSettings(defaults: defaults)
        XCTAssertFalse(settings.preferences.scrollVolumeEnabled)
        XCTAssertEqual(settings.preferences.doubleClickAction, .disabled)
        XCTAssertEqual(settings.preferences.volumeStep, 0.04)

        var updated = settings.preferences
        updated.scrollVolumeEnabled = true
        updated.doubleClickAction = .nextTrack
        updated.volumeStep = 5
        settings.setPreferences(updated)
        let restored = NotchGestureSettings(defaults: defaults)
        XCTAssertTrue(restored.preferences.scrollVolumeEnabled)
        XCTAssertEqual(restored.preferences.doubleClickAction, .nextTrack)
        XCTAssertEqual(restored.preferences.volumeStep, 0.10)
    }

    func testDoubleClickWaitsForPairAndCancelDropsPendingSingle() {
        XCTAssertGreaterThan(NotchDoubleClickPolicy.systemInterval, 0)
        var policy = NotchDoubleClickPolicy()
        let point = CGPoint(x: 20, y: 20)
        XCTAssertEqual(policy.mouseDown(at: 1, point: point, clickCount: 1, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: point), .scheduleSingle)
        XCTAssertEqual(policy.mouseDown(at: 1.2, point: CGPoint(x: 22, y: 20),
                                        clickCount: 2, interval: 0.5), .performDouble)
        XCTAssertEqual(policy.mouseUp(at: CGPoint(x: 22, y: 20)), .performDouble)
        XCTAssertFalse(policy.resolveSingle())

        XCTAssertEqual(policy.mouseDown(at: 2, point: point, clickCount: 1, interval: 0.5), .scheduleSingle)
        policy.cancel()
        XCTAssertFalse(policy.resolveSingle())
        XCTAssertEqual(policy.mouseDown(at: 3, point: point, clickCount: 1, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: point), .scheduleSingle)
        XCTAssertTrue(policy.resolveSingle())
    }

    func testDoubleClickNeedsSystemIntervalAndSameArea() {
        var policy = NotchDoubleClickPolicy()
        let point = CGPoint(x: 20, y: 20)
        XCTAssertEqual(policy.mouseDown(at: 1, point: point, clickCount: 1, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: point), .scheduleSingle)
        XCTAssertEqual(policy.mouseDown(at: 1.1, point: CGPoint(x: 40, y: 20),
                                        clickCount: 2, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: CGPoint(x: 40, y: 20)), .scheduleSingle)
        XCTAssertEqual(policy.mouseDown(at: 2, point: point, clickCount: 2, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: point), .scheduleSingle)
        XCTAssertEqual(policy.mouseDown(at: 2.1, point: point, clickCount: 3, interval: 0.5), .ignore)
        XCTAssertFalse(policy.resolveSingle())
    }

    func testSecondPressDragThenReturnDoesNotPerformDoubleClick() {
        var policy = NotchDoubleClickPolicy()
        let point = CGPoint(x: 20, y: 20)
        XCTAssertEqual(policy.mouseDown(at: 1, point: point, clickCount: 1, interval: 0.5), .scheduleSingle)
        XCTAssertEqual(policy.mouseUp(at: point), .scheduleSingle)
        XCTAssertEqual(policy.mouseDown(at: 1.2, point: point, clickCount: 2, interval: 0.5), .performDouble)
        XCTAssertTrue(policy.dragged(to: CGPoint(x: 40, y: 20)))
        XCTAssertEqual(policy.mouseUp(at: point), .ignore)
        XCTAssertFalse(policy.resolveSingle())
    }

    func testVerticalScrollRequiresThresholdRateLimitAndIgnoresMomentum() {
        var policy = NotchScrollVolumePolicy()
        XCTAssertEqual(policy.process(vertical: 7, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: true, ended: false, time: 1), .pass)
        XCTAssertEqual(policy.process(vertical: 18, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.01), .consume(step: nil))
        XCTAssertEqual(policy.process(vertical: 12, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.02), .consume(step: 1))
        XCTAssertEqual(policy.process(vertical: 48, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.03), .consume(step: nil))
        XCTAssertEqual(policy.process(vertical: 1, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.12), .consume(step: 1))
        XCTAssertEqual(policy.process(vertical: 20, horizontal: 0, precise: true, momentum: true,
                                      modified: false, began: false, ended: true, time: 1.2), .pass)
    }

    func testHorizontalGestureStaysPassedThroughEvenWithVerticalTail() {
        var policy = NotchScrollVolumePolicy()
        XCTAssertEqual(policy.process(vertical: 1, horizontal: 10, precise: true, momentum: false,
                                      modified: false, began: true, ended: false, time: 1), .pass)
        XCTAssertEqual(policy.process(vertical: 40, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.1), .pass)
        XCTAssertEqual(policy.process(vertical: 0, horizontal: 0, precise: true, momentum: false,
                                      modified: false, began: false, ended: true, time: 1.2), .pass)
        XCTAssertEqual(policy.process(vertical: -2, horizontal: 0, precise: false, momentum: false,
                                      modified: false, began: false, ended: false, time: 1.3), .consume(step: -1))
    }

    func testVolumeHandlerUsesFakeAndNeverWritesForInvalidDirection() {
        let fake = FakeVolumeController()
        let handler = NotchGestureVolumeHandler(controller: fake)
        XCTAssertNil(handler.adjust(direction: 0, step: 0.04))
        XCTAssertNil(handler.adjust(direction: 1, step: .infinity))
        XCTAssertTrue(fake.deltas.isEmpty)
        XCTAssertEqual(handler.adjust(direction: 1, step: 0.04), .updated(0.54))
        XCTAssertEqual(handler.adjust(direction: -1, step: 0.02), .updated(0.48))
        XCTAssertEqual(fake.deltas, [0.04, -0.02])
        XCTAssertEqual(NotchVolumePolicy.target(current: 0.98, delta: 0.04), 1)
        XCTAssertEqual(NotchVolumePolicy.target(current: 0.02, delta: -0.04), 0)
    }

    private final class FakeVolumeController: SystemVolumeControlling {
        var deltas: [Double] = []
        func adjust(by delta: Double) -> NotchVolumeAdjustmentResult {
            deltas.append(delta)
            return .updated(0.5 + delta)
        }
    }
}
