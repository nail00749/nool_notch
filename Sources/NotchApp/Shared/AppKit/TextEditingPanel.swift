import AppKit

/// Accessory-app panels have no main Edit menu to route standard text commands.
class TextEditingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleTextEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handleTextEditingShortcut(event) { return }
        super.sendEvent(event)
    }

    private func handleTextEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let action = TextEditingAction(event: event),
              let editor = activeTextEditor else { return false }
        action.perform(in: editor)
        return true
    }

    private var activeTextEditor: NSTextView? {
        if let editor = firstResponder as? NSTextView { return editor }
        if let field = firstResponder as? NSTextField {
            if let editor = field.currentEditor() as? NSTextView { return editor }
            field.selectText(nil)
            return field.currentEditor() as? NSTextView
        }
        return nil
    }
}
