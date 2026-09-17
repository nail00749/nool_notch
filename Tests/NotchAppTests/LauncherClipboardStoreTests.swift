import AppKit
import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class LauncherClipboardStoreTests: XCTestCase {
    func testClipboardIsNotReadUntilHistoryIsEnabled() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.pasteboard.setString("секрет до согласия", forType: .string)

        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }

        store.captureIfChanged()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    func testConcealedPasteboardContentIsIgnoredBeforeReadingPayload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.pasteboard.setString("не сохранять", forType: .string)
        fixture.pasteboard.setData(
            Data(),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        )

        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()

        XCTAssertTrue(store.items.isEmpty)

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("можно сохранить", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()

        XCTAssertEqual(store.items.map(\.text), ["можно сохранить"])
    }

    func testAdjacentDuplicateIsNotPersistedTwice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()

        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("повтор", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("повтор", forType: .string)
        store.captureIfChanged()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.text, "повтор")
    }

    func testHistoryLoadsOnlyAfterOptInAndExpiresOldEntries() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let fresh = LauncherClipboardItem(
            id: UUID(), text: "свежий", imageData: nil, createdAt: Date()
        )
        let old = LauncherClipboardItem(
            id: UUID(), text: "старый", imageData: nil,
            createdAt: Date().addingTimeInterval(-2 * 86_400)
        )
        try JSONEncoder().encode([old, fresh]).write(to: fixture.persistenceURL, options: .atomic)

        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }

        XCTAssertTrue(store.items.isEmpty)
        store.configure(enabled: true, limit: 100, retentionDays: 1)
        await store.waitForPersistence()

        XCTAssertEqual(store.items.map(\.text), ["свежий"])
    }

    func testDisableErasesPersistedHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("удалить", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()
        XCTAssertEqual(store.items.map(\.text), ["удалить"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))

        store.configure(enabled: false, limit: 100, retentionDays: 7)
        await store.waitForPersistence()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    func testCopyRestoresTextAndImageData() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let imageData = bitmap.representation(using: .tiff, properties: [:])!
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("текст с картинкой", forType: .string)
        fixture.pasteboard.setData(imageData, forType: .tiff)
        store.captureIfChanged()

        guard let item = store.items.first else {
            return XCTFail("Expected clipboard item")
        }
        fixture.pasteboard.clearContents()

        XCTAssertTrue(store.copy(item.id))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "текст с картинкой")
        XCTAssertEqual(fixture.pasteboard.data(forType: .tiff), item.imageData)
    }

    func testPersistenceFailureIsExposedWithoutLeakingClipboardContent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.directoryURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("очень личная строка", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()

        XCTAssertEqual(store.errorMessage, "Не удалось сохранить историю буфера.")
        XCTAssertFalse(store.copy(UUID()))
        XCTAssertEqual(store.errorMessage, "Элемент буфера больше недоступен.")
    }

    func testClearDoesNotRecaptureTheUnchangedPasteboard() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("не возвращать после очистки", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()

        store.clear()
        await store.waitForPersistence()
        store.captureIfChanged()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    func testCorruptDuplicateIdentifiersAreCollapsedOnLoad() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let duplicateID = UUID()
        let current = Date()
        let newer = LauncherClipboardItem(
            id: duplicateID, text: "новее", imageData: nil, createdAt: current
        )
        let older = LauncherClipboardItem(
            id: duplicateID, text: "старее", imageData: nil,
            createdAt: current.addingTimeInterval(-1)
        )
        try JSONEncoder().encode([older, newer]).write(to: fixture.persistenceURL, options: .atomic)

        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()

        XCTAssertEqual(store.items.map(\.text), ["новее"])
    }

    func testInvalidImageDataIsRejectedBeforeItReachesHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.setData(Data(repeating: 0, count: 64), forType: .tiff)

        store.captureIfChanged()

        XCTAssertTrue(store.items.isEmpty)
    }

    func testDisableWinsAgainstAnAlreadyQueuedWrite() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("не возвращать после отключения", forType: .string)
        store.captureIfChanged()
        store.configure(enabled: false, limit: 100, retentionDays: 7)

        await store.waitForPersistence()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    func testStopPreventsAnInFlightLoadFromRestoringOrCapturingHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.pasteboard.setString("не захватывать при остановке", forType: .string)
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )

        store.configure(enabled: true, limit: 100, retentionDays: 7)
        store.stop()
        await store.waitForPersistence()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    func testDisableThenStopCompletesQueuedDeletion() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = LauncherClipboardStore(
            persistenceURL: fixture.persistenceURL,
            pasteboard: fixture.pasteboard
        )
        defer { store.stop() }
        store.configure(enabled: true, limit: 100, retentionDays: 7)
        await store.waitForPersistence()
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("удалить перед остановкой", forType: .string)
        store.captureIfChanged()
        await store.waitForPersistence()
        XCTAssertEqual(store.items.map(\.text), ["удалить перед остановкой"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))

        store.configure(enabled: false, limit: 100, retentionDays: 7)
        store.stop()
        await store.waitForPersistence()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.persistenceURL.path))
    }

    private func makeFixture() throws -> ClipboardFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAppTests-Clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchAppTests.Clipboard.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return ClipboardFixture(directoryURL: directoryURL, pasteboard: pasteboard)
    }
}

private struct ClipboardFixture {
    let directoryURL: URL
    let pasteboard: NSPasteboard

    var persistenceURL: URL {
        directoryURL.appendingPathComponent("history.json")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
