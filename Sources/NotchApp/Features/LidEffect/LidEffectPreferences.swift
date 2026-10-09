import Foundation

struct LidEffectPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var startAngle: Double = 70
    var blurRadius: Double = 20
    var dimming: Double = 0.65

    var sanitized: Self {
        var copy = self
        copy.startAngle = startAngle.isFinite ? min(110, max(35, startAngle)) : 70
        copy.blurRadius = blurRadius.isFinite ? min(40, max(0, blurRadius)) : 20
        copy.dimming = dimming.isFinite ? min(0.85, max(0, dimming)) : 0.65
        return copy
    }
}

enum LidEffectPolicy {
    static func progress(angle: Double?, startAngle: Double) -> Double {
        guard let angle, angle.isFinite, (0...180).contains(angle), startAngle.isFinite else { return 0 }
        let start = min(110, max(35, startAngle))
        let linear = min(1, max(0, (start - angle) / (start - 10)))
        return linear * linear * (3 - 2 * linear)
    }

    static func previewProgress(elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed >= 0, elapsed < 3 else { return 0 }
        let linear = elapsed < 1.5 ? elapsed / 1.5 : (3 - elapsed) / 1.5
        return linear * linear * (3 - 2 * linear)
    }
}
