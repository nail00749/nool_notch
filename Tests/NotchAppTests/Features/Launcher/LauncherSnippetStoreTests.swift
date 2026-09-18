import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class LauncherSnippetStoreTests: XCTestCase {
    func testDiskRoundTripKeepsTextAndCreatesPrivateStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let store = LauncherSnippetStore(url: fixture.url)
        await store.waitForPersistence()
        XCTAssertTrue(store.save(text: "  Deploy checklist  \nRun the release command"))
        await store.waitForPersistence()

        let restored = LauncherSnippetStore(url: fixture.url)
        await restored.waitForPersistence()

        let item = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(item.title, "Deploy checklist")
        XCTAssertEqual(item.text, "  Deploy checklist  \nRun the release command")
        XCTAssertEqual(restored.items.count, 1)
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.url.path)[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
    }

    func testCorruptFileIsPreservedAndBlocksMutations() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: fixture.url)

        let store = LauncherSnippetStore(url: fixture.url)
        XCTAssertFalse(store.save(text: "Не перезаписывать во время загрузки"))
        await store.waitForPersistence()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.save(text: "Не перезаписывать повреждённый файл"))
        await store.waitForPersistence()
        XCTAssertEqual(try Data(contentsOf: fixture.url), corrupt)
    }

    func testCountLengthAndDuplicateLimitsAreEnforcedWithoutPersistence() {
        let store = LauncherSnippetStore(url: nil)
        XCTAssertFalse(store.save(text: " \n "))
        XCTAssertFalse(store.save(text: String(repeating: "a", count: LauncherSnippetStore.maximumTextCharacters + 1)))

        for number in 0..<LauncherSnippetStore.maximumItemCount {
            XCTAssertTrue(store.save(text: "Snippet \(number)"))
        }
        XCTAssertEqual(store.items.count, LauncherSnippetStore.maximumItemCount)
        XCTAssertTrue(store.save(text: "Snippet 1"))
        XCTAssertEqual(store.items.count, LauncherSnippetStore.maximumItemCount)
        XCTAssertFalse(store.save(text: "One too many"))
    }

    func testQueuedRemoveWinsOverEarlierWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = LauncherSnippetStore(url: fixture.url)
        await store.waitForPersistence()
        XCTAssertTrue(store.save(text: "Удалить"))
        let id = try XCTUnwrap(store.items.first?.id)
        store.remove(id: id)
        await store.waitForPersistence()

        let restored = LauncherSnippetStore(url: fixture.url)
        await restored.waitForPersistence()
        XCTAssertTrue(restored.items.isEmpty)
    }
}

private struct Fixture {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAppTests-Snippets-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("snippets.json", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
