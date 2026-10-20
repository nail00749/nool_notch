import AppKit
import XCTest
@testable import NotchApp

final class DisplayCursorCrossingServiceTests: XCTestCase {
    @MainActor func testInstallIsAtomicAndRollsBackGlobalWhenLocalFails() {
        let rig = CursorCrossingTestRuntime()
        rig.failLocal = true
        let service = PublicDisplayCursorCrossingService(runtime: rig)
        XCTAssertThrowsError(try service.start(displays: rig.displays))
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(rig.removed, [1])
        rig.emit()
        XCTAssertTrue(rig.warps.isEmpty)
        service.stop()
        XCTAssertEqual(rig.removed, [1])
    }

    @MainActor func testFailedGlobalDoesNotInstallLocal() {
        let rig = CursorCrossingTestRuntime()
        rig.failGlobal = true
        let service = PublicDisplayCursorCrossingService(runtime: rig)
        XCTAssertThrowsError(try service.start(displays: rig.displays))
        XCTAssertEqual(rig.localInstalls, 0)
        XCTAssertTrue(rig.removed.isEmpty)
    }

    @MainActor func testAlignedOrSingleScreenInstallsNoMonitors() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        try service.start(displays: [rig.displays[0]])
        try service.start(displays: [rig.displays[0], Self.display("b", 2, CGRect(x: 100, y: 0, width: 100, height: 100))])
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(rig.globalInstalls, 0)
        XCTAssertEqual(rig.localInstalls, 0)
    }

    @MainActor func testSameTopologyIsIdempotentAndChangeInvalidatesOldCallbacks() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        try service.start(displays: rig.displays)
        try service.start(displays: rig.displays.reversed())
        XCTAssertEqual(rig.globalInstalls, 1)
        let old = rig.globalHandlers[0]
        rig.displays[1] = Self.display("c", 3, CGRect(x: 100, y: 50, width: 100, height: 100))
        try service.start(displays: rig.displays)
        XCTAssertEqual(rig.removed, [1, 2])
        old(rig.sample)
        XCTAssertTrue(rig.warps.isEmpty)
        rig.emit()
        XCTAssertEqual(rig.warps, [CGPoint(x: 102, y: 52)])
        service.stop()
        service.stop()
        XCTAssertEqual(rig.removed, [1, 2, 3, 4])
    }

    @MainActor func testGlobalAndLocalSamplesUseSameWarpPolicyAndCooldown() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        try service.start(displays: rig.displays)
        rig.emit()
        XCTAssertEqual(rig.warps, [CGPoint(x: 102, y: 52)])
        rig.now = 10.1
        rig.emit(local: true)
        XCTAssertEqual(rig.warps.count, 1)
        rig.now = 10.16
        rig.emit(local: true)
        XCTAssertEqual(rig.warps.count, 2)
    }

    @MainActor func testSkipsStaleFuturePressedSecureAndMovedPointerSamples() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        try service.start(displays: rig.displays)
        rig.emit(timestamp: 9.8)
        rig.emit(timestamp: 11)
        rig.emit(timestamp: .nan)
        rig.emit(buttons: 1)
        rig.pressedMouseButtons = 2
        rig.emit()
        rig.pressedMouseButtons = 0
        rig.isSecureInputEnabled = true
        rig.emit()
        rig.isSecureInputEnabled = false
        rig.pointer = CGPoint(x: 80, y: 20)
        rig.emit()
        rig.pointer = CGPoint(x: 100, y: 20)
        rig.emit()
        XCTAssertTrue(rig.warps.isEmpty)
        XCTAssertEqual(rig.liveReads, 0)
    }

    @MainActor func testFreshIdentityOrBoundsChangeStopsAndReportsOnce() throws {
        for kind in 0...2 {
            let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            try service.start(displays: rig.displays)
            if kind == 0 { rig.liveOverride = [DisplayCursorCrossingScreen(uuid: "reused-id", displayID: 1, frame: rig.displays[0].frame)] }
            if kind == 1 { rig.liveOverride = [DisplayCursorCrossingScreen(uuid: "a", displayID: 1, frame: CGRect(x: 1, y: 0, width: 100, height: 100))] }
            if kind == 2 { rig.liveOverride = [] } // asleep, disabled or mirror group no longer eligible
            rig.emit()
            rig.emit()
            XCTAssertFalse(service.isRunning)
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(rig.removed, [1, 2])
            XCTAssertTrue(rig.warps.isEmpty)
        }
    }

    @MainActor func testWarpFailureRemovesMonitorsAndDoesNotRetry() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        rig.warpResult = .cannotComplete
        var failures = 0
        service.onFailure = { _ in failures += 1 }
        try service.start(displays: rig.displays)
        rig.emit()
        rig.emit(local: true)
        XCTAssertEqual(rig.warps.count, 1)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(rig.removed, [1, 2])
    }

    @MainActor func testStopInvalidatesRetainedCallbacks() throws {
        let rig = CursorCrossingTestRuntime(), service = PublicDisplayCursorCrossingService(runtime: rig)
        try service.start(displays: rig.displays)
        service.stop()
        rig.emit()
        rig.emit(local: true)
        XCTAssertTrue(rig.warps.isEmpty)
    }

    func testSuppressionIntervalRestoredOnSuccessAndNativeFailure() {
        for result: CGError in [.success, .cannotComplete] {
            var intervals: [TimeInterval] = [], calls = 0
            let actual = DisplayCursorCrossingWarp.perform(to: CGPoint(x: 1, y: 2), previousInterval: 0.25,
                setInterval: { intervals.append($0) }, warp: { _ in calls += 1; return result })
            XCTAssertEqual(actual, result)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(intervals, [0, 0.25])
        }
        let unavailable = DisplayCursorCrossingWarp.perform(to: .zero, previousInterval: nil,
            setInterval: { _ in XCTFail("No source") }, warp: { _ in XCTFail("No source"); return .success })
        XCTAssertEqual(unavailable, .cannotComplete)
    }

    func testEligibilityExcludesWholeMirrorGroupDisabledDuplicatesAndInvalidFrames() {
        let displays = [Self.display("master", 1), Self.display("mirror", 2, mirror: 1),
                        Self.display("disabled", 3, enabled: false), Self.display("A", 4), Self.display("a", 5),
                        Self.display("same-id", 6), Self.display("other-id", 6),
                        Self.display("invalid", 7, CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)),
                        Self.display(" Z ", 8), Self.display("b", 9)]
        XCTAssertEqual(DisplayCursorCrossingEligibility.screens(from: displays).map(\.uuid), ["b", "z"])
    }

    private static func display(_ uuid: String, _ id: UInt32, _ frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100),
                                mirror: UInt32? = nil, enabled: Bool = true) -> DisplayInfo {
        DisplayInfo(id: uuid, displayID: id, name: uuid, isBuiltin: false, isMain: id == 1,
                    mirrorMasterID: mirror, modes: [], currentMode: nil, frame: frame, isEnabled: enabled)
    }
}

@MainActor
private final class CursorCrossingTestRuntime: DisplayCursorCrossingRuntime {
    var now: TimeInterval = 10
    var pressedMouseButtons = 0
    var isSecureInputEnabled = false
    var failGlobal = false, failLocal = false
    var globalInstalls = 0, localInstalls = 0, liveReads = 0
    var globalHandlers: [@MainActor (DisplayCursorCrossingSample) -> Void] = []
    var localHandlers: [@MainActor (DisplayCursorCrossingSample) -> Void] = []
    var removed: [Int] = [], warps: [CGPoint] = []
    var warpResult: CGError = .success
    var pointer: CGPoint? = CGPoint(x: 99, y: 20)
    var liveOverride: [DisplayCursorCrossingScreen]?
    var displays: [DisplayInfo] = [
        DisplayInfo(id: "a", displayID: 1, name: "a", isBuiltin: true, isMain: true,
                    mirrorMasterID: nil, modes: [], currentMode: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
        DisplayInfo(id: "b", displayID: 2, name: "b", isBuiltin: false, isMain: false,
                    mirrorMasterID: nil, modes: [], currentMode: nil, frame: CGRect(x: 100, y: 50, width: 100, height: 100))
    ]
    var sample: DisplayCursorCrossingSample {
        DisplayCursorCrossingSample(location: CGPoint(x: 99, y: 20), delta: CGVector(dx: 5, dy: 0),
                                    timestamp: now, pressedMouseButtons: 0)
    }
    func installGlobal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any? {
        globalInstalls += 1
        globalHandlers.append(handler)
        return failGlobal ? nil : globalInstalls * 2 - 1
    }
    func installLocal(_ handler: @escaping @MainActor (DisplayCursorCrossingSample) -> Void) -> Any? {
        localInstalls += 1
        localHandlers.append(handler)
        return failLocal ? nil : localInstalls * 2
    }
    func removeMonitor(_ token: Any) { removed.append(token as! Int) }
    func currentPointerLocation() -> CGPoint? { pointer }
    func liveScreens() -> [DisplayCursorCrossingScreen]? {
        liveReads += 1
        return liveOverride ?? DisplayCursorCrossingEligibility.screens(from: displays)
    }
    func warp(to point: CGPoint) -> CGError { warps.append(point); return warpResult }
    func emit(local: Bool = false, timestamp: TimeInterval? = nil, buttons: Int = 0) {
        let event = DisplayCursorCrossingSample(location: sample.location, delta: sample.delta,
            timestamp: timestamp ?? now, pressedMouseButtons: buttons)
        (local ? localHandlers.last : globalHandlers.last)?(event)
    }
}
