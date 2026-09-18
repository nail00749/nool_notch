import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class NoolDockSettingsTests: XCTestCase {
    func testDefaultsAndPreferencesRoundTrip() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = NoolDockSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.scale, 1)
        XCTAssertEqual(settings.opacity, 0.92)
        XCTAssertFalse(settings.autoHide)
        XCTAssertEqual(settings.displayID, "")
        XCTAssertEqual(settings.items.map(\.kind), [.app, .music, .calendar, .timer, .note])

        settings.isEnabled = true
        settings.scale = 1.1
        settings.opacity = 0.8
        settings.autoHide = true
        settings.displayID = "studio-display"
        settings.noteText = "Ship the Dock"
        settings.setSize(.compact, for: "music")
        settings.move(id: "note", before: "calendar")

        settings = NoolDockSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.scale, 1.1)
        XCTAssertEqual(settings.opacity, 0.8)
        XCTAssertTrue(settings.autoHide)
        XCTAssertEqual(settings.displayID, "studio-display")
        XCTAssertEqual(settings.noteText, "Ship the Dock")
        XCTAssertEqual(settings.items.map(\.id), ["app:/System/Library/CoreServices/Finder.app", "music", "note", "calendar", "timer"])
        XCTAssertEqual(settings.items.first(where: { $0.id == "music" })?.size, .compact)
    }

    func testBoundsAreAppliedBeforePersistenceAndNotifyAfterMutation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NoolDockSettings(defaults: defaults)
        var observed: [(Double, Double, Int)] = []
        settings.onChange = { observed.append((settings.scale, settings.opacity, settings.noteText.count)) }

        settings.scale = 2
        settings.opacity = 0
        settings.noteText = String(repeating: "x", count: 2_010)

        XCTAssertEqual(settings.scale, 1.2)
        XCTAssertEqual(settings.opacity, 0.55)
        XCTAssertEqual(settings.noteText.count, 2_000)
        XCTAssertEqual(defaults.double(forKey: "nool.dock.scale"), 1.2)
        XCTAssertEqual(defaults.double(forKey: "nool.dock.opacity"), 0.55)
        XCTAssertEqual(defaults.string(forKey: "nool.dock.noteText")?.count, 2_000)
        XCTAssertEqual(observed.count, 3)
        XCTAssertEqual(observed[0].0, 1.2)
        XCTAssertEqual(observed[0].1, 0.92)
        XCTAssertEqual(observed[0].2, 0)
        XCTAssertEqual(observed[2].0, 1.2)
        XCTAssertEqual(observed[2].1, 0.55)
        XCTAssertEqual(observed[2].2, 2_000)
    }

    func testApplicationsRequireLocalBundleDeduplicateAndRespectLimit() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = try makeApplication(named: "Example", in: root)
        let settings = NoolDockSettings(defaults: defaults)

        XCTAssertFalse(settings.addApplication(URL(string: "https://example.test/Example.app")!))
        XCTAssertFalse(settings.addApplication(root.appendingPathComponent("plain-folder.app")))
        XCTAssertTrue(settings.addApplication(application))
        XCTAssertFalse(settings.addApplication(application))
        XCTAssertEqual(settings.items.last?.applicationPath, application.standardizedFileURL.resolvingSymlinksInPath().path)

        for index in 0 ..< 22 {
            let nextApplication = try makeApplication(named: "More\(index)", in: root)
            XCTAssertTrue(settings.addApplication(nextApplication))
        }
        let overflowApplication = try makeApplication(named: "Overflow", in: root)
        XCTAssertFalse(settings.addApplication(overflowApplication))
        XCTAssertEqual(settings.items.filter({ $0.kind == .app }).count, 24)
    }

    func testWidgetsAreUniqueAndMoveAndSizePersist() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NoolDockSettings(defaults: defaults)

        XCTAssertFalse(settings.addWidget(.music))
        settings.remove(id: "music")
        XCTAssertTrue(settings.addWidget(.music))
        settings.move(id: "music", by: -10)
        XCTAssertEqual(settings.items.first?.id, "music")
        settings.move(id: "music", by: 1)
        XCTAssertEqual(settings.items[1].id, "music")
        settings.setSize(.compact, for: "music")
        XCTAssertEqual(settings.items[1].baseWidth, 210)
    }

    func testMalformedStoredItemsAreNormalized() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let application = try makeApplication(named: "Saved", in: root)
        let stored = [
            NoolDockItem(id: "wrong", kind: .music, applicationPath: "/bad", title: "Wrong", size: .compact),
            NoolDockItem(id: "duplicate", kind: .music, applicationPath: nil, title: "Again", size: .regular),
            NoolDockItem(id: "bad-app", kind: .app, applicationPath: root.appendingPathComponent("not-an-app").path, title: "Bad", size: .regular),
            NoolDockItem(id: "saved", kind: .app, applicationPath: application.path, title: "Saved title", size: .compact),
            NoolDockItem(id: "saved-duplicate", kind: .app, applicationPath: application.path, title: "Duplicate", size: .regular)
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "nool.dock.items")

        let settings = NoolDockSettings(defaults: defaults)
        XCTAssertEqual(settings.items.map(\.id), ["music", "app:\(application.standardizedFileURL.resolvingSymlinksInPath().path)"])
        XCTAssertEqual(settings.items.map(\.size), [.compact, .compact])
    }

    func testUnavailableApplicationPathSurvivesRoundTrip() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let unavailablePath = "/Volumes/External SSD/Offline.app"
        let stored = [
            NoolDockItem(
                id: "old-id",
                kind: .app,
                applicationPath: unavailablePath,
                title: "Offline",
                size: .compact
            )
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "nool.dock.items")

        let restored = NoolDockSettings(defaults: defaults)
        let reloaded = NoolDockSettings(defaults: defaults)

        XCTAssertEqual(restored.items, [
            NoolDockItem(
                id: "app:\(unavailablePath)",
                kind: .app,
                applicationPath: unavailablePath,
                title: "Offline",
                size: .compact
            )
        ])
        XCTAssertEqual(reloaded.items, restored.items)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "NoolDockSettingsTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplication(named name: String, in root: URL) throws -> URL {
        let application = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = contents.appendingPathComponent("Info.plist")
        let dictionary: NSDictionary = [
            "CFBundleIdentifier": "test.nool.dock.\(name.lowercased())",
            "CFBundleName": name
        ]
        XCTAssertTrue(dictionary.write(to: info, atomically: true))
        return application
    }
}
