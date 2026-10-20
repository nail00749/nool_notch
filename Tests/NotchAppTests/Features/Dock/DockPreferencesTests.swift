import AppKit
import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class DockPreferencesTests: XCTestCase {
    func testAppLabelsPersistAndMissingFieldKeepsExistingV2Preferences() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        XCTAssertFalse(prefs.showAppLabels)
        prefs.showAppLabels = true
        prefs.noteText = "Preserve existing note"
        prefs.scale = 1.2
        let expectedItems = prefs.items
        XCTAssertTrue(DockPreferences(defaults: defaults).showAppLabels)
        let data = try XCTUnwrap(defaults.data(forKey: DockPreferences.storageKey))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        payload.removeValue(forKey: "showAppLabels")
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: DockPreferences.storageKey)
        let migrated = DockPreferences(defaults: defaults)
        XCTAssertFalse(migrated.showAppLabels)
        XCTAssertEqual(migrated.noteText, "Preserve existing note")
        XCTAssertEqual(migrated.scale, 1.2)
        XCTAssertEqual(migrated.items, expectedItems)
    }

    func testDefaultsPersistSettingsAndWidgetWidths() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertFalse(preferences.replaceSystemDock)
        preferences.isEnabled = true
        preferences.visibility = .intelligent
        preferences.magnification = 0.6
        preferences.displayUUID = "chosen-display"
        preferences.previewEnabled = false
        preferences.setSpan(3, for: "integration:calendar")
        preferences.setSpan(3, for: "integration:timer")
        preferences.setOption("style", value: "agenda", for: "integration:calendar")
        let reloaded = DockPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled)
        XCTAssertEqual(reloaded.visibility, .intelligent)
        XCTAssertEqual(reloaded.magnification, 0.6)
        XCTAssertEqual(reloaded.displayUUID, "chosen-display")
        XCTAssertFalse(reloaded.previewEnabled)
        XCTAssertEqual(reloaded.items.first(where: { $0.integrationID == "calendar" })?.span, 3)
        XCTAssertEqual(reloaded.items.first(where: { $0.integrationID == "calendar" })?.options["style"], "agenda")
        XCTAssertEqual(reloaded.items.first(where: { $0.integrationID == "timer" })?.span, 1)
    }

    func testLegacyMigrationKeepsOfflineAppsNotesAndSourceKeys() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = Data("""
        [{"id":"old","kind":"app","title":"Offline","applicationPath":"/Volumes/SSD/Offline.app","size":"regular"},
         {"id":"calendar","kind":"calendar","title":"Calendar","size":"compact"},
         {"id":"music","kind":"music","title":"Music","size":"regular"}]
        """.utf8)
        defaults.set(old, forKey: "nool.dock.items")
        defaults.set(true, forKey: "nool.dock.enabled")
        defaults.set(true, forKey: "nool.dock.autoHide")
        defaults.set("draft", forKey: "nool.dock.noteText")
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isEnabled)
        XCTAssertEqual(preferences.visibility, .autoHide)
        XCTAssertFalse(preferences.replaceSystemDock)
        XCTAssertEqual(preferences.noteText, "draft")
        XCTAssertEqual(preferences.items.map(\.span), [1, 1, 3])
        XCTAssertEqual(preferences.items.first?.applicationPath, "/Volumes/SSD/Offline.app")
        XCTAssertEqual(defaults.data(forKey: "nool.dock.items"), old)
        defaults.set("changed old data", forKey: "nool.dock.noteText")
        XCTAssertEqual(DockPreferences(defaults: defaults).noteText, "draft")
    }

    func testFoldersGroupMoveAndUngroupWithoutDuplicatesOrLostApps() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try application("First", at: root)
        let second = try application("Second", at: root)
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertTrue(preferences.addApplication(first))
        XCTAssertTrue(preferences.addApplication(second))
        let firstID = "app:\(first.path)", secondID = "app:\(second.path)"
        XCTAssertTrue(preferences.group(firstID, with: secondID))
        let folder = try XCTUnwrap(preferences.items.first(where: { $0.kind == .folder }))
        XCTAssertEqual(folder.children.map(\.id), [secondID, firstID])
        XCTAssertFalse(preferences.addApplication(first))
        XCTAssertFalse(preferences.moveIntoFolder(folder.id, folderID: folder.id))
        preferences.move(id: firstID, before: secondID)
        XCTAssertEqual(preferences.items.first(where: { $0.kind == .folder })?.children.map(\.id), [firstID, secondID])
        let destination = preferences.addFolder(name: "Work")
        XCTAssertTrue(preferences.moveIntoFolder(firstID, folderID: destination))
        preferences.moveOutOfFolder(firstID, before: folder.id)
        XCTAssertEqual(preferences.flattenedApps.filter { $0.id == firstID }.count, 1)
        XCTAssertEqual(preferences.flattenedApps.count, 3)
        XCTAssertEqual(DockPreferences(defaults: defaults).items, preferences.items)
    }

    func testTopLevelAppDroppedInsideOpenFolderJoinsItAtThatPosition() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = try ["First", "Second", "Third"].map { try application($0, at: root) }
        let preferences = DockPreferences(defaults: defaults)
        for app in apps { XCTAssertTrue(preferences.addApplication(app)) }
        let ids = apps.map { "app:\($0.path)" }
        XCTAssertTrue(preferences.group(ids[0], with: ids[1]))
        let folderID = try XCTUnwrap(preferences.items.first(where: { $0.kind == .folder })?.id)

        // The drop on an open folder's icon: join the folder, then stand before that icon.
        XCTAssertTrue(preferences.moveIntoFolder(ids[2], folderID: folderID))
        preferences.move(id: ids[2], before: ids[0])

        let folder = try XCTUnwrap(preferences.items.first(where: { $0.id == folderID }))
        XCTAssertEqual(folder.children.map(\.id), [ids[1], ids[2], ids[0]])
        XCTAssertFalse(preferences.items.contains { $0.id == ids[2] })
        XCTAssertEqual(preferences.flattenedApps.filter { ids.contains($0.id) }.count, 3)
    }

    func testProfilesAreIndependentAndLastProfileCannotBeDeleted() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        let original = preferences.activeProfileID
        let duplicate = preferences.createProfile(name: "Work", duplicateCurrent: true)
        preferences.remove(id: "integration:calendar")
        preferences.setSpan(3, for: "integration:music")
        preferences.selectProfile(original)
        XCTAssertTrue(preferences.items.contains { $0.integrationID == "calendar" })
        XCTAssertEqual(preferences.items.first(where: { $0.integrationID == "music" })?.span, 2)
        preferences.selectProfile(duplicate)
        XCTAssertFalse(preferences.items.contains { $0.integrationID == "calendar" })
        preferences.removeProfile(duplicate)
        preferences.removeProfile(original)
        XCTAssertEqual(preferences.profiles.count, 1)
        XCTAssertEqual(preferences.activeProfileID, original)
    }

    func testRemovingFolderUngroupsInPlaceAndRemovingLastChildRemovesEmptyFolder() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = DockPreferences(defaults: defaults)
        let first = try application("One", at: root), second = try application("Two", at: root)
        XCTAssertTrue(preferences.addApplication(first))
        XCTAssertTrue(preferences.addApplication(second))
        let firstID = "app:\(first.path)", secondID = "app:\(second.path)"
        XCTAssertTrue(preferences.group(secondID, with: firstID))
        let folder = try XCTUnwrap(preferences.items.last)
        let prior = Array(preferences.items.dropLast())
        preferences.remove(id: folder.id)
        XCTAssertEqual(preferences.items, prior + folder.children)
        XCTAssertTrue(preferences.group(secondID, with: firstID))
        let nextFolder = try XCTUnwrap(preferences.items.last)
        preferences.remove(id: firstID)
        preferences.moveOutOfFolder(secondID)
        XCTAssertFalse(preferences.items.contains { $0.id == nextFolder.id })
        XCTAssertTrue(preferences.items.contains { $0.id == secondID })
        XCTAssertEqual(DockPreferences(defaults: defaults).items, preferences.items)
    }

    func testNormalizationFlattensNestedFoldersAndDeduplicatesApplicationsAcrossTree() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: DockPreferences.storageKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        let offline = DockElement(kind: .app, title: "Offline", applicationPath: "/Volumes/Disk/Offline.app")
        let folder = DockElement(id: "folder", kind: .folder, title: "Group", children: [
            DockElement(kind: .folder, children: [offline]), offline,
            DockElement(kind: .integration, integrationID: "music")
        ])
        let elements = try JSONEncoder().encode([folder, offline, DockElement(kind: .integration, integrationID: "future", span: 5)])
        profiles[0]["elements"] = try JSONSerialization.jsonObject(with: elements)
        json["profiles"] = profiles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: DockPreferences.storageKey)
        let restored = DockPreferences(defaults: defaults)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.items[0].children.count, 1)
        XCTAssertEqual(restored.items[0].children.first?.kind, .app)
        XCTAssertEqual(restored.items.last?.integrationID, "future")
        XCTAssertEqual(restored.items.last?.span, 5)
        XCTAssertEqual(preferences.profiles.count, 1)
    }

    func testClampingNotifiesOnceWithNormalizedValues() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        var values: [Double] = []
        preferences.onChange = { values.append(preferences.scale) }
        preferences.scale = .infinity
        XCTAssertEqual(values, [1])
        preferences.opacity = -1
        preferences.magnification = 20
        preferences.noteText = String(repeating: "x", count: 2_100)
        XCTAssertEqual(preferences.opacity, 0.45)
        XCTAssertEqual(preferences.magnification, 1)
        XCTAssertEqual(preferences.noteText.count, 2_000)
    }

    func testApplicationsAndStacksValidatePathsAndDoNotDuplicate() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try application("Example", at: root)
        XCTAssertFalse(preferences.addApplication(URL(string: "https://example.test/App.app")!))
        XCTAssertFalse(preferences.addApplication(root))
        XCTAssertTrue(preferences.addApplication(bundle))
        XCTAssertFalse(preferences.addApplication(bundle))
        XCTAssertTrue(preferences.addStack(root))
        XCTAssertFalse(preferences.addStack(root))
        XCTAssertFalse(preferences.addStack(bundle))
        XCTAssertFalse(preferences.addIntegration("unknown"))
        XCTAssertTrue(preferences.addIntegration("displays"))
        XCTAssertFalse(preferences.addIntegration("displays"))
    }

    func testOlderElementPayloadDefaultsOptionsAndSpan() throws {
        let element = try JSONDecoder().decode(DockElement.self, from: Data("{\"id\":\"a\",\"kind\":\"folder\"}".utf8))
        XCTAssertEqual(element.span, 1)
        XCTAssertEqual(element.options, [:])
        XCTAssertTrue(element.children.isEmpty)
    }

    func testMalformedNewPreferencesAreBackedUpBeforeRepair() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let malformed = Data("{invalid".utf8)
        defaults.set(malformed, forKey: DockPreferences.storageKey)
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertFalse(preferences.items.isEmpty)
        XCTAssertEqual(defaults.data(forKey: DockPreferences.storageKey + ".unreadableBackup"), malformed)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: DockPreferences.storageKey))))
    }

    func testRegistryCanAddFutureIntegrationAndLargerSupportedWidths() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        preferences.registerIntegrations(titles: ["weather": "Погода"], spans: ["weather": [2, 4, 4, -1, 20]])
        XCTAssertTrue(preferences.addIntegration("weather"))
        XCTAssertEqual(preferences.items.last?.title, "Погода")
        XCTAssertEqual(preferences.items.last?.span, 2)
        XCTAssertEqual(preferences.supportedSpans(for: try XCTUnwrap(preferences.items.last)), [2, 4])
        preferences.setSpan(4, for: "integration:weather")
        XCTAssertEqual(DockPreferences(defaults: defaults).items.last?.span, 4)
        preferences.registerIntegration(id: "invalid", title: "Invalid", supportedSpans: [])
        XCTAssertFalse(preferences.addIntegration("invalid"))
    }

    func testBookmarkFollowsMovedBundleInsideFolderAndProfilesWithoutChangingNote() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try application("MoveMe", at: root)
        let preferences = DockPreferences(defaults: defaults)
        preferences.noteText = "Shared note survives profiles"
        XCTAssertTrue(preferences.addApplication(original))
        let applicationID = "app:\(original.path)"
        XCTAssertNotNil(preferences.flattenedApps.last?.options[DockApplicationBookmark.optionKey])
        let folder = preferences.addFolder(name: "Work")
        XCTAssertTrue(preferences.moveIntoFolder(applicationID, folderID: folder))
        let profileID = preferences.activeProfileID
        _ = preferences.createProfile(name: "Copy", duplicateCurrent: true)
        let destination = root.appendingPathComponent("Moved.app")
        try FileManager.default.moveItem(at: original, to: destination)
        XCTAssertFalse(preferences.addApplication(destination))
        XCTAssertEqual(preferences.resolveApplicationPath(original.path), destination.path)
        XCTAssertEqual(preferences.resolveApplicationPath(original.path), destination.path)
        XCTAssertEqual(preferences.flattenedApps.last?.applicationPath, destination.path)
        preferences.selectProfile(profileID)
        XCTAssertEqual(preferences.items.last?.children.first?.applicationPath, destination.path)
        XCTAssertEqual(preferences.items.last?.children.first?.id, "app:\(destination.path)")
        let reloaded = DockPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.items.last?.children.first?.applicationPath, destination.path)
        XCTAssertEqual(reloaded.noteText, "Shared note survives profiles")
        XCTAssertFalse(reloaded.addApplication(destination))
    }

    func testBookmarkRelocatesOnLoadAndUnavailableBookmarkPreservesOriginalPin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try application("Original", at: root)
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertTrue(preferences.addApplication(original))
        let destination = root.appendingPathComponent("Renamed.app")
        try FileManager.default.moveItem(at: original, to: destination)
        let restored = DockPreferences(defaults: defaults)
        XCTAssertEqual(restored.flattenedApps.last?.applicationPath, destination.path)
        try FileManager.default.removeItem(at: destination)
        let unavailable = DockPreferences(defaults: defaults)
        XCTAssertEqual(unavailable.flattenedApps.last?.applicationPath, destination.path)
        XCTAssertNotNil(unavailable.flattenedApps.last?.options[DockApplicationBookmark.optionKey])
    }

    func testCorruptUnavailableBookmarkKeepsOriginalPathAndOtherOptions() throws {
        let original = DockElement(kind: .app, title: "Offline", applicationPath: "/Volumes/Missing-Dock-Test/Offline.app",
                                   options: [DockApplicationBookmark.optionKey: "invalid bookmark", "futureSetting": "keep"])
        let refreshed = try XCTUnwrap(DockApplicationBookmark.refreshed(original))
        XCTAssertEqual(refreshed.applicationPath, original.applicationPath)
        XCTAssertEqual(refreshed.options, original.options)
        XCTAssertEqual(refreshed.title, original.title)
    }

    @MainActor
    func testTrailingSectionAndFullscreenExclusionsPersistWithSafeDefaults() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showDownloads)
        XCTAssertTrue(preferences.showTrash)
        XCTAssertEqual(preferences.downloadsSort, .added)
        XCTAssertTrue(preferences.hideInFullscreenGames)
        XCTAssertTrue(preferences.hideInFullscreenVideo)
        XCTAssertTrue(preferences.addFullscreenExclusion(" com.example.game "))
        XCTAssertFalse(preferences.addFullscreenExclusion("com.example.game"))
        XCTAssertFalse(preferences.addFullscreenExclusion("   "))
        preferences.showTrash = false
        preferences.downloadsSort = .name
        preferences.hideInFullscreenVideo = false
        let reloaded = DockPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.fullscreenExclusions, ["com.example.game"])
        XCTAssertFalse(reloaded.showTrash)
        XCTAssertEqual(reloaded.downloadsSort, .name)
        XCTAssertFalse(reloaded.hideInFullscreenVideo)
        reloaded.removeFullscreenExclusion("com.example.game")
        XCTAssertTrue(DockPreferences(defaults: defaults).fullscreenExclusions.isEmpty)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "DockPreferencesTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func application(_ name: String, at root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.dock.\(name)", "CFBundleName": name], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle.standardizedFileURL.resolvingSymlinksInPath()
    }
}
