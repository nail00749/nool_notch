import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class ScratchpadStoreTests: XCTestCase {
    private func fixture() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scratchpad-tests-\(UUID().uuidString)/scratchpad.json")
    }

    func testEmptyLoadDoesNotCreateFileAndEditsBeforeLoadAreIgnored() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url)
        store.addNote()
        XCTAssertTrue(store.notes.isEmpty)
        await store.load()
        await store.flush()
        XCTAssertTrue(store.canEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRestartRestoresNotesAndSelectedNote() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url)
        await store.load()
        store.addNote()
        store.updateTitle("Первая")
        store.updateBody("Текст\n**Markdown**")
        let firstID = store.selectedNoteID!
        store.addNote()
        store.updateTitle("Вторая")
        store.selectNote(firstID)
        await store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)
        let reopened = ScratchpadStore(fileURL: url)
        await reopened.load()
        XCTAssertEqual(reopened.notes, store.notes)
        XCTAssertEqual(reopened.selectedNoteID, firstID)
        XCTAssertEqual(reopened.selectedNote?.body, "Текст\n**Markdown**")
    }

    func testRapidEditsAndConcurrentFlushKeepLatestText() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url, debounceNanoseconds: 0)
        await store.load()
        store.addNote()
        for index in 0..<30 {
            store.updateBody("Revision \(index)")
            if index % 3 == 0 { Task { await store.flush() } }
            await Task.yield()
        }
        store.updateBody("Последний текст")
        await store.flush()
        let reopened = ScratchpadStore(fileURL: url)
        await reopened.load()
        XCTAssertEqual(reopened.selectedNote?.body, "Последний текст")
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testCorruptAndUnsupportedDocumentsAreNeverOverwritten() async throws {
        for content in ["not json", "{\"version\":2,\"notes\":[],\"selectedNoteID\":null}"] {
            let url = fixture()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data(content.utf8)
            try original.write(to: url)
            let store = ScratchpadStore(fileURL: url)
            await store.load()
            XCTAssertFalse(store.canEdit)
            XCTAssertNotNil(store.errorMessage)
            store.addNote()
            store.updateBody("Must not write")
            await store.flush()
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testCountAndTextBounds() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url, debounceNanoseconds: 60_000_000_000)
        await store.load()
        for _ in 0..<35 { store.addNote() }
        XCTAssertEqual(store.notes.count, 30)
        let text = String(repeating: "x", count: 100_001)
        store.updateTitle(text)
        store.updateBody(text)
        XCTAssertEqual(store.selectedNote?.title.count, 100_000)
        XCTAssertEqual(store.selectedNote?.body.count, 100_000)
        await store.flush()
    }

    func testUnicodeByteBoundPersistsAndInactiveStoreFlushesButRejectsEdits() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url, debounceNanoseconds: 60_000_000_000)
        await store.load()
        store.addNote()
        store.updateBody(String(repeating: "👨‍👩‍👧‍👦", count: 100_001))
        let expected = store.selectedNote?.body
        XCTAssertLessThanOrEqual(expected?.utf8.count ?? Int.max, ScratchpadStore.maximumTextBytes)
        store.setActive(false)
        store.updateBody("Must not replace")
        await store.flush()
        let reopened = ScratchpadStore(fileURL: url)
        await reopened.load()
        XCTAssertTrue(reopened.canEdit)
        XCTAssertEqual(reopened.selectedNote?.body, expected)
    }

    func testDeleteUndoRetainsBodyOrderAndSelection() async {
        let url = fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ScratchpadStore(fileURL: url)
        await store.load()
        store.addNote()
        store.updateBody("Сохранить")
        let first = store.selectedNote!
        store.addNote()
        store.selectNote(first.id)
        store.deleteSelectedNote()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.canUndoDeletion)
        store.undoDeletion()
        XCTAssertEqual(store.notes.first, first)
        XCTAssertEqual(store.selectedNoteID, first.id)
        XCTAssertFalse(store.canUndoDeletion)
        await store.flush()
    }

    func testWriteFailureKeepsUnsavedStateAndRetryPersistsLatest() async throws {
        let url = fixture()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScratchpadStore(fileURL: url)
        await store.load()
        try Data("block directory creation".utf8).write(to: directory)
        store.addNote()
        store.updateBody("Recover me")
        await store.flush()
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertNotNil(store.errorMessage)
        try FileManager.default.removeItem(at: directory)
        await store.flush()
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(store.errorMessage)
        let reopened = ScratchpadStore(fileURL: url)
        await reopened.load()
        XCTAssertEqual(reopened.selectedNote?.body, "Recover me")
    }
}
