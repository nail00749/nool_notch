import Foundation

/// A bounded recovery policy for an eligible, attached and playing wallpaper surface.
/// The owner supplies a monotonic clock and resets this state while paused or detached.
/// Observing a stall is a recovery heuristic, not proof of a particular native renderer bug.
struct LiveWallpaperFrameHealth: Sendable {
    private var lastFrameCount: UInt64?
    private var lastObservationTime: TimeInterval?
    private var lastProgressTime: TimeInterval?
    private var lastRecoveryTime: TimeInterval?
    private var healthyProgressStart: TimeInterval?
    private(set) var recoveryAttempts = 0

    mutating func reset() {
        lastFrameCount = nil
        lastObservationTime = nil
        lastProgressTime = nil
        lastRecoveryTime = nil
        healthyProgressStart = nil
        recoveryAttempts = 0
    }

    mutating func observe(frameCount: UInt64, now: TimeInterval) -> Bool {
        guard now.isFinite else { reset(); return false }
        if let lastObservationTime, now < lastObservationTime { reset() }
        let previousObservationTime = lastObservationTime
        lastObservationTime = now

        guard let lastFrameCount else {
            self.lastFrameCount = frameCount
            lastProgressTime = now
            return false
        }
        if frameCount != lastFrameCount {
            self.lastFrameCount = frameCount
            lastProgressTime = now
            let observationGap = previousObservationTime.map { now - $0 } ?? .infinity
            if healthyProgressStart == nil || observationGap > 2 {
                healthyProgressStart = now
            }
            // A restart can produce one update and freeze again. Only sustained observations
            // of progress restore the budget; brief progress retains the retry cooldown/cap.
            if let healthyProgressStart, now - healthyProgressStart >= 5 {
                lastRecoveryTime = nil
                recoveryAttempts = 0
            }
            return false
        }

        healthyProgressStart = nil

        guard let lastProgressTime, now - lastProgressTime >= 2,
              recoveryAttempts < 3 else { return false }
        if let lastRecoveryTime, now - lastRecoveryTime < 10 { return false }
        lastRecoveryTime = now
        recoveryAttempts += 1
        return true
    }
}
