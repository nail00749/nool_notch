import AppKit
import Carbon

enum LauncherTabAction: Equatable {
    case select(LauncherCategory)
    case cycle(backwards: Bool)
}

enum LauncherKeyboardShortcuts {
    static func isActions(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_ANSI_K)
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    static func isQuickAI(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)].contains(keyCode)
            && modifiers.intersection([.command, .control, .option, .shift]) == .option
    }

    static func tabAction(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> LauncherTabAction? {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if keyCode == UInt16(kVK_Tab) {
            if modifiers == .control { return .cycle(backwards: false) }
            if modifiers == [.control, .shift] { return .cycle(backwards: true) }
        }
        guard modifiers == .command else { return nil }
        let category: LauncherCategory
        switch Int(keyCode) {
        case kVK_ANSI_1: category = .all
        case kVK_ANSI_2: category = .applications
        case kVK_ANSI_3: category = .files
        case kVK_ANSI_4: category = .clipboard
        case kVK_ANSI_5: category = .ai
        default: return nil
        }
        return .select(category)
    }
}

extension LauncherCategory {
    var keyboardShortcutHint: String {
        switch self {
        case .all: "⌘1"
        case .applications: "⌘2"
        case .files: "⌘3"
        case .clipboard: "⌘4"
        case .ai: "⌘5"
        }
    }
}
