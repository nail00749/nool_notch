import AppKit
import Combine
import XCTest
@testable import NotchApp

@MainActor
final class DockApplicationStoreTests: XCTestCase {
    func testDedupeUsesInstallationPathAndPrefersActiveProcess() {
        let applications = [
            DockRunningApplication(path: "/Applications/Editor.app", title: "Editor", pid: 1, icon: nil, isActive: false),
            DockRunningApplication(path: "/Applications/Editor.app", title: "Editor", pid: 2, icon: nil, isActive: true),
            DockRunningApplication(path: "/Volumes/Test/Editor.app", title: "Editor", pid: 3, icon: nil, isActive: false)
        ]
        let result = DockApplicationStore.deduplicated(applications)
        XCTAssertEqual(result.map(\.pid), [2, 3])
        XCTAssertEqual(result.count, 2)
    }

    func testUnavailableApplicationReportsErrorWithoutLaunching() {
        let store = DockApplicationStore()
        store.open(path: "/not-a-real-dock-test-application.app")
        XCTAssertNotNil(store.errorMessage)
        store.open(path: "relative.app")
        XCTAssertEqual(store.errorMessage, "Некорректный путь приложения.")
        store.stop()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.running.isEmpty)
    }

    func testCatalogCoalescesConcurrentRequestsAndFiltersInvalidOrDuplicatePaths() async {
        var loads = 0
        let store = DockApplicationStore(catalogLoader: {
            loads += 1
            await Task.yield()
            return [DockInstalledApplication(path: "/Applications/Editor.app", title: "Editor"),
                    DockInstalledApplication(path: "/Applications/Editor.app", title: "Duplicate"),
                    DockInstalledApplication(path: "relative.app", title: "Invalid"),
                    DockInstalledApplication(path: "/Applications/readme.txt", title: "Invalid")]
        })
        let first = Task { await store.loadCatalog() }
        let second = Task { await store.loadCatalog() }
        await first.value
        await second.value
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(store.catalog, [DockInstalledApplication(path: "/Applications/Editor.app", title: "Editor")])
        XCTAssertFalse(store.isCatalogLoading)
    }

    func testStopRejectsLateCatalogResult() async throws {
        var continuation: CheckedContinuation<[DockInstalledApplication], Never>?
        let store = DockApplicationStore(catalogLoader: {
            await withCheckedContinuation { continuation = $0 }
        })
        let load = Task { await store.loadCatalog() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let resume = try XCTUnwrap(continuation)
        store.stop()
        resume.resume(returning: [DockInstalledApplication(path: "/Applications/Late.app", title: "Late")])
        await load.value
        XCTAssertTrue(store.catalog.isEmpty)
        XCTAssertFalse(store.isCatalogLoading)
    }

    func testFinderClickOpensHomeFolderWithFinderWithoutLaunchingDuringTest() {
        var receivedFiles: [URL] = []
        var applicationPath: String?
        let store = DockApplicationStore(documentOpener: { files, application in
            receivedFiles = files
            applicationPath = application.path
        })
        store.open(path: "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(applicationPath, "/System/Library/CoreServices/Finder.app")
        XCTAssertEqual(receivedFiles, [FileManager.default.homeDirectoryForCurrentUser])
        XCTAssertNil(store.errorMessage)
    }

    func testActivationHotPathSkipsBookmarkResolutionAndUnchangedPublication() {
        let store = DockApplicationStore()
        var resolutions = 0
        store.reconcilePinnedPaths = { resolutions += 1 }
        let snapshots = (0..<40).map {
            DockRunningApplication(path: "/Applications/Fixture\($0).app", title: "Fixture \($0)",
                                   pid: Int32($0 + 1), icon: nil, isActive: $0 == 0)
        }
        var publications = 0
        let observation = store.$running.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        store.updateRunningApplications(snapshots, reconcilePinnedPaths: true)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(publications, 1)
        store.updateActivation(activePID: 2)
        XCTAssertEqual(publications, 2)
        let start = ContinuousClock.now
        for _ in 0..<500 { store.updateActivation(activePID: 2) }
        print("Dock activation fixture: 500 unchanged events / 40 apps in \(start.duration(to: .now))")
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(store.running.filter(\.isActive).map(\.pid), [2])
        store.updateRunningApplications(store.running, reconcilePinnedPaths: false)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(publications, 2)
        store.updateRunningApplications(store.running, reconcilePinnedPaths: true)
        XCTAssertEqual(resolutions, 2)
        XCTAssertEqual(publications, 2)
    }

    func testExplicitFileOpenResolvesMovedPinnedTargetAndPreservesFileRouting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DockOpenRouting-\(UUID().uuidString)")
        let application = root.appendingPathComponent("Moved.app")
        let contents = application.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.dock.routing"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let document = root.appendingPathComponent("document.pdf")
        var target: URL?
        var files: [URL] = []
        let store = DockApplicationStore(documentOpener: { received, app in files = received; target = app })
        var resolutions = 0
        store.resolvePinnedPath = { _ in resolutions += 1; return application.path }
        store.openFiles([document], with: root.appendingPathComponent("Old.app").path)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(target, application.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(files, [document])
        XCTAssertNil(store.errorMessage)
    }
}
