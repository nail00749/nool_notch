import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class FileActionIntegrationTests: XCTestCase {
    func testRenameReplacementMatchesOriginalURLAfterTemporaryAliasChanges() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("before.txt")
        let replacement = directory.appendingPathComponent("after.txt")
        try Data("body".utf8).write(to: original)
        let shelf = FileShelfStore()
        shelf.add(urls: [original])
        let retainedURL = try XCTUnwrap(shelf.items.first?.url)
        try FileManager.default.moveItem(at: original, to: replacement)
        shelf.replace(urls: [retainedURL], with: [replacement])
        XCTAssertEqual(shelf.items.map(\.url), [replacement])
    }

    func testPreviewThenRenameUpdatesShelfAndPreservesUnselectedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let other = directory.appendingPathComponent("other.txt")
        try Data("source body".utf8).write(to: source)
        try Data("other body".utf8).write(to: other)
        let shelf = FileShelfStore()
        shelf.add(urls: [source, other])
        let store = FileActionStore(urls: [source]) { originals, outputs, renamed in
            XCTAssertTrue(renamed)
            shelf.replace(urls: originals, with: outputs)
        }
        store.kind = .rename
        store.options.renamePrefix = "Document"
        store.previewRename()
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.renamePlan.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        store.applyRename()
        await settle(store)
        let destination = directory.appendingPathComponent("Document 001.txt")
        XCTAssertEqual(store.inputURLs, [destination])
        XCTAssertEqual(store.outputURLs, [destination])
        XCTAssertEqual(Set(shelf.items.map(\.url)), Set([destination, other]))
        XCTAssertEqual(try Data(contentsOf: destination), Data("source body".utf8))
        XCTAssertEqual(try Data(contentsOf: other), Data("other body".utf8))
    }

    func testChangingOptionsInvalidatesRenamePreview() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("body".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let store = FileActionStore(urls: [source])
        store.kind = .rename
        store.previewRename()
        await settle(store)
        XCTAssertEqual(store.renamePlan.count, 1)
        store.options.renamePrefix = "Changed"
        XCTAssertTrue(store.renamePlan.isEmpty)
        store.applyRename()
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func settle(_ store: FileActionStore) async {
        await store.waitForCompletion()
        for _ in 0..<100 where store.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isRunning)
    }
}
