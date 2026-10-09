import AppKit
import Combine

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide appearance inherited by existing and newly created windows.
/// A nil override restores live tracking of the macOS appearance.
@MainActor
final class AppAppearanceSettings: ObservableObject {
    static let shared = AppAppearanceSettings()
    static let preferenceKey = "appearance.theme"

    private let defaults: UserDefaults
    private let applyAppearance: (NSAppearance?) -> Void

    @Published var theme: AppTheme {
        didSet {
            guard theme != oldValue else { return }
            defaults.set(theme.rawValue, forKey: Self.preferenceKey)
            applyCurrentTheme()
        }
    }

    init(defaults: UserDefaults = .standard,
         applyAppearance: @escaping (NSAppearance?) -> Void = { NSApplication.shared.appearance = $0 }) {
        self.defaults = defaults
        self.applyAppearance = applyAppearance
        theme = defaults.string(forKey: Self.preferenceKey).flatMap(AppTheme.init(rawValue:)) ?? .system
    }

    func applyCurrentTheme() {
        applyAppearance(theme.appearance)
    }
}
