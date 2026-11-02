import XCTest
@testable import NotchApp

final class WindowFrameApplicationTests: XCTestCase {
    private let original = WindowLayoutRect(x: -1660, y: -1157, width: 2013, height: 1048)
    private let target = WindowLayoutRect(x: -1660, y: -1410, width: 2560, height: 1410)

    func testPositionsBeforeSizeForTheObservedDeviceHubClippingSequence() async {
        let backend = FrameBackend(original: original, target: target, mode: .requiresPositionFirst)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didApply)
        XCTAssertFalse(result.needsRestore)
        XCTAssertEqual(trace.frame, target)
        XCTAssertEqual(trace.operations.prefix(2), ["position", "size"])
    }

    func testReadsSizeAgainAfterPositionEvenIfItPreviouslyMatched() async {
        let target = WindowLayoutRect(x: -1000, y: -1000, width: original.width, height: original.height)
        let backend = FrameBackend(original: original, target: target, mode: .positionResetsSize)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(trace.sizeWrites, 1)
        XCTAssertEqual(trace.frame, target)
    }

    func testRetriesAcknowledgedButIgnoredFirstSizeRequest() async {
        let backend = FrameBackend(original: original, target: target, mode: .ignoreFirstSize)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(trace.sizeWrites, 2)
        XCTAssertEqual(trace.frame, target)
    }

    func testWaitsForDeferredSizeBeforeDeclaringSuccess() async {
        let backend = FrameBackend(original: original, target: target, mode: .deferredSize)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        let trace = await backend.trace()
        XCTAssertTrue(result.didApply)
        XCTAssertEqual(trace.sizeWrites, 1)
        XCTAssertGreaterThanOrEqual(trace.pauses, 4)
        XCTAssertEqual(trace.frame, target)
    }

    func testPermanentSizeConstraintRollsBackAndDoesNotReportSuccess() async {
        let original = WindowLayoutRect(x: 100, y: 100, width: 1200, height: 800)
        let target = WindowLayoutRect(x: 0, y: 0, width: 500, height: 800)
        let backend = FrameBackend(original: original, target: target, mode: .constrained)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        let trace = await backend.trace()
        XCTAssertFalse(result.didApply)
        XCTAssertFalse(result.needsRestore)
        XCTAssertEqual(trace.frame, original)
        XCTAssertLessThanOrEqual(trace.sizeWrites, 4, "Retries and cleanup must remain bounded")
    }

    func testFailedRollbackKeepsRestorePointNeeded() async {
        let original = WindowLayoutRect(x: 100, y: 100, width: 1200, height: 800)
        let target = WindowLayoutRect(x: 0, y: 0, width: 500, height: 800)
        let backend = FrameBackend(original: original, target: target, mode: .rollbackFailure)
        let result = await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend)
        XCTAssertFalse(result.didApply)
        XCTAssertTrue(result.needsRestore)
    }

    func testPositionOnlyNeverWritesSizeOnSuccessOrRollback() async {
        let target = WindowLayoutRect(x: -1000, y: -1000, width: original.width, height: original.height)
        for mode in [FrameBackend.Mode.normal, .positionRefusal] {
            let backend = FrameBackend(original: original, target: target, mode: mode)
            let result = await WindowFrameApplication.run(target: target, original: original, changeSize: false, backend: backend)
            let trace = await backend.trace()
            XCTAssertEqual(result.didApply, mode == .normal)
            XCTAssertEqual(trace.sizeWrites, 0)
        }
    }

    func testCancelledTaskPerformsCancellationIndependentRollback() async {
        let backend = FrameBackend(original: original, target: target, mode: .cancelAfterPosition)
        let target = target, original = original
        let task = Task { await WindowFrameApplication.run(target: target, original: original, changeSize: true, backend: backend) }
        for _ in 0..<1000 {
            if await backend.hasMoved() { break }
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        let trace = await backend.trace()
        XCTAssertFalse(result.didApply)
        XCTAssertFalse(result.needsRestore)
        XCTAssertEqual(trace.frame, original)
        XCTAssertGreaterThan(trace.cleanupPauses, 0, "Rollback cannot spin through waits in the cancelled parent task")
    }
}

private actor FrameBackend: WindowFrameApplicationBackend {
    enum Mode: Equatable, Sendable { case normal, requiresPositionFirst, positionResetsSize, ignoreFirstSize, deferredSize, constrained, rollbackFailure, positionRefusal, cancelAfterPosition }
    struct Trace: Sendable {
        let frame: WindowLayoutRect
        let operations: [String]
        let sizeWrites: Int
        let pauses: Int
        let cleanupPauses: Int
    }
    let original: WindowLayoutRect
    let target: WindowLayoutRect
    let mode: Mode
    var frame: WindowLayoutRect
    var operations: [String] = []
    var sizeWrites = 0
    var pauses = 0
    var cleanupPauses = 0
    var cancellationSeen = false
    var deferredSize: (width: Double, height: Double, remaining: Int)?

    init(original: WindowLayoutRect, target: WindowLayoutRect, mode: Mode) {
        self.original = original; self.target = target; self.mode = mode; frame = original
    }
    func readFrame() -> WindowLayoutRect? { frame }
    func hasMoved() -> Bool { operations.contains("position") }
    func trace() -> Trace { .init(frame: frame, operations: operations, sizeWrites: sizeWrites, pauses: pauses, cleanupPauses: cleanupPauses) }
    func setPosition(x: Double, y: Double) -> Bool {
        operations.append("position")
        if mode == .positionRefusal || (mode == .rollbackFailure && x == original.x && y == original.y) { return false }
        frame.x = x; frame.y = y
        if mode == .positionResetsSize { frame.width = 500; frame.height = 400 }
        return true
    }
    func setSize(width: Double, height: Double) -> Bool {
        operations.append("size")
        sizeWrites += 1
        if mode == .rollbackFailure && width == original.width { return false }
        if mode == .requiresPositionFirst && (frame.x != target.x || frame.y != target.y) { return true }
        if mode == .ignoreFirstSize && sizeWrites == 1 { return true }
        if mode == .deferredSize {
            deferredSize = (width, height, 3)
        } else {
            frame.width = mode == .constrained || mode == .rollbackFailure ? max(900, width) : width
            frame.height = height
        }
        return true
    }
    func pause() async throws {
        pauses += 1
        if mode == .cancelAfterPosition && frame.x == target.x && frame.y == target.y && !cancellationSeen {
            while !Task.isCancelled { await Task.yield() }
            cancellationSeen = true
            throw CancellationError()
        }
        try Task.checkCancellation()
        if cancellationSeen { cleanupPauses += 1 }
        if let pending = deferredSize {
            if pending.remaining <= 1 { frame.width = pending.width; frame.height = pending.height; deferredSize = nil }
            else { deferredSize = (pending.width, pending.height, pending.remaining - 1) }
        }
        await Task.yield()
    }
}
