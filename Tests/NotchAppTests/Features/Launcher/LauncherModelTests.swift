import XCTest
@testable import NotchApp

final class LauncherModelTests: XCTestCase {
    @MainActor
    func testChangingInputImmediatelyInvalidatesTheActionableSelection() async throws {
        let suite = "launcher-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LauncherModel(settings: LauncherSettings(defaults: defaults))
        model.query = "1 + 1"
        for _ in 0..<100 where model.selectedResult == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selectedResult?.payload, .calculation("2"))
        model.query = "4 + 4"
        XCTAssertNil(model.selectedResult, "Return must not activate the previous expression during ranking")
        for _ in 0..<100 where model.selectedResult == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selectedResult?.payload, .calculation("8"))
        model.category = .files
        XCTAssertNil(model.selectedResult, "Switching scope must immediately invalidate the previous action")
        model.dismiss()
    }

    func testSelectionSurvivesAsyncResultUpdatesAndFallsBackWhenRemoved() {
        XCTAssertEqual(LauncherSelection.preserved(current: "second", ids: ["first", "second"]), "second")
        XCTAssertEqual(LauncherSelection.preserved(current: "second", ids: ["first"]), "first")
        XCTAssertNil(LauncherSelection.preserved(current: "second", ids: []))
    }

    func testKeyboardMovementStaysWithinAvailableResults() {
        XCTAssertEqual(LauncherSelection.moved(current: nil, offset: 1, ids: ["a", "b"]), "a")
        XCTAssertEqual(LauncherSelection.moved(current: "a", offset: -1, ids: ["a", "b"]), "a")
        XCTAssertEqual(LauncherSelection.moved(current: "b", offset: 1, ids: ["a", "b"]), "b")
        XCTAssertNil(LauncherSelection.moved(current: "b", offset: 1, ids: []))
    }

    func testClipboardSearchFindsTextBeyondTheDisplayedFirstLine() {
        let item = LauncherClipboardItem(id: UUID(), text: "Header\n" + String(repeating: "x", count: 200) + " needle",
                                        imageData: nil, createdAt: Date())
        let results = LauncherModel.searchResults([], clipboard: [item], query: "needle", category: .clipboard)
        XCTAssertEqual(results.map(\.payload), [.clipboard(item.id)])
    }

    func testEmptyClipboardQueryPreservesNewestFirstOrder() {
        let latest = LauncherClipboardItem(id: UUID(), text: "Zulu", imageData: nil, createdAt: Date())
        let older = LauncherClipboardItem(id: UUID(), text: "Alpha", imageData: nil, createdAt: Date().addingTimeInterval(-100))
        let results = LauncherModel.searchResults([], clipboard: [latest, older], query: "", category: .clipboard)
        XCTAssertEqual(results.map(\.payload), [.clipboard(latest.id), .clipboard(older.id)])
    }

    func testArithmeticOnlyAppearsInAllCategory() {
        XCTAssertEqual(LauncherModel.searchResults([], clipboard: [], query: "24 * 7", category: .all).first?.payload, .calculation("168"))
        XCTAssertTrue(LauncherModel.searchResults([], clipboard: [], query: "24 * 7", category: .files).isEmpty)
    }

    func testNoolMetadataMatchesRemainVisibleOnlyInAllScope() {
        let event = CalendarEvent(id: "meeting", title: "Обсуждение", startDate: .distantFuture,
                                  endDate: .distantFuture, isAllDay: false, calendarTitle: "Команда")
        let match = LauncherResult(nool: .event(event))
        XCTAssertEqual(match.payload, .nool(id: "calendar:meeting", kind: .event))
        // UnifiedSearch already matched hidden metadata; the launcher must not filter it a second time.
        XCTAssertEqual(LauncherModel.searchResults([], clipboard: [], query: "metadata", category: .all, nool: [match]), [match])
        for category in [LauncherCategory.applications, .files, .clipboard, .ai] {
            XCTAssertTrue(LauncherModel.searchResults([], clipboard: [], query: "metadata", category: category, nool: [match]).isEmpty)
        }
        XCTAssertTrue(LauncherModel.searchResults([], clipboard: [], query: " ", category: .all, nool: [match]).isEmpty)
    }
}
