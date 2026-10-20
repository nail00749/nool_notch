import XCTest
@testable import NotchApp

final class DockFileStackTests: XCTestCase {
    func testReadSortsOnlyImmediateVisibleFilesAndPreservesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["z.pdf", "a.txt", ".hidden", "Folder/nested.txt"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
        let files = try DockFileStackProvider.read(directory: root, sort: .name)
        XCTAssertEqual(files.map(\.title), ["a.txt", "Folder", "z.pdf"])
        XCTAssertTrue(try XCTUnwrap(files.first { $0.title == "Folder" }).isDirectory)
        let byKind = try DockFileStackProvider.read(directory: root, sort: .kind)
        XCTAssertEqual(byKind.first?.title, "Folder")
    }

    func testDateAddedSortPutsNewestDownloadFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let older = root.appendingPathComponent("a-older.txt"), newer = root.appendingPathComponent("b-newer.txt")
        try Data("1".utf8).write(to: older)
        try Data("2".utf8).write(to: newer)
        // Modification time alone must not reorder a file downloaded earlier.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: older.path)
        let files = try DockFileStackProvider.read(directory: root, sort: .added)
        XCTAssertEqual(Set(files.map(\.title)), ["a-older.txt", "b-newer.txt"])
        XCTAssertTrue(files.allSatisfy { $0.addedAt != nil || $0.modifiedAt != nil })
    }

    @MainActor
    func testTrashDetectsVisibleItemsAndIgnoresHiddenOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(DockTrashModel.containsItems(root), false)
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(DockTrashModel.containsItems(root), false)
        try Data("x".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        XCTAssertEqual(DockTrashModel.containsItems(root), true)
        XCTAssertNil(DockTrashModel.containsItems(root.appendingPathComponent("missing")))
    }

    func testUnreadableDirectoryThrowsInsteadOfLookingEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertThrowsError(try DockFileStackProvider.read(directory: root, sort: .name))
    }

    @MainActor
    func testFoldersAndBundlesDoNotShareOneCachedIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["One.app", "Two.app", "A", "B"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let provider = DockFileStackProvider()
        func file(_ name: String) -> DockStackFile {
            DockStackFile(url: root.appendingPathComponent(name), title: name, isDirectory: true, modifiedAt: nil)
        }
        XCTAssertFalse(provider.icon(for: file("One.app")) === provider.icon(for: file("Two.app")))
        XCTAssertFalse(provider.icon(for: file("A")) === provider.icon(for: file("B")))
        XCTAssertTrue(provider.icon(for: file("A")) === provider.icon(for: file("A")))
    }

    @MainActor
    func testMissingDirectoryReportsErrorAndDoesNotLeaveSpinner() async {
        let provider = DockFileStackProvider()
        await provider.load(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertNotNil(provider.errorMessage)
        XCTAssertFalse(provider.isLoading)
        XCTAssertTrue(provider.items.isEmpty)
    }

    @MainActor
    func testPaginationAndCancellationClearVisibleData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<100 { try Data().write(to: root.appendingPathComponent("file-\(n).txt")) }
        let provider = DockFileStackProvider()
        await provider.load(directory: root, sort: .name)
        XCTAssertEqual(provider.items.count, 80)
        XCTAssertTrue(provider.hasMore)
        await provider.loadMore()
        XCTAssertEqual(provider.items.count, 100)
        XCTAssertFalse(provider.hasMore)
        provider.cancel()
        XCTAssertTrue(provider.items.isEmpty)
        XCTAssertFalse(provider.isLoading)
    }
}
