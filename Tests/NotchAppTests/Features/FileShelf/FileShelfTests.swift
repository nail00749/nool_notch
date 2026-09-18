import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class FileShelfTests: XCTestCase {
    func testAddDeduplicatesStandardizedFileURLs() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("design.txt")
        try Data("draft".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShelfStore()
        let nonStandardizedURL = directory.appendingPathComponent(".").appendingPathComponent("design.txt")

        XCTAssertEqual(store.add(urls: [file, nonStandardizedURL]), 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.standardizedURL, file.standardizedFileURL)
    }

    func testAddRejectsNonFileAndMissingURLs() throws {
        let store = FileShelfStore()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")

        XCTAssertEqual(store.add(urls: [URL(string: "https://example.test/file")!, missing]), 0)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    func testRemovingShelfReferenceKeepsOriginalFile() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("keep-me.txt")
        try Data("content".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShelfStore()
        store.add(urls: [file])
        let item = try XCTUnwrap(store.items.first)

        store.remove(item)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAddKeepsAtMostTwentyFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0...FileShelfStore.maximumItemCount).map { index in
            let file = directory.appendingPathComponent("\(index).txt")
            try Data("file \(index)".utf8).write(to: file)
            return file
        }

        let store = FileShelfStore()

        XCTAssertEqual(store.add(urls: files), FileShelfStore.maximumItemCount)
        XCTAssertEqual(store.items.count, FileShelfStore.maximumItemCount)
        XCTAssertEqual(store.errorMessage, "На полке можно держать до 20 файлов.")
    }

    func testAcceptDropImportsURLProviderAndFinishesImport() async throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("drop.txt")
        try Data("dropped".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShelfStore()
        let completed = expectation(description: "file import completed")
        store.onImportCompleted = {
            completed.fulfill()
        }

        XCTAssertTrue(store.acceptDrop(providers: [NSItemProvider(object: file as NSURL)]))
        XCTAssertTrue(store.isImporting)

        await fulfillment(of: [completed], timeout: 2)

        XCTAssertFalse(store.isImporting)
        XCTAssertEqual(store.entries.map(\.standardizedURL), [file.standardizedFileURL])
    }

    func testAcceptDropRejectsNonFileProvider() {
        let store = FileShelfStore()

        XCTAssertFalse(store.acceptDrop(providers: [NSItemProvider(object: "not a file" as NSString)]))
        XCTAssertFalse(store.isImporting)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.errorMessage, "Перетащите файл с этого Mac.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
