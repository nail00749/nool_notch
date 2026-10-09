import XCTest
@testable import NotchApp

@MainActor
final class WorkspaceTests: XCTestCase {
    func testStoreValidatesPersistsAndUpdatesWorkspace() throws {
        let suite = "WorkspaceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = try XCTUnwrap(WorkspaceEntry.folder(url: URL(fileURLWithPath: "/tmp", isDirectory: true)))
        let site = try XCTUnwrap(WorkspaceEntry.website("https://example.com/team"))
        let id = UUID()
        let store = WorkspaceStore(defaults: defaults)

        XCTAssertEqual(store.save(SavedWorkspace(id: id, name: "  Работа  ", entries: [folder, site])), .saved)
        XCTAssertEqual(store.workspaces.first?.name, "Работа")
        XCTAssertEqual(WorkspaceStore(defaults: defaults).workspaces, store.workspaces)

        XCTAssertEqual(store.save(SavedWorkspace(id: id, name: "Работа", entries: [site])), .saved)
        XCTAssertEqual(store.workspaces.first?.entries, [site])
        XCTAssertEqual(store.save(SavedWorkspace(name: "Работа", entries: [site])),
                       .rejected("Рабочее пространство с таким названием уже существует."))
    }

    func testStoreEnforcesTwentyWorkspaceLimit() throws {
        let suite = "WorkspaceLimitTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        for index in 0..<SavedWorkspace.maximumCount {
            let site = try XCTUnwrap(WorkspaceEntry.website("https://example.com/\(index)"))
            XCTAssertEqual(store.save(SavedWorkspace(name: "Space \(index)", entries: [site])), .saved)
        }
        let overflow = try XCTUnwrap(WorkspaceEntry.website("https://example.com/overflow"))
        XCTAssertEqual(store.save(SavedWorkspace(name: "Overflow", entries: [overflow])),
                       .rejected("Можно сохранить не более 20 рабочих пространств."))
        XCTAssertEqual(store.workspaces.count, SavedWorkspace.maximumCount)
    }

    func testValidationRejectsCustomSchemesCredentialsAndOversizedContent() throws {
        XCTAssertNil(WorkspaceEntry.website("file:///tmp/example"))
        XCTAssertNil(WorkspaceEntry.website("custom://open"))
        XCTAssertNil(WorkspaceEntry.website("https://user:password@example.com"))
        XCTAssertNotNil(WorkspaceEntry.website("HTTP://example.com/path"))

        let site = try XCTUnwrap(WorkspaceEntry.website("https://example.com"))
        XCTAssertNil(SavedWorkspace(name: "", entries: [site]).validated())
        XCTAssertNil(SavedWorkspace(name: "Too many", entries: Array(repeating: site, count: 21)).validated())
        XCTAssertNil(SavedWorkspace(name: "Empty", entries: []).validated())
        let script = WorkspaceEntry(kind: .application, title: "Script", urlString: "file:///tmp/run.command")
        XCTAssertNil(script.validated())

        let regularFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: regularFile) }
        let disguisedFolder = WorkspaceEntry(kind: .folder, title: "File", urlString: regularFile.absoluteString)
        XCTAssertNil(disguisedFolder.validated())
    }

    func testFolderSymlinkAcceptsDirectoryButRejectsApplicationPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("Documents", isDirectory: true)
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let directoryLink = root.appendingPathComponent("Directory Link", isDirectory: true)
        let packageLink = root.appendingPathComponent("Package Link", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        try FileManager.default.createSymbolicLink(at: packageLink, withDestinationURL: package)
        defer { try? FileManager.default.removeItem(at: root) }

        let normal = WorkspaceEntry(kind: .folder, title: "Documents", urlString: directoryLink.absoluteString)
        XCTAssertNotNil(normal.validated())
        XCTAssertTrue(normal.matchesResolvedType(directoryLink))

        let disguisedPackage = WorkspaceEntry(kind: .folder, title: "Package", urlString: packageLink.absoluteString)
        XCTAssertNil(disguisedPackage.validated())
        XCTAssertFalse(disguisedPackage.matchesResolvedType(packageLink))
    }

    func testLauncherCommandIsSearchableOnlyInAllCategory() throws {
        let workspace = SavedWorkspace(name: "Работа", entries: [
            try XCTUnwrap(WorkspaceEntry.website("https://example.com"))
        ])
        XCTAssertTrue(LauncherResult.workspaceCommands(workspaces: [workspace], query: "", category: .all).isEmpty)
        XCTAssertTrue(LauncherResult.workspaceCommands(workspaces: [workspace], query: "Работа", category: .files).isEmpty)
        let candidates = LauncherResult.workspaceCommands(workspaces: [workspace], query: "Работа", category: .all)
        XCTAssertEqual(LauncherModel.searchResults(candidates, clipboard: [], query: "Работа", category: .all).first?.payload,
                       .workspace(workspace.id))
        XCTAssertTrue(candidates.contains { $0.payload == .workspaceManager })
    }

    func testLauncherOpensSequentiallyReportsFailuresThenRestoresLayout() async throws {
        let app = try XCTUnwrap(WorkspaceEntry.application(url: URL(fileURLWithPath: "/Applications/Editor.app")))
        let folder = try XCTUnwrap(WorkspaceEntry.folder(url: URL(fileURLWithPath: "/tmp", isDirectory: true)))
        let site = try XCTUnwrap(WorkspaceEntry.website("https://example.com"))
        let layoutID = UUID()
        let workspace = SavedWorkspace(name: "Работа", entries: [app, folder, site], windowLayoutID: layoutID)
        let opener = WorkspaceOpeningSpy(entries: [app, folder, site], failingIDs: [folder.id])
        let launcher = WorkspaceLauncher(opener: opener)
        var restored: UUID?

        let report = await launcher.launch(workspace) { id in
            restored = id
            opener.events.append("layout")
            return "Раскладка применена."
        }

        XCTAssertEqual(opener.events, ["application:\(app.id)", "open:\(folder.id)", "open:\(site.id)", "wait", "layout"])
        XCTAssertEqual(restored, layoutID)
        XCTAssertEqual(report.status, .completed)
        XCTAssertEqual(report.openedCount, 2)
        XCTAssertEqual(report.failures, [.init(entryTitle: folder.title, reason: "не удалось открыть")])
        XCTAssertEqual(report.layoutMessage, "Раскладка применена.")
    }

    func testConcurrentLaunchIsRejected() async throws {
        let app = try XCTUnwrap(WorkspaceEntry.application(url: URL(fileURLWithPath: "/Applications/Editor.app")))
        let workspace = SavedWorkspace(name: "Работа", entries: [app])
        let opener = WorkspaceOpeningSpy(entries: [app], applicationDelay: .milliseconds(150))
        let launcher = WorkspaceLauncher(opener: opener)

        let first = Task { await launcher.launch(workspace) }
        await Task.yield()
        let second = await launcher.launch(workspace)
        XCTAssertEqual(second.status, .busy)
        _ = await first.value
        XCTAssertFalse(launcher.isLaunching)
    }

    func testStopCancelsSequenceBeforeNextEntryAndLayout() async throws {
        let first = try XCTUnwrap(WorkspaceEntry.application(url: URL(fileURLWithPath: "/Applications/First.app")))
        let second = try XCTUnwrap(WorkspaceEntry.application(url: URL(fileURLWithPath: "/Applications/Second.app")))
        let workspace = SavedWorkspace(name: "Работа", entries: [first, second], windowLayoutID: UUID())
        let opener = WorkspaceOpeningSpy(entries: [first, second], applicationDelay: .milliseconds(150))
        let launcher = WorkspaceLauncher(opener: opener)
        var restored = false
        let task = Task {
            await launcher.launch(workspace) { _ in restored = true; return "restored" }
        }
        for _ in 0..<100 where opener.events.isEmpty { await Task.yield() }
        launcher.stop()

        let report = await task.value
        XCTAssertEqual(report.status, .cancelled)
        XCTAssertEqual(opener.events, ["application:\(first.id)"])
        XCTAssertFalse(restored)
    }
}

@MainActor
private final class WorkspaceOpeningSpy: WorkspaceOpening {
    var events: [String] = []
    private let failingIDs: Set<UUID>
    private let applicationDelay: Duration
    private var entriesByURL: [URL: WorkspaceEntry] = [:]

    init(entries: [WorkspaceEntry], failingIDs: Set<UUID> = [], applicationDelay: Duration = .zero) {
        self.failingIDs = failingIDs
        self.applicationDelay = applicationDelay
        entriesByURL = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.resolvedURL.map { ($0, entry) }
        })
    }

    func openApplication(at url: URL) async -> Bool {
        let known = entriesByURL[url]!
        events.append("application:\(known.id)")
        if applicationDelay != .zero { try? await Task.sleep(for: applicationDelay) }
        return !failingIDs.contains(known.id)
    }

    func open(_ url: URL) -> Bool {
        // Tests register the stable entry identity through its exact URL before launching.
        let entry = entriesByURL[url]
        if let entry { events.append("open:\(entry.id)"); return !failingIDs.contains(entry.id) }
        events.append("open:unknown")
        return true
    }

    func waitUntilApplicationsReady(_ entries: [WorkspaceEntry], timeout: TimeInterval) async -> Set<UUID> {
        events.append("wait")
        return Set(entries.map(\.id))
    }
}
