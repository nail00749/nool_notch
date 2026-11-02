import XCTest
@testable import NotchApp

final class WindowFullscreenTransferTests: XCTestCase {
    private let source = WindowLayoutScreen(id: "source", frame: .init(x: 0, y: 0, width: 1000, height: 800),
        visibleFrame: .init(x: 0, y: 24, width: 1000, height: 776))
    private let destination = WindowLayoutScreen(id: "destination", frame: .init(x: 1000, y: 0, width: 1600, height: 900),
        visibleFrame: .init(x: 1000, y: 24, width: 1600, height: 876))
    private let normal = WindowLayoutRect(x: 100, y: 100, width: 600, height: 400)

    func testDelayedStateAndFrameTransitionsMoveRestoredGeometryThenReenterFullscreen() async throws {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal)
        let result = await run(backend)
        let trace = await backend.trace()
        let expected = WindowLayoutGeometry.restore(WindowLayoutGeometry.normalize(normal, in: source.visibleFrame),
                                                     to: destination.visibleFrame)
        XCTAssertTrue(result.didMove)
        XCTAssertEqual(result.normalOriginal?.frame, normal)
        XCTAssertEqual(trace.moves, [expected])
        XCTAssertEqual(trace.toggles, [false, true])
        XCTAssertGreaterThanOrEqual(trace.pausesBeforeMove, 6, "Do not move when only AXFullScreen has changed")
        XCTAssertEqual(trace.state?.frame, destination.frame)
        XCTAssertTrue(trace.state?.isFullscreen == true)
    }

    func testSingleDisplayNeverExitsFullscreen() async {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal)
        let result = await WindowFullscreenTransfer.run(action: .nextDisplay, initial: initial,
                                                        screens: [source], backend: backend)
        XCTAssertFalse(result.didMove)
        let trace = await backend.trace()
        XCTAssertTrue(trace.toggles.isEmpty)
    }

    func testSlowObservableFullscreenTransitionDoesNotReceiveRepeatedRequests() async {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: .slowEnter)
        let result = await run(backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.message.hasPrefix("Окно перенесено"))
        XCTAssertEqual(trace.toggles, [false, true], "An active fullscreen transition must not be restarted")
    }

    func testIgnoredFirstFullscreenEntryRetriesBeforeTimeoutInBothDirections() async {
        for reverse in [false, true] {
            let from = reverse ? destination : source
            let to = reverse ? source : destination
            let restored = WindowLayoutRect(x: from.visibleFrame.x + 100, y: 100, width: 600, height: 400)
            let backend = FakeFullscreenBackend(source: from, destination: to, normal: restored, mode: .ignoreFirstEnter)
            let result = await WindowFullscreenTransfer.run(action: .nextDisplay,
                initial: .init(isFullscreen: true, frame: from.frame, canMoveAndResize: false),
                screens: [source, destination], backend: backend)
            let trace = await backend.trace()
            XCTAssertTrue(result.message.hasPrefix("Окно перенесено"), "An ignored request should not require timeout recovery")
            XCTAssertEqual(trace.toggles, [false, true, true])
            XCTAssertEqual(trace.state?.frame, to.frame)
            XCTAssertTrue(trace.state?.isFullscreen == true)
            XCTAssertLessThan(trace.totalPauses, 30, "Retry should not wait through the full five-second timeout")
        }
    }

    func testFullscreenExitRefusalAndTimeoutRecoverOnSourceWithoutMoving() async {
        for mode in [FakeFullscreenBackend.Mode.exitRefusal, .exitTimeout] {
            let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: mode)
            let result = await run(backend)
            let trace = await backend.trace()
            XCTAssertFalse(result.didMove)
            XCTAssertTrue(trace.moves.isEmpty)
            XCTAssertTrue(result.message.contains("исходном"))
            XCTAssertTrue(trace.state?.isFullscreen == true)
        }
    }

    func testMoveFailureRecoversSourceAndPartialMoveFailureRecoversDestination() async {
        for mode in [FakeFullscreenBackend.Mode.moveRefusal, .partialMoveFailure] {
            let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: mode)
            let result = await run(backend)
            let trace = await backend.trace()
            XCTAssertEqual(result.didMove, mode == .partialMoveFailure)
            XCTAssertTrue(trace.state?.isFullscreen == true)
            XCTAssertEqual(trace.state?.frame, mode == .partialMoveFailure ? destination.frame : source.frame)
            XCTAssertTrue(result.message.contains("восстановлен"))
        }
    }

    func testReentryRefusalAndWindowDisappearanceReportRecoveryFailure() async {
        for mode in [FakeFullscreenBackend.Mode.enterRefusal, .disappear] {
            let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: mode)
            let result = await run(backend)
            XCTAssertTrue(result.message.contains("вручную"), "Do not silently strand a normal or unavailable window")
        }
    }

    func testReentryOnWrongDisplayCannotReportSuccess() async {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: .wrongDisplay)
        let result = await run(backend)
        XCTAssertTrue(result.message.contains("Не удалось подтвердить"))
        XCTAssertFalse(result.message.hasPrefix("Окно перенесено"))
    }

    func testIdenticalNormalFrameWaitsConservativelyInsteadOfTimingOut() async {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: source.frame)
        let result = await run(backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didMove)
        XCTAssertGreaterThanOrEqual(trace.pausesBeforeMove, 12)
    }

    func testDestinationIsChosenBeforeExitEvenIfNormalFrameRestoresOnAnotherDisplay() async {
        let third = WindowLayoutScreen(id: "third", frame: .init(x: 2600, y: 0, width: 1000, height: 800),
            visibleFrame: .init(x: 2600, y: 24, width: 1000, height: 776))
        let backend = FakeFullscreenBackend(source: source, destination: destination,
            normal: .init(x: 2700, y: 100, width: 600, height: 400))
        let result = await WindowFullscreenTransfer.run(action: .nextDisplay, initial: initial,
            screens: [third, destination, source], backend: backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didMove)
        let frame = trace.moves.first
        XCTAssertEqual(frame.flatMap { WindowLayoutGeometry.screen(for: $0, in: [source, destination, third]) }?.id, destination.id)
    }

    func testCancelledParentStillWaitsForFullscreenRecovery() async {
        let backend = FakeFullscreenBackend(source: source, destination: destination, normal: normal, mode: .pendingExitCancellation)
        let initial = initial
        let screens = [source, destination]
        let task = Task { await WindowFullscreenTransfer.run(action: .nextDisplay, initial: initial, screens: screens, backend: backend) }
        for _ in 0..<1000 {
            if await backend.hasExited() { break }
            await Task.yield()
        }
        await backend.markCancellationRequested()
        task.cancel()
        let result = await task.value
        await backend.completeDelayedExitIfPending()
        let trace = await backend.trace()
        XCTAssertTrue(result.message.contains("отменён"))
        XCTAssertTrue(result.message.contains("восстановлен"))
        XCTAssertTrue(trace.state?.isFullscreen == true)
        XCTAssertGreaterThan(trace.nonCancelledRecoveryPauses, 0, "Cleanup must await in a cancellation-independent task")
        XCTAssertEqual(trace.toggles, [false, true], "Recovery must supersede the pending exit request")
    }

    private var initial: WindowFullscreenState { .init(isFullscreen: true, frame: source.frame, canMoveAndResize: false) }
    private func run(_ backend: FakeFullscreenBackend) async -> WindowFullscreenTransferResult {
        await WindowFullscreenTransfer.run(action: .nextDisplay, initial: initial, screens: [source, destination], backend: backend)
    }
}

private actor FakeFullscreenBackend: WindowFullscreenTransferBackend {
    enum Mode: Equatable, Sendable { case normal, exitRefusal, exitTimeout, moveRefusal, partialMoveFailure, enterRefusal, disappear, wrongDisplay, pendingExitCancellation, ignoreFirstEnter, slowEnter }
    struct Trace: Sendable {
        let state: WindowFullscreenState?
        let toggles: [Bool]
        let moves: [WindowLayoutRect]
        let pausesBeforeMove: Int
        let nonCancelledRecoveryPauses: Int
        let totalPauses: Int
    }
    let source: WindowLayoutScreen
    let destination: WindowLayoutScreen
    let normal: WindowLayoutRect
    let mode: Mode
    var state: WindowFullscreenState?
    var toggles: [Bool] = []
    var moves: [WindowLayoutRect] = []
    var exitCountdown: Int?
    var enterCountdown: Int?
    var pauses = 0
    var pausesBeforeMove = 0
    var nonCancelledRecoveryPauses = 0
    var observedCancellation = false

    init(source: WindowLayoutScreen, destination: WindowLayoutScreen, normal: WindowLayoutRect, mode: Mode = .normal) {
        self.source = source; self.destination = destination; self.normal = normal; self.mode = mode
        state = .init(isFullscreen: true, frame: source.frame, canMoveAndResize: false)
    }
    func read() -> WindowFullscreenState? { state }
    func hasExited() -> Bool { toggles.contains(false) }
    func markCancellationRequested() { observedCancellation = true }
    func completeDelayedExitIfPending() {
        guard exitCountdown != nil else { return }
        state = .init(isFullscreen: false, frame: normal, canMoveAndResize: true)
        exitCountdown = nil
    }
    func trace() -> Trace { .init(state: state, toggles: toggles, moves: moves,
                                 pausesBeforeMove: pausesBeforeMove, nonCancelledRecoveryPauses: nonCancelledRecoveryPauses, totalPauses: pauses) }
    func setFullscreen(_ enabled: Bool) -> Bool {
        toggles.append(enabled)
        guard state != nil else { return false }
        if enabled {
            guard mode != .enterRefusal else { return false }
            if mode == .ignoreFirstEnter, toggles.filter({ $0 }).count == 1 { return true }
            exitCountdown = nil
            enterCountdown = mode == .slowEnter ? 15 : 3
            if mode == .slowEnter, let current = state {
                state = .init(isFullscreen: false, frame: current.frame, canMoveAndResize: false)
            }
        } else {
            guard mode != .exitRefusal else { return false }
            if mode != .exitTimeout { exitCountdown = 5 }
        }
        return true
    }
    func move(to frame: WindowLayoutRect) -> Bool {
        moves.append(frame)
        pausesBeforeMove = pauses
        if mode == .moveRefusal { return false }
        state = .init(isFullscreen: false, frame: frame, canMoveAndResize: true)
        return mode != .partialMoveFailure
    }
    func pause() async throws {
        if Task.isCancelled { observedCancellation = true; throw CancellationError() }
        if observedCancellation { nonCancelledRecoveryPauses += 1 }
        pauses += 1
        if let count = exitCountdown, mode != .pendingExitCancellation {
            exitCountdown = count - 1
            if count == 3 { state = .init(isFullscreen: false, frame: source.frame, canMoveAndResize: false) }
            if count == 1 {
                state = mode == .disappear ? nil : .init(isFullscreen: false, frame: normal, canMoveAndResize: true)
                exitCountdown = nil
            }
        }
        if let count = enterCountdown, let current = state {
            enterCountdown = count - 1
            if count == 3 { state = .init(isFullscreen: true, frame: current.frame, canMoveAndResize: false) }
            if count == 1 {
                let onDestination = current.frame.x >= destination.frame.x && mode != .wrongDisplay
                state = .init(isFullscreen: true, frame: onDestination ? destination.frame : source.frame, canMoveAndResize: false)
                enterCountdown = nil
            }
        }
        await Task.yield()
    }
}
