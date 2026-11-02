import XCTest
@testable import NotchApp

final class LiveWallpaperFrameHealthTests: XCTestCase {
    func testFirstObservationStartsGraceEvenWhenCounterIsAlreadyNonzero() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 500, now: 100))
        XCTAssertFalse(policy.observe(frameCount: 500, now: 101.999))
        XCTAssertTrue(policy.observe(frameCount: 500, now: 102))
        XCTAssertFalse(policy.observe(frameCount: 500, now: 102))
        XCTAssertFalse(policy.observe(frameCount: 500, now: 102.001))
    }

    func testNormallyAdvancingSixtyFPSCounterNeverRequestsRecovery() {
        var policy = LiveWallpaperFrameHealth()
        for frame in 0..<1_800 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(frame), now: Double(frame) / 60))
        }
    }

    func testFrozenCounterRequestsRecoveryEvenWhenOwnerReportsUnpaused() {
        var policy = LiveWallpaperFrameHealth()
        // The owner has already checked attachment, visibility and isPaused == false.
        // Simulate the independent symptom: update callbacks have stopped advancing.
        XCTAssertFalse(policy.observe(frameCount: 120, now: 10))
        XCTAssertFalse(policy.observe(frameCount: 180, now: 11))
        XCTAssertFalse(policy.observe(frameCount: 180, now: 12))
        XCTAssertTrue(policy.observe(frameCount: 180, now: 13))
    }

    func testRecoveryRetriesRespectCooldownAndStopAfterThreeAttempts() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 0, now: 0))
        XCTAssertEqual(policy.recoveryAttempts, 0)
        XCTAssertTrue(policy.observe(frameCount: 0, now: 2))
        XCTAssertEqual(policy.recoveryAttempts, 1)
        for time in [2.1, 3.0, 5.0, 10.0, 11.999] {
            XCTAssertFalse(policy.observe(frameCount: 0, now: time))
        }
        XCTAssertTrue(policy.observe(frameCount: 0, now: 12))
        XCTAssertEqual(policy.recoveryAttempts, 2)
        XCTAssertFalse(policy.observe(frameCount: 0, now: 21.999))
        XCTAssertTrue(policy.observe(frameCount: 0, now: 22))
        XCTAssertEqual(policy.recoveryAttempts, 3)
        for time in [22.1, 32.0, 100.0, 10_000.0] {
            XCTAssertFalse(policy.observe(frameCount: 0, now: time), "No unbounded recovery loop")
        }
    }

    func testSustainedFiveSecondProgressRestoresRecoveryBudget() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 3, now: 0))
        XCTAssertTrue(policy.observe(frameCount: 3, now: 2))
        XCTAssertTrue(policy.observe(frameCount: 3, now: 12))
        XCTAssertTrue(policy.observe(frameCount: 3, now: 22))
        XCTAssertFalse(policy.observe(frameCount: 4, now: 23))
        XCTAssertEqual(policy.recoveryAttempts, 3, "One update is not a stable recovery")
        for second in 24...27 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second - 19), now: Double(second)))
            XCTAssertEqual(policy.recoveryAttempts, 3)
        }
        XCTAssertFalse(policy.observe(frameCount: 9, now: 28))
        XCTAssertEqual(policy.recoveryAttempts, 0)
        XCTAssertFalse(policy.observe(frameCount: 9, now: 29.999))
        XCTAssertTrue(policy.observe(frameCount: 9, now: 30))
        XCTAssertFalse(policy.observe(frameCount: 9, now: 39.999))
        XCTAssertTrue(policy.observe(frameCount: 9, now: 40))
        XCTAssertTrue(policy.observe(frameCount: 9, now: 50))
        XCTAssertFalse(policy.observe(frameCount: 9, now: 60))
    }

    func testSingleUpdateAfterEachAttemptCannotBypassCooldownOrAttemptCap() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 0, now: 0))
        XCTAssertTrue(policy.observe(frameCount: 0, now: 2))
        XCTAssertFalse(policy.observe(frameCount: 1, now: 3))
        XCTAssertEqual(policy.recoveryAttempts, 1)
        XCTAssertFalse(policy.observe(frameCount: 1, now: 5))
        XCTAssertFalse(policy.observe(frameCount: 1, now: 11.999))
        XCTAssertTrue(policy.observe(frameCount: 1, now: 12))
        XCTAssertFalse(policy.observe(frameCount: 2, now: 13))
        XCTAssertEqual(policy.recoveryAttempts, 2)
        XCTAssertFalse(policy.observe(frameCount: 2, now: 15))
        XCTAssertTrue(policy.observe(frameCount: 2, now: 22))
        XCTAssertFalse(policy.observe(frameCount: 3, now: 23))
        XCTAssertEqual(policy.recoveryAttempts, 3)
        for time in [25.0, 32.0, 42.0, 100.0] {
            XCTAssertFalse(policy.observe(frameCount: 3, now: time))
        }
    }

    func testUnchangedObservationBreaksTheHealthyProgressWindow() {
        var policy = exhaustedPolicy()
        for second in 23...25 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second), now: Double(second)))
        }
        XCTAssertFalse(policy.observe(frameCount: 25, now: 25.5))
        for second in 26...30 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second), now: Double(second)))
            XCTAssertEqual(policy.recoveryAttempts, 3)
        }
        XCTAssertFalse(policy.observe(frameCount: 31, now: 31))
        XCTAssertEqual(policy.recoveryAttempts, 0)
    }

    func testObservationGapLongerThanTwoSecondsBreaksTheHealthyProgressWindow() {
        var policy = exhaustedPolicy()
        for second in 23...26 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second), now: Double(second)))
        }
        for second in 29...33 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second), now: Double(second)))
            XCTAssertEqual(policy.recoveryAttempts, 3)
        }
        XCTAssertFalse(policy.observe(frameCount: 34, now: 34))
        XCTAssertEqual(policy.recoveryAttempts, 0)
    }

    func testWrappingCounterStillCountsAsProgress() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: UInt64.max, now: 0))
        XCTAssertTrue(policy.observe(frameCount: UInt64.max, now: 2))
        XCTAssertFalse(policy.observe(frameCount: 0, now: 3))
        XCTAssertFalse(policy.observe(frameCount: 1, now: 4))
        XCTAssertFalse(policy.observe(frameCount: 1, now: 5.999))
        XCTAssertFalse(policy.observe(frameCount: 1, now: 6), "Wrap does not bypass the existing cooldown")
        XCTAssertTrue(policy.observe(frameCount: 1, now: 12))
    }

    func testSustainedProgressAcrossCounterWrapRestoresBudget() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: UInt64.max - 1, now: 0))
        XCTAssertTrue(policy.observe(frameCount: UInt64.max - 1, now: 2))
        XCTAssertFalse(policy.observe(frameCount: UInt64.max, now: 3))
        for second in 4...7 {
            XCTAssertFalse(policy.observe(frameCount: UInt64(second - 4), now: Double(second)))
            XCTAssertEqual(policy.recoveryAttempts, 1)
        }
        XCTAssertFalse(policy.observe(frameCount: 4, now: 8))
        XCTAssertEqual(policy.recoveryAttempts, 0)
    }

    func testResetForPauseOrDetachStartsFreshGraceAndClearsAttemptCap() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 10, now: 0))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 2))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 12))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 22))
        policy.reset()
        XCTAssertFalse(policy.observe(frameCount: 10, now: 100), "Time spent paused is not a frame stall")
        XCTAssertFalse(policy.observe(frameCount: 10, now: 101.999))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 102))
        policy.reset()
        XCTAssertFalse(policy.observe(frameCount: 0, now: 200), "A reattached surface gets its own grace period")
        XCTAssertTrue(policy.observe(frameCount: 0, now: 202))
    }

    func testNonfiniteTimesResetWithoutRequestingRecovery() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var policy = LiveWallpaperFrameHealth()
            XCTAssertFalse(policy.observe(frameCount: 10, now: 0))
            XCTAssertTrue(policy.observe(frameCount: 10, now: 2))
            XCTAssertFalse(policy.observe(frameCount: 10, now: invalid))
            XCTAssertFalse(policy.observe(frameCount: 10, now: 20))
            XCTAssertFalse(policy.observe(frameCount: 10, now: 21.999))
            XCTAssertTrue(policy.observe(frameCount: 10, now: 22))
        }
    }

    func testBackwardClockRestartsGraceAndClearsOldCooldown() {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 10, now: 100))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 102))
        XCTAssertFalse(policy.observe(frameCount: 10, now: 5))
        XCTAssertFalse(policy.observe(frameCount: 10, now: 6.999))
        XCTAssertTrue(policy.observe(frameCount: 10, now: 7))
    }

    private func exhaustedPolicy() -> LiveWallpaperFrameHealth {
        var policy = LiveWallpaperFrameHealth()
        XCTAssertFalse(policy.observe(frameCount: 0, now: 0))
        XCTAssertTrue(policy.observe(frameCount: 0, now: 2))
        XCTAssertTrue(policy.observe(frameCount: 0, now: 12))
        XCTAssertTrue(policy.observe(frameCount: 0, now: 22))
        return policy
    }
}
