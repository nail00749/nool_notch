import AppKit
import Carbon
import XCTest
@testable import NotchApp

@MainActor
final class LauncherTextInputTests: XCTestCase {
    func testSearchSelectAllWorksThroughKeyEquivalentAndDirectKeyDown() throws {
        let panel = makePanel()
        let field = makeSearchField()
        panel.contentView?.addSubview(field)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        for direct in [false, true] {
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            let event = key("a", code: kVK_ANSI_A, window: panel)
            if direct { panel.sendEvent(event) }
            else { XCTAssertTrue(panel.performKeyEquivalent(with: event)) }
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (field.stringValue as NSString).length))
        }
    }

    func testChatSelectAllSupportsRussianLayoutAndMultilineText() {
        let panel = makePanel()
        let editor = NSTextView(frame: panel.contentView!.bounds)
        editor.string = "Привет AI\nВторая строка 👋"
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        panel.sendEvent(key("ф", code: kVK_ANSI_A, window: panel))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (editor.string as NSString).length))
    }

    func testUndoAndRedoReachSearchFieldEditor() throws {
        let panel = makePanel()
        let field = makeSearchField()
        panel.contentView?.addSubview(field)
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let original = editor.string
        XCTAssertTrue(editor.allowsUndo)
        editor.undoManager?.beginUndoGrouping()
        editor.insertText("Новый запрос", replacementRange: NSRange(location: 0, length: (original as NSString).length))
        editor.undoManager?.endUndoGrouping()
        XCTAssertTrue(panel.performKeyEquivalent(with: key("z", code: kVK_ANSI_Z, window: panel)))
        XCTAssertEqual(editor.string, original)
        XCTAssertTrue(panel.performKeyEquivalent(with: key("Z", code: kVK_ANSI_Z, modifiers: [.command, .shift], window: panel)))
        XCTAssertEqual(editor.string, "Новый запрос")
    }

    func testUndoAndRedoReachFocusedChatEditorExactlyOnce() {
        let panel = makePanel()
        let editor = NSTextView(frame: panel.contentView!.bounds)
        editor.allowsUndo = true
        editor.string = "Original"
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.undoManager?.beginUndoGrouping()
        editor.insertText(" replacement", replacementRange: NSRange(location: 8, length: 0))
        editor.undoManager?.endUndoGrouping()
        panel.sendEvent(key("z", code: kVK_ANSI_Z, window: panel))
        XCTAssertEqual(editor.string, "Original")
        panel.sendEvent(key("Z", code: kVK_ANSI_Z, modifiers: [.command, .shift], window: panel))
        XCTAssertEqual(editor.string, "Original replacement")
    }

    func testClipboardCommandsReachFocusedEditorWithoutTouchingSystemClipboard() {
        let panel = makePanel()
        let editor = ClipboardCommandRecorder(frame: panel.contentView!.bounds)
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        panel.sendEvent(key("c", code: kVK_ANSI_C, window: panel))
        panel.sendEvent(key("x", code: kVK_ANSI_X, window: panel))
        panel.sendEvent(key("v", code: kVK_ANSI_V, window: panel))
        panel.sendEvent(key("V", code: kVK_ANSI_V, modifiers: [.command, .option, .shift], window: panel))
        XCTAssertEqual(editor.commands, ["copy", "cut", "paste", "plainPaste"])
    }

    func testEditingShortcutsPreserveNavigationTabSwitchingAndOtherModifiers() {
        let panel = makePanel()
        for flags: NSEvent.ModifierFlags in [[], .shift, .control, .option, [.command, .control], [.command, .shift]] {
            XCTAssertNil(TextEditingAction(event: key("a", code: kVK_ANSI_A, modifiers: flags, window: panel)))
        }
        XCTAssertNil(TextEditingAction(event: key("5", code: kVK_ANSI_5, window: panel)))
        XCTAssertNil(TextEditingAction(event: key("\u{f702}", code: kVK_LeftArrow, window: panel)))
        XCTAssertEqual(TextEditingAction(event: key("A", code: kVK_ANSI_A, modifiers: [.command, .capsLock], window: panel)), .selectAll)
        // Latin alternative layouts follow their letters, not ANSI positions.
        XCTAssertEqual(TextEditingAction(event: key("a", code: kVK_ANSI_Q, window: panel)), .selectAll)
        XCTAssertNil(TextEditingAction(event: key("q", code: kVK_ANSI_A, window: panel)))
    }

    func testSearchDrawingAndFieldEditorAreVerticallyCentered() throws {
        let panel = makePanel()
        let field = makeSearchField()
        panel.contentView?.addSubview(field)
        let cell = try XCTUnwrap(field.cell)
        for text in ["", "Поиск", String(repeating: "long query ", count: 20)] {
            field.stringValue = text
            let rect = cell.drawingRect(forBounds: field.bounds)
            XCTAssertEqual(rect.midY, field.bounds.midY, accuracy: 0.5)
            XCTAssertLessThan(rect.height, field.bounds.height)
        }
        field.stringValue = "Поиск"
        XCTAssertTrue(panel.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let editorRect = editor.convert(editor.bounds, to: field)
        XCTAssertEqual(editorRect.midY, field.bounds.midY, accuracy: 1)
        XCTAssertGreaterThan(editorRect.height, 20)
    }

    private func makePanel() -> LauncherPanel {
        _ = NSApplication.shared
        let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 492),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeSearchField() -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 480, height: 38))
        field.cell = VerticallyCenteredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = .systemFont(ofSize: 23)
        field.placeholderAttributedString = NSAttributedString(string: "Поиск в Nool…", attributes: [.font: field.font!])
        field.stringValue = "Проверка поиска"
        return field
    }

    private func key(_ characters: String, code: Int, modifiers: NSEvent.ModifierFlags = .command, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: UInt16(code))!
    }
}

private final class ClipboardCommandRecorder: NSTextView {
    var commands: [String] = []
    override func copy(_ sender: Any?) { commands.append("copy") }
    override func cut(_ sender: Any?) { commands.append("cut") }
    override func paste(_ sender: Any?) { commands.append("paste") }
    override func pasteAsPlainText(_ sender: Any?) { commands.append("plainPaste") }
}
