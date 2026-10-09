import SwiftUI

/// Semantic macOS colors follow the current appearance and user's accent color.
/// Provider brands and status colors remain separate from interface surfaces.
enum NotchPalette {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let accent = Color.accentColor
    static let text = Color.primary
    static let secondary = Color.secondary
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let track = Color(nsColor: .quaternaryLabelColor)
}
