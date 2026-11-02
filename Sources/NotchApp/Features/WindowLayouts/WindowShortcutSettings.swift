import Carbon
import Combine
import Foundation

@MainActor
final class WindowShortcutSettings: ObservableObject {
    @Published var enabled: Bool { didSet { save() } }
    @Published private(set) var bindings: [String: LauncherShortcut]
    @Published var recordingAction: WindowLayoutAction? { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private let defaults: UserDefaults
    private static let key = "nool.windowShortcuts.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.key + ".enabled") as? Bool ?? true
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: LauncherShortcut].self, from: data) {
            bindings = saved.filter { WindowLayoutAction(rawValue: $0.key) != nil && $0.value.isValid }
        } else {
            bindings = Self.standardBindings
        }
    }

    func shortcut(for action: WindowLayoutAction) -> LauncherShortcut? { bindings[action.rawValue] }

    func assign(_ shortcut: LauncherShortcut?, to action: WindowLayoutAction,
                launcher: LauncherShortcut) -> String? {
        if let shortcut {
            guard shortcut.isValid else { return "Добавьте ⌘, ⌥ или ⌃ к сочетанию." }
            if Self.matches(shortcut, launcher) { return "Это сочетание открывает Launcher. Выберите другое." }
            if let conflict = WindowLayoutAction.allCases.first(where: {
                $0 != action && bindings[$0.rawValue].map { Self.matches($0, shortcut) } == true
            }) { return "Это сочетание уже назначено: \(conflict.title)." }
            bindings[action.rawValue] = shortcut
        } else {
            bindings.removeValue(forKey: action.rawValue)
        }
        save()
        return nil
    }

    func reset() { bindings = Self.standardBindings; save() }

    static func matches(_ lhs: LauncherShortcut, _ rhs: LauncherShortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static var standardBindings: [String: LauncherShortcut] {
        let modifiers = UInt32(controlKey | optionKey)
        func key(_ code: Int, _ label: String, shift: Bool = false) -> LauncherShortcut {
            LauncherShortcut(keyCode: UInt32(code), modifiers: modifiers | (shift ? UInt32(shiftKey) : 0), keyLabel: label)
        }
        return [
            WindowLayoutAction.left.rawValue: key(kVK_LeftArrow, "←"),
            WindowLayoutAction.right.rawValue: key(kVK_RightArrow, "→"),
            WindowLayoutAction.maximize.rawValue: key(kVK_UpArrow, "↑"),
            WindowLayoutAction.restore.rawValue: key(kVK_DownArrow, "↓"),
            WindowLayoutAction.center.rawValue: key(kVK_Return, "Return"),
            WindowLayoutAction.previousDisplay.rawValue: key(kVK_LeftArrow, "←", shift: true),
            WindowLayoutAction.nextDisplay.rawValue: key(kVK_RightArrow, "→", shift: true),
            WindowLayoutAction.topLeft.rawValue: key(kVK_ANSI_U, "U"),
            WindowLayoutAction.topRight.rawValue: key(kVK_ANSI_I, "I"),
            WindowLayoutAction.bottomLeft.rawValue: key(kVK_ANSI_J, "J"),
            WindowLayoutAction.bottomRight.rawValue: key(kVK_ANSI_K, "K"),
            WindowLayoutAction.leftThird.rawValue: key(kVK_ANSI_1, "1"),
            WindowLayoutAction.centerThird.rawValue: key(kVK_ANSI_2, "2"),
            WindowLayoutAction.rightThird.rawValue: key(kVK_ANSI_3, "3"),
            WindowLayoutAction.leftTwoThirds.rawValue: key(kVK_ANSI_4, "4"),
            WindowLayoutAction.rightTwoThirds.rawValue: key(kVK_ANSI_5, "5")
        ]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.key) }
        defaults.set(enabled, forKey: Self.key + ".enabled")
        onChange?()
    }
}
