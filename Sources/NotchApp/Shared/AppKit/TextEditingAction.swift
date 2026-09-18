import AppKit
import Carbon

enum TextEditingAction: Equatable {
    case selectAll, copy, cut, paste, pasteAsPlainText, undo, redo

    @MainActor
    func perform(in editor: NSTextView) {
        switch self {
        case .selectAll: editor.selectAll(nil)
        case .copy: editor.copy(nil)
        case .cut: editor.cut(nil)
        case .paste: editor.paste(nil)
        case .pasteAsPlainText: editor.pasteAsPlainText(nil)
        case .undo: editor.undoManager?.undo()
        case .redo: editor.undoManager?.redo()
        }
    }

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift]
                || modifiers == [.command, .option, .shift] else { return nil }
        var key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Preserve letter-based shortcuts on Latin layouts (including Dvorak),
        // and standard physical Command keys on non-Latin layouts.
        if key.count == 1, key.unicodeScalars.allSatisfy({ !$0.isASCII && CharacterSet.letters.contains($0) }) {
            switch Int(event.keyCode) {
            case kVK_ANSI_A: key = "a"
            case kVK_ANSI_C: key = "c"
            case kVK_ANSI_X: key = "x"
            case kVK_ANSI_V: key = "v"
            case kVK_ANSI_Z: key = "z"
            default: return nil
            }
        }
        switch (key, modifiers) {
        case ("a", .command): self = .selectAll
        case ("c", .command): self = .copy
        case ("x", .command): self = .cut
        case ("v", .command): self = .paste
        case ("v", [.command, .option, .shift]): self = .pasteAsPlainText
        case ("z", .command): self = .undo
        case ("z", [.command, .shift]): self = .redo
        default: return nil
        }
    }
}
