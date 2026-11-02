import AppKit
import Combine
import XCTest
@testable import NotchApp

final class LauncherModelTests: XCTestCase {
    @MainActor
    func testSourceUpdatesWaitForPresentationAndUnchangedResultsDoNotPublish() async throws {
        let suite = "launcher-source-publications-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        pasteboard.clearContents()
        let clipboard = LauncherClipboardStore(persistenceURL: directory.appendingPathComponent("history.json"),
                                                pasteboard: pasteboard)
        defer { clipboard.stop() }
        let settings = LauncherSettings(defaults: defaults)
        settings.clipboardEnabled = true
        clipboard.configure(enabled: true, limit: 100, retentionDays: 7)
        await clipboard.waitForPersistence()
        let model = LauncherModel(settings: settings, clipboard: clipboard, snippets: LauncherSnippetStore(url: nil))
        defer { model.dismiss() }
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        pasteboard.clearContents()
        pasteboard.setString("saved while closed", forType: .string)
        clipboard.captureIfChanged()
        await clipboard.waitForPersistence()
        for _ in 0..<20 { model.clipboard.objectWillChange.send() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(publications, 0, "A hidden launcher must not rank source notifications")
        XCTAssertTrue(model.results.isEmpty)

        model.present()
        model.category = .clipboard
        for _ in 0..<100 where model.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.results.map(\.title), ["saved while closed"])
        // Allow the application scan started by present() to settle; in the
        // clipboard category it cannot change any visible result or status.
        try await Task.sleep(for: .milliseconds(150))
        publications = 0
        for _ in 0..<20 { model.clipboard.objectWillChange.send() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(publications, 0, "Identical rankings and status must not invalidate the visible view")

        pasteboard.clearContents()
        pasteboard.setString("saved while open", forType: .string)
        clipboard.captureIfChanged()
        await clipboard.waitForPersistence()
        for _ in 0..<100 where model.results.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(model.results.map(\.title)), ["saved while closed", "saved while open"])
        XCTAssertGreaterThan(publications, 0, "Real source changes must still update the visible launcher")
    }

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

    func testCurrencyResultPrecedesSearchMatchesOnlyInAllCategory() {
        let conversion = LauncherResult(id: "currency", title: "20 000 ₽", subtitle: "250 USD → RUB",
                                        payload: .calculation("20 000 ₽"))
        XCTAssertEqual(LauncherModel.searchResults([], clipboard: [], query: "250$", category: .all,
                                                   currency: conversion).first, conversion)
        XCTAssertTrue(LauncherModel.searchResults([], clipboard: [], query: "250$", category: .files,
                                                  currency: conversion).isEmpty)
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
