import AppKit
import Combine
import Foundation
import SwiftUI

enum IndicatorColorMode: String, CaseIterable, Identifiable {
    case monochrome
    case gradient

    var id: Self { self }

    var title: String {
        switch self {
        case .monochrome:
            "Монохром"
        case .gradient:
            "Градиент"
        }
    }
}

@MainActor
final class NotchVisualSettings: ObservableObject {
    private enum Key {
        static let lineColor = "notch.visual.lineColor"
        static let lineGradientColor = "notch.visual.lineGradientColor"
        static let lineMode = "notch.visual.lineMode"
        static let showsLine = "notch.visual.showsLine"
        static let pulsesLine = "notch.visual.pulsesLine"
        static let pulseIntensity = "notch.visual.pulseIntensity"
        static let pulseSpeed = "notch.visual.pulseSpeed"
    }

    private let defaults: UserDefaults

    @Published var lineColor: Color {
        didSet { defaults.set(lineColor.rgbaHex, forKey: Key.lineColor) }
    }

    @Published var lineGradientColor: Color {
        didSet { defaults.set(lineGradientColor.rgbaHex, forKey: Key.lineGradientColor) }
    }

    @Published var lineMode: IndicatorColorMode {
        didSet { defaults.set(lineMode.rawValue, forKey: Key.lineMode) }
    }

    @Published var showsLine: Bool {
        didSet { defaults.set(showsLine, forKey: Key.showsLine) }
    }

    @Published var pulsesLine: Bool {
        didSet { defaults.set(pulsesLine, forKey: Key.pulsesLine) }
    }

    @Published var pulseIntensity: Double {
        didSet { defaults.set(pulseIntensity, forKey: Key.pulseIntensity) }
    }

    @Published var pulseSpeed: Double {
        didSet { defaults.set(pulseSpeed, forKey: Key.pulseSpeed) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lineColor = Color(rgbaHex: defaults.string(forKey: Key.lineColor) ?? "57D1FFFF")
        lineGradientColor = Color(rgbaHex: defaults.string(forKey: Key.lineGradientColor) ?? "57D1FFFF")
        lineMode = IndicatorColorMode(rawValue: defaults.string(forKey: Key.lineMode) ?? "") ?? .monochrome
        showsLine = defaults.object(forKey: Key.showsLine) as? Bool ?? true
        pulsesLine = defaults.object(forKey: Key.pulsesLine) as? Bool ?? true
        pulseIntensity = defaults.object(forKey: Key.pulseIntensity) as? Double ?? 1
        pulseSpeed = defaults.object(forKey: Key.pulseSpeed) as? Double ?? 0.55
    }
}

private extension Color {
    init(rgbaHex: String) {
        let normalized = rgbaHex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        let value = UInt64(normalized, radix: 16) ?? 0x57D1FFFF
        let hasAlpha = normalized.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }

    var rgbaHex: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        let alpha = Int((color.alphaComponent * 255).rounded())
        return String(format: "%02X%02X%02X%02X", red, green, blue, alpha)
    }
}
