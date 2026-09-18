import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class LauncherFileProviderTests: XCTestCase {
    func testPredicateTreatsQueryAsAValueInsteadOfPredicateSource() {
        let predicate = LauncherFileProvider.predicate(for: "report' OR TRUEPREDICATE OR '")
        let matching = [NSMetadataItemFSNameKey: "report' OR TRUEPREDICATE OR '.txt"]
        let unrelated = [NSMetadataItemFSNameKey: "notes.txt"]

        XCTAssertTrue(predicate.evaluate(with: matching))
        XCTAssertFalse(predicate.evaluate(with: unrelated))
    }

    func testScopePreparationIsStructuralAndBackgroundValidationDropsMissingFolders() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let duplicate = folder.appendingPathComponent(".")
        let missing = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)

        let scopes = LauncherFileProvider.searchScopes(for: [folder, duplicate, missing])
        XCTAssertEqual(scopes.map(\.path), [folder.standardizedFileURL.path, missing.standardizedFileURL.path])
        XCTAssertEqual(try LauncherFileProvider.availableSearchScopes(for: scopes).map(\.path), [folder.standardizedFileURL.path])
    }

    func testStopCancelsDebouncedSearch() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = LauncherFileProvider()

        provider.search(query: "draft", folders: [folder])
        XCTAssertTrue(provider.isSearching)
        provider.stop()
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertFalse(provider.isSearching)
        XCTAssertTrue(provider.results.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LauncherFileProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
