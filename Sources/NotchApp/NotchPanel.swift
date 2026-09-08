import AppKit

@MainActor
final class NotchPanel: NSPanel {
    var acceptsKeyboardFocus = false
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Accessory panels have no Edit menu to route standard text shortcuts.
        if acceptsKeyboardFocus,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            switch event.keyCode {
            case 0: editor.selectAll(nil)
            case 8: editor.copy(nil)
            case 9: editor.paste(nil)
            case 7: editor.cut(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
