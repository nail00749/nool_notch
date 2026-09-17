import XCTest
import ApplicationServices
@testable import NotchApp

@MainActor
final class LauncherTextSelectionTests: XCTestCase {
    func testPermissionDenialDoesNotReadOrCaptureText() {
        let selection = LauncherTextSelection(isTrusted: { false }, read: { _ in
            XCTFail("Reading another app must require Accessibility trust")
            return .text("private", target: Self.target())
        })
        selection.capture(pid: 123)
        XCTAssertTrue(selection.needsPermission)
        XCTAssertNil(selection.text)
        XCTAssertFalse(selection.isReading)
    }

    func testCapturePreservesSelectedTextAndRequiresExactMatchBeforeInsertion() async throws {
        let selection = LauncherTextSelection(isTrusted: { true }, read: { _ in .text(" selected\ntext ", target: Self.target()) })
        selection.capture(pid: 123)
        try await finish(selection)
        XCTAssertEqual(selection.text, " selected\ntext ")
        let matches = await selection.stillMatches(pid: 123, expected: " selected\ntext ")
        let changed = await selection.stillMatches(pid: 123, expected: "changed")
        XCTAssertTrue(matches)
        XCTAssertFalse(changed)
    }

    func testProtectedAndOversizedSelectionsAreNotExposed() async throws {
        for result in [LauncherSelectionRead.protectedField, .text(String(repeating: "a", count: 7_001), target: Self.target()), .tooLong] {
            let selection = LauncherTextSelection(isTrusted: { true }, read: { _ in result })
            selection.capture(pid: 123)
            try await finish(selection)
            XCTAssertNil(selection.text)
        }
    }

    func testClearingInvalidatesInFlightCapture() async throws {
        let selection = LauncherTextSelection(isTrusted: { true }, read: { _ in
            Thread.sleep(forTimeInterval: 0.03)
            return .text("stale", target: Self.target())
        })
        selection.capture(pid: 123)
        selection.clear()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(selection.text)
        XCTAssertFalse(selection.isReading)
    }

    func testActionsPrepareBoundedPromptWithoutChangingSourceText() {
        let text = String(repeating: "a", count: 7_000)
        for action in LauncherTextAction.allCases {
            XCTAssertTrue(action.prompt(text).hasSuffix(text))
            XCTAssertLessThan(action.prompt(text).count, 8_000)
        }
    }

    func testIdenticalTextAtDifferentTargetIsNotTheSameSelection() {
        let original = LauncherSelectionRead.text("OK", target: Self.target())
        XCTAssertNotEqual(original, .text("OK", target: Self.target(location: 10)))
        XCTAssertNotEqual(original, .text("OK", target: Self.target(pid: 456)))
    }

    nonisolated private static func target(pid: pid_t = 123, location: Int = 0) -> LauncherSelectionTarget {
        LauncherSelectionTarget(element: AXUIElementCreateApplication(pid), range: CFRange(location: location, length: 2))
    }

    private func finish(_ selection: LauncherTextSelection) async throws {
        for _ in 0..<100 where selection.isReading { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(selection.isReading)
    }
}
