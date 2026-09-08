import Foundation
import XCTest
@testable import NotchApp

final class NoolTimerTests: XCTestCase {
    @MainActor
    func testRejectsZeroAndOverDayDurations() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })

        XCTAssertFalse(source.create(duration: 0))
        XCTAssertFalse(source.create(duration: 24 * 60 * 60 + 1))
        XCTAssertNil(source.snapshot)
    }

    @MainActor
    func testAcceptsTwentyFourHourDuration() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })

        XCTAssertTrue(source.create(duration: 24 * 60 * 60))
        XCTAssertEqual(source.snapshot?.countdownText, "24:00:00")
    }

    @MainActor
    func testPauseRetainsFractionalRemainingTimeAndResumeUsesIt() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        source.start()
        XCTAssertTrue(source.create(duration: 100))

        now = now.addingTimeInterval(25.25)
        source.toggle()
        let pausedRemaining = try XCTUnwrap(source.snapshot?.remaining)
        XCTAssertEqual(source.snapshot?.state, .paused)
        XCTAssertNil(source.snapshot?.endsAt)
        XCTAssertEqual(pausedRemaining, 74.75, accuracy: 0.001)

        now = now.addingTimeInterval(10)
        source.refresh()
        XCTAssertEqual(try XCTUnwrap(source.snapshot?.remaining), 74.75, accuracy: 0.001)

        source.toggle()
        XCTAssertEqual(source.snapshot?.state, .active)
        XCTAssertEqual(source.snapshot?.endsAt, now.addingTimeInterval(74.75))

        now = now.addingTimeInterval(14.75)
        source.refresh()
        XCTAssertEqual(try XCTUnwrap(source.snapshot?.remaining), 60, accuracy: 0.001)
    }

    @MainActor
    func testStartReconcilesAnExpiredTimerAfterSourceRestart() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        source.start()
        XCTAssertTrue(source.create(duration: 10))
        source.stop()

        now = now.addingTimeInterval(11)
        source.start()

        XCTAssertEqual(source.snapshot?.state, .completed)
        XCTAssertEqual(source.snapshot?.remaining, 0)
    }

    @MainActor
    func testCancelClearsSnapshotAndEmitsNoActivities() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var emissions: [[LiveActivity]] = []
        source.onChange = { emissions.append($0) }
        source.start()
        XCTAssertTrue(source.create(duration: 60))

        source.cancel()

        XCTAssertNil(source.snapshot)
        XCTAssertEqual(emissions.last, [])
    }

    @MainActor
    func testCompletionIsReportedOnceAndIsNoLongerCompactEligible() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var completionCount = 0
        var emissions: [[LiveActivity]] = []
        source.onCompletion = { completionCount += 1 }
        source.onChange = { emissions.append($0) }
        source.start()
        XCTAssertTrue(source.create(duration: 1))

        now = now.addingTimeInterval(1)
        source.refresh()
        source.refresh()

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(source.snapshot?.state, .completed)
        XCTAssertEqual(emissions.last?.first?.kind, .timer)
        XCTAssertEqual(emissions.last?.first?.state, .completed)
        XCTAssertFalse(emissions.last?.first?.isCompactEligible ?? true)
    }

    @MainActor
    func testPausedTimerRemainsCompactEligibleAndOnlyEmitsTimerActivities() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var emissions: [[LiveActivity]] = []
        source.onChange = { emissions.append($0) }
        source.start()
        XCTAssertTrue(source.create(duration: 60))

        source.toggle()

        XCTAssertTrue(emissions.flatMap { $0 }.allSatisfy { $0.kind == .timer })
        XCTAssertEqual(emissions.last?.first?.state, .paused)
        XCTAssertTrue(emissions.last?.first?.isCompactEligible ?? false)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }
}
