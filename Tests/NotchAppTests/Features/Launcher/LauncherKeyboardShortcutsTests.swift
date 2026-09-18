import AppKit
import Carbon
import XCTest
@testable import NotchApp

final class LauncherKeyboardShortcutsTests: XCTestCase {
    func testQuickAIRequiresOptionReturnAndDoesNotStealPasteOrRegularReturn() {
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            XCTAssertTrue(LauncherKeyboardShortcuts.isQuickAI(keyCode: UInt16(key), modifiers: .option))
            XCTAssertTrue(LauncherKeyboardShortcuts.isQuickAI(keyCode: UInt16(key), modifiers: [.option, .capsLock]))
            for flags: NSEvent.ModifierFlags in [[], .command, .shift, .control, [.option, .command], [.option, .shift]] {
                XCTAssertFalse(LauncherKeyboardShortcuts.isQuickAI(keyCode: UInt16(key), modifiers: flags))
            }
        }
        XCTAssertFalse(LauncherKeyboardShortcuts.isQuickAI(keyCode: UInt16(kVK_Tab), modifiers: .option))
    }

    func testCommandNumbersSelectEveryTabIncludingAI() {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for (key, category) in zip(keys, LauncherCategory.allCases) {
            XCTAssertEqual(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(key), modifiers: .command), .select(category))
        }
        XCTAssertEqual(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_ANSI_5), modifiers: [.command, .capsLock]), .select(.ai))
    }

    func testControlTabCyclesInBothDirections() {
        XCTAssertEqual(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_Tab), modifiers: .control), .cycle(backwards: false))
        XCTAssertEqual(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_Tab), modifiers: [.control, .shift]), .cycle(backwards: true))
    }

    func testTypingEditingAndSystemShortcutsAreNotConsumed() {
        for flags: NSEvent.ModifierFlags in [[], .shift, .option, .control, [.command, .shift], [.command, .option]] {
            XCTAssertNil(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_ANSI_1), modifiers: flags))
        }
        XCTAssertNil(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_LeftArrow), modifiers: .command))
        XCTAssertNil(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_Tab), modifiers: .command))
        XCTAssertNil(LauncherKeyboardShortcuts.tabAction(keyCode: UInt16(kVK_ANSI_6), modifiers: .command))
    }
}
