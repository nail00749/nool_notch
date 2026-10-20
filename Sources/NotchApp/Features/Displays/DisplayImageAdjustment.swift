import Foundation

struct DisplayImageAdjustment: Codable, Equatable, Sendable {
    var gamma: Double
    var contrast: Double
    var temperature: Double
    var red: Double
    var green: Double
    var blue: Double

    static let neutral = DisplayImageAdjustment()

    init(gamma: Double = 1, contrast: Double = 1, temperature: Double = 0,
         red: Double = 1, green: Double = 1, blue: Double = 1) {
        self.gamma = gamma
        self.contrast = contrast
        self.temperature = temperature
        self.red = red
        self.green = green
        self.blue = blue
    }

    var sanitized: DisplayImageAdjustment {
        Self(gamma: Self.clamp(gamma, to: 0.5...2, fallback: 1),
             contrast: Self.clamp(contrast, to: 0.5...1.5, fallback: 1),
             temperature: Self.clamp(temperature, to: -1...1, fallback: 0),
             red: Self.clamp(red, to: 0...1, fallback: 1),
             green: Self.clamp(green, to: 0...1, fallback: 1),
             blue: Self.clamp(blue, to: 0...1, fallback: 1))
    }

    var isNeutral: Bool { sanitized == .neutral }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
