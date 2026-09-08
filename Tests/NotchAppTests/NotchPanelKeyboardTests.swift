import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class NotchPanelKeyboardTests: XCTestCase {
    func testRussianCommandAWithCapsLockSelectsAllInFieldEditor() throws {
        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.acceptsKeyboardFocus = true
        XCTAssertTrue(panel.canBecomeKey)

        let contentView = NSView(frame: panel.frame)
        let editor = NSTextView(frame: contentView.bounds)
        editor.isFieldEditor = true
        editor.string = "Текст для выделения"
        contentView.addSubview(editor)
        panel.contentView = contentView
        XCTAssertTrue(panel.makeFirstResponder(editor))
        XCTAssertTrue(panel.firstResponder === editor)

        let commandA = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command, .capsLock],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "ф",
                charactersIgnoringModifiers: "ф",
                isARepeat: false,
                keyCode: 0
            )
        )

        XCTAssertTrue(panel.performKeyEquivalent(with: commandA))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
    }
}
