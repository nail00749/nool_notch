import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import NotchApp

final class RecentCapturesTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(_ name: String, in folder: URL, date: Date = Date(timeIntervalSince1970: 100)) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testSortsByDateThenFilenameAndBoundsThumbnails() throws {
        let folder = try temporaryFolder()
        _ = try image("z.png", in: folder)
        _ = try image("a.png", in: folder)
        _ = try image("new.PNG", in: folder, date: Date(timeIntervalSince1970: 200))
        let result = try RecentCaptureScanner.scan(folder: folder)
        XCTAssertEqual(result.items.map(\.url.lastPathComponent), ["new.PNG", "a.png", "z.png"])
        XCTAssertFalse(result.isPartial)
        XCTAssertTrue(result.items.allSatisfy { $0.thumbnail.width <= 320 && $0.thumbnail.height <= 320 })
    }

    func testExcludesCorruptEmptyUnsupportedNestedAndSymlinkFiles() throws {
        let folder = try temporaryFolder()
        let outside = try temporaryFolder()
        let target = try image("outside.png", in: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias.png"), withDestinationURL: target)
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("corrupt.png"))
        try Data().write(to: folder.appendingPathComponent("empty.png"))
        _ = try image("unsupported.txt", in: folder)
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try image("hidden.png", in: nested)
        _ = try image("valid.png", in: folder)
        XCTAssertEqual(try RecentCaptureScanner.scan(folder: folder).items.map(\.url.lastPathComponent), ["valid.png"])
    }

    func testLimitsResultsAndReportsPartialDirectoryScan() throws {
        let folder = try temporaryFolder()
        for index in 0..<5 { _ = try image("\(index).png", in: folder, date: Date(timeIntervalSince1970: Double(index))) }
        let full = try RecentCaptureScanner.scan(folder: folder, itemLimit: 2)
        XCTAssertEqual(full.items.map(\.url.lastPathComponent), ["4.png", "3.png"])
        let partial = try RecentCaptureScanner.scan(folder: folder, entryLimit: 2)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.items.count, 2)
    }

    func testCacheAvoidsDecodingAndInvalidatesChangedFingerprint() throws {
        let folder = try temporaryFolder()
        let url = try image("cached.png", in: folder)
        let first = try RecentCaptureScanner.scan(folder: folder)
        let reused = try RecentCaptureScanner.scan(folder: folder, cachedItems: first.items, decodeLimit: 0)
        XCTAssertEqual(reused.items.count, 1)
        XCTAssertFalse(reused.isPartial)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 500)], ofItemAtPath: url.path)
        let changed = try RecentCaptureScanner.scan(folder: folder, cachedItems: first.items, decodeLimit: 0)
        XCTAssertTrue(changed.items.isEmpty)
        XCTAssertTrue(changed.isPartial)
    }

    func testRemovedFolderThrowsInsteadOfShowingSuccessfulEmptyScan() throws {
        let folder = try temporaryFolder()
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try RecentCaptureScanner.scan(folder: folder))
    }

    func testOversizedFileIsSkippedWithoutDecoding() throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RecentCaptureScanner.maximumFileSize + 1))
        try handle.close()
        XCTAssertTrue(try RecentCaptureScanner.scan(folder: folder).items.isEmpty)
    }

    func testCancelledWorkerDoesNotPublishScan() async throws {
        let folder = try temporaryFolder()
        _ = try image("test.png", in: folder)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RecentCaptureScanner.scan(folder: folder)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    @MainActor
    func testFolderIsOptInAndBookmarkRestoresOnlyWhenActive() async throws {
        let name = "RecentCapturesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = try temporaryFolder()
        _ = try image("test.png", in: folder)
        let store = RecentCapturesStore(defaults: defaults)
        XCTAssertNil(store.folderURL)
        await store.chooseFolder(folder)
        XCTAssertTrue(store.items.isEmpty, "Choosing a folder while inactive must not crawl it")
        XCTAssertNotNil(defaults.data(forKey: RecentCapturesStore.bookmarkKey))
        let restored = RecentCapturesStore(defaults: defaults)
        XCTAssertNil(restored.folderURL)
        restored.setActive(true)
        await Task.yield()
        await restored.refresh()
        XCTAssertEqual(restored.items.count, 1)
        restored.setActive(false)
        XCTAssertFalse(restored.isLoading)
        XCTAssertTrue(restored.items.isEmpty)
        await restored.refresh()
        XCTAssertTrue(restored.items.isEmpty)
    }

    @MainActor
    func testDisableInvalidatesInFlightResult() async throws {
        let name = "RecentCapturesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = try temporaryFolder()
        _ = try image("test.png", in: folder)
        let store = RecentCapturesStore(defaults: defaults)
        await store.chooseFolder(folder)
        store.forgetFolder()
        XCTAssertNil(store.folderURL)
        XCTAssertNil(defaults.data(forKey: RecentCapturesStore.bookmarkKey))
        await store.chooseFolder(folder)
        store.setActive(true)
        let refreshing = Task { await store.refresh() }
        await Task.yield()
        store.setActive(false)
        await refreshing.value
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isLoading)
    }
}
