import SwiftUI

/// The notch's interface colors are separate from provider brands and status colors.
enum NotchPalette {
    static let surface = Color(red: 16 / 255, green: 26 / 255, blue: 40 / 255)
    static let accent = Color(red: 143 / 255, green: 203 / 255, blue: 255 / 255)
    static let text = Color(red: 237 / 255, green: 244 / 255, blue: 252 / 255)
    static let secondary = Color(red: 137 / 255, green: 154 / 255, blue: 175 / 255)
    static let raised = Color(red: 28 / 255, green: 41 / 255, blue: 58 / 255)
    static let separator = text.opacity(0.10)
    static let track = text.opacity(0.12)
}
