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

    @MainActor
    func testStopwatchAccumulatesOnlyRunningTimeAndNeverCompletes() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var completions = 0
        var activities: [LiveActivity] = []
        source.onCompletion = { completions += 1 }
        source.onChange = { activities = $0 }
        source.startStopwatch()
        now = now.addingTimeInterval(12.75)
        source.toggle()
        XCTAssertEqual(try XCTUnwrap(source.snapshot?.elapsed), 12.75, accuracy: 0.001)
        XCTAssertEqual(source.snapshot?.countdownText, "00:12")
        XCTAssertEqual(source.snapshot?.state, .paused)
        XCTAssertNil(activities.first?.progress)
        XCTAssertTrue(activities.first?.isCompactEligible ?? false)
        now = now.addingTimeInterval(100)
        source.refresh()
        XCTAssertEqual(try XCTUnwrap(source.snapshot?.elapsed), 12.75, accuracy: 0.001)
        source.toggle()
        now = now.addingTimeInterval(3_600)
        source.refresh()
        XCTAssertEqual(source.snapshot?.countdownText, "1:00:12")
        XCTAssertEqual(source.snapshot?.state, .active)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testStopwatchReconcilesSourceRestartAndClampsClockRegression() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        source.start()
        source.startStopwatch()
        source.stop()
        now = now.addingTimeInterval(20)
        source.start()
        XCTAssertEqual(source.snapshot?.elapsed, 20)
        now = now.addingTimeInterval(-30)
        source.refresh()
        XCTAssertEqual(source.snapshot?.elapsed, 20)
        source.restart()
        XCTAssertEqual(source.snapshot?.elapsed, 0)
        XCTAssertEqual(source.snapshot?.state, .active)
        source.stop()
    }

    @MainActor
    func testPomodoroRequiresExplicitAdvancementAndLongBreakAfterFourthFocus() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var completions = 0
        source.onCompletion = { completions += 1 }
        XCTAssertTrue(source.startPomodoro(focusDuration: 10, shortBreakDuration: 2, longBreakDuration: 5))
        for round in 1...4 {
            XCTAssertEqual(source.snapshot?.pomodoroRound, round)
            XCTAssertEqual(source.snapshot?.pomodoroPhase, .focus)
            source.advancePomodoro()
            XCTAssertEqual(source.snapshot?.pomodoroPhase, .focus)
            now = now.addingTimeInterval(10)
            source.refresh()
            source.refresh()
            XCTAssertEqual(source.snapshot?.state, .completed)
            XCTAssertEqual(completions, round * 2 - 1)
            source.advancePomodoro()
            XCTAssertEqual(source.snapshot?.pomodoroPhase, round == 4 ? .longBreak : .shortBreak)
            XCTAssertEqual(source.snapshot?.pomodoroRound, round)
            now = now.addingTimeInterval(round == 4 ? 5 : 2)
            source.refresh()
            source.advancePomodoro()
        }
        XCTAssertEqual(source.snapshot?.pomodoroRound, 5)
        XCTAssertEqual(source.snapshot?.pomodoroPhase, .focus)
        XCTAssertEqual(source.snapshot?.state, .active)
        XCTAssertEqual(completions, 8)
    }

    @MainActor
    func testRestartRepeatsCurrentPomodoroPhaseAndCompletionCanFireAgain() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        var completions = 0
        source.onCompletion = { completions += 1 }
        XCTAssertTrue(source.startPomodoro(focusDuration: 10, shortBreakDuration: 2))
        now = now.addingTimeInterval(10)
        source.refresh()
        source.advancePomodoro()
        now = now.addingTimeInterval(1)
        source.toggle()
        source.restart()
        XCTAssertEqual(source.snapshot?.mode, .pomodoro)
        XCTAssertEqual(source.snapshot?.pomodoroPhase, .shortBreak)
        XCTAssertEqual(source.snapshot?.pomodoroRound, 1)
        XCTAssertEqual(source.snapshot?.remaining, 2)
        XCTAssertEqual(source.snapshot?.state, .active)
        now = now.addingTimeInterval(2)
        source.refresh()
        source.restart()
        now = now.addingTimeInterval(2)
        source.refresh()
        source.refresh()
        XCTAssertEqual(completions, 3)
    }

    @MainActor
    func testInvalidPomodoroDurationsPreserveExistingTimer() throws {
        let now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        XCTAssertTrue(source.create(duration: 60))
        let original = source.snapshot
        for value in [0, -1, .infinity, .nan, NoolTimerSource.maximumDuration + 1] {
            XCTAssertFalse(source.startPomodoro(focusDuration: value))
            XCTAssertFalse(source.startPomodoro(shortBreakDuration: value))
            XCTAssertFalse(source.startPomodoro(longBreakDuration: value))
            XCTAssertEqual(source.snapshot, original)
        }
        XCTAssertFalse(source.startPomodoro(sessionsBeforeLongBreak: 0))
        XCTAssertEqual(source.snapshot, original)
    }

    @MainActor
    func testRestartOrdinaryTimerRepeatsOriginalDuration() throws {
        var now = try date("2026-09-07T12:00:00Z")
        let source = NoolTimerSource(now: { now })
        XCTAssertTrue(source.create(duration: 60))
        now = now.addingTimeInterval(15)
        source.toggle()
        source.restart()
        XCTAssertEqual(source.snapshot?.remaining, 60)
        XCTAssertEqual(source.snapshot?.endsAt, now.addingTimeInterval(60))
        XCTAssertEqual(source.snapshot?.state, .active)
        XCTAssertEqual(source.snapshot?.mode, .timer)
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }
}
