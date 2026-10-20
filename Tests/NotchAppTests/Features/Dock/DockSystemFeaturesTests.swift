import AppKit
import XCTest
@testable import NotchApp

@MainActor
final class DockSystemFeaturesTests: XCTestCase {
    func testNewBehaviourSettingsPersistWithDefaultsForOlderPayloads() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        XCTAssertEqual(prefs.position, .bottom)
        XCTAssertTrue(prefs.showRecentApplications)
        XCTAssertTrue(prefs.animateLaunch)
        XCTAssertTrue(prefs.dimHiddenApplications)
        XCTAssertTrue(prefs.hideHotKeyEnabled)
        XCTAssertEqual(prefs.downloadsStyle, .automatic)
        XCTAssertTrue(prefs.showBadges)
        XCTAssertTrue(prefs.showMinimizedWindows)
        prefs.position = .left
        prefs.animateLaunch = false
        prefs.dimHiddenApplications = false
        prefs.hideHotKeyEnabled = false
        prefs.downloadsStyle = .grid
        prefs.showBadges = false
        prefs.showMinimizedWindows = false
        let restored = DockPreferences(defaults: defaults)
        XCTAssertEqual(restored.position, .left)
        XCTAssertFalse(restored.animateLaunch)
        XCTAssertFalse(restored.dimHiddenApplications)
        XCTAssertFalse(restored.hideHotKeyEnabled)
        XCTAssertEqual(restored.downloadsStyle, .grid)
        XCTAssertFalse(restored.showBadges)
        XCTAssertFalse(restored.showMinimizedWindows)
    }

    func testRecentApplicationsAreDeduplicatedBoundedAndClearedWhenDisabled() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        for index in 0..<10 { prefs.noteLaunchedApplication("/Applications/App\(index).app") }
        prefs.noteLaunchedApplication("/Applications/App3.app")
        prefs.noteLaunchedApplication("relative.app")
        prefs.noteLaunchedApplication("/Applications/readme.txt")
        XCTAssertEqual(prefs.recentApplications.first, "/Applications/App3.app")
        XCTAssertEqual(prefs.recentApplications.count, 8)
        XCTAssertEqual(Set(prefs.recentApplications).count, 8)
        XCTAssertEqual(DockPreferences(defaults: defaults).recentApplications, prefs.recentApplications)
        prefs.showRecentApplications = false
        XCTAssertTrue(prefs.recentApplications.isEmpty)
        prefs.noteLaunchedApplication("/Applications/Later.app")
        XCTAssertTrue(prefs.recentApplications.isEmpty, "Nothing is recorded while the section is off")
    }

    func testRecentSectionSkipsPinnedRunningAndMissingApplications() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        let feature = DockFeatureModel(prefs: prefs)
        prefs.noteLaunchedApplication("/System/Applications/Calculator.app")
        prefs.noteLaunchedApplication("/System/Applications/Chess.app")
        prefs.noteLaunchedApplication("/Applications/Missing-NooL-Test.app")
        prefs.noteLaunchedApplication("/System/Library/CoreServices/Finder.app")
        feature.applications.updateRunningApplications([
            DockRunningApplication(path: "/System/Applications/Chess.app", title: "Chess", pid: 7, icon: nil, isActive: false)
        ], reconcilePinnedPaths: false)
        XCTAssertEqual(feature.recentApplications.map(\.path), ["/System/Applications/Calculator.app"])
        prefs.showRecentApplications = false
        XCTAssertTrue(feature.recentApplications.isEmpty)
    }

    func testMoveToEndAndAutoHideShortcutToggle() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        let first = try XCTUnwrap(prefs.items.first?.id)
        prefs.moveToEnd(id: first)
        XCTAssertEqual(prefs.items.last?.id, first)
        prefs.visibility = .always
        prefs.toggleAutoHide()
        XCTAssertEqual(prefs.visibility, .autoHide)
        prefs.toggleAutoHide()
        XCTAssertEqual(prefs.visibility, .always)
        prefs.visibility = .intelligent
        prefs.toggleAutoHide()
        XCTAssertEqual(prefs.visibility, .always)
    }

    func testVerticalDockForcesCompactWidgetsAndUsesSideGeometry() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        let feature = DockFeatureModel(prefs: prefs)
        let music = try XCTUnwrap(prefs.items.first { $0.integrationID == "music" })
        XCTAssertEqual(feature.effectiveElement(music).span, 2)
        prefs.position = .right
        XCTAssertEqual(feature.effectiveElement(music).span, 1)
        XCTAssertEqual(feature.popoverEdge, .leading)

        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 943)
        let left = DockLayout.frame(screenFrame: screen, visibleFrame: visible, contentWidth: 400, scale: 1,
                                    replacingSystemDock: false, position: .left)
        XCTAssertEqual(left.minX, 8)
        XCTAssertEqual(left.width, DockLayout.verticalThickness(scale: 1))
        XCTAssertEqual(left.height, 400)
        XCTAssertEqual(left.midY, visible.midY, accuracy: 0.5)
        let right = DockLayout.frame(screenFrame: screen, visibleFrame: visible, contentWidth: 5_000, scale: 1,
                                     replacingSystemDock: true, position: .right)
        XCTAssertEqual(right.maxX, screen.maxX - 8)
        XCTAssertEqual(right.height, screen.height - 24)
        XCTAssertEqual(DockLayout.triggerFrame(screenFrame: screen, dockFrame: left, position: .left),
                       CGRect(x: 0, y: left.minY, width: 5, height: left.height))
        XCTAssertEqual(DockLayout.triggerFrame(screenFrame: screen, dockFrame: right, position: .right),
                       CGRect(x: screen.maxX - 5, y: right.minY, width: 5, height: right.height))
    }

    func testStripLengthCountsSeparatorsTrailingCellsAndVerticalUnits() {
        let scale = 1.0
        let gap = DockLayout.spacing(scale: scale)
        let horizontal = DockLayout.stripLength(spans: [1, 2], separators: 1, trailingCells: 2, scale: scale,
                                                showLabels: false, vertical: false)
        let expected = DockLayout.width(span: 1, scale: scale) + DockLayout.width(span: 2, scale: scale) + gap
            + (1 + gap) + DockLayout.trailingWidth(cells: 2, scale: scale)
        XCTAssertEqual(horizontal, expected, accuracy: 0.001)
        let vertical = DockLayout.stripLength(spans: [1, 3], separators: 0, trailingCells: 0, scale: scale,
                                              showLabels: true, vertical: true)
        XCTAssertEqual(vertical, 2 * DockLayout.contentHeight(showLabels: true) + gap + DockLayout.chromeWidth, accuracy: 0.001)
    }

    func testStackStyleResolution() {
        XCTAssertEqual(DockStackStyle.automatic.resolved(itemCount: 6, position: .bottom), .fan)
        XCTAssertEqual(DockStackStyle.automatic.resolved(itemCount: 30, position: .bottom), .grid)
        XCTAssertEqual(DockStackStyle.automatic.resolved(itemCount: 3, position: .left), .grid)
        XCTAssertEqual(DockStackStyle.fan.resolved(itemCount: 3, position: .right), .grid)
        XCTAssertEqual(DockStackStyle.list.resolved(itemCount: 3, position: .bottom), .list)
    }

    func testLaunchingStateEndsWhenApplicationAppearsAndHiddenStatePublishes() {
        let store = DockApplicationStore()
        let path = "/System/Applications/Calculator.app"
        store.beginLaunching(path)
        XCTAssertTrue(store.launching.contains(path))
        store.updateRunningApplications([
            DockRunningApplication(path: path, title: "Calculator", pid: 42, icon: nil, isActive: false)
        ], reconcilePinnedPaths: false)
        XCTAssertFalse(store.launching.contains(path))
        store.updateRunningApplications([
            DockRunningApplication(path: path, title: "Calculator", pid: 42, icon: nil, isActive: false, isHidden: true)
        ], reconcilePinnedPaths: false)
        XCTAssertEqual(store.running.first?.isHidden, true)
        store.stop()
    }

    func testFileTransferMovesWithinVolumeRenamesCollisionsAndSkipsSelfDrops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DockTransfer-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("report.txt")
        try Data("a".utf8).write(to: file)
        try Data("b".utf8).write(to: target.appendingPathComponent("report.txt"))
        let copied = source.appendingPathComponent("copy.txt")
        try Data("c".utf8).write(to: copied)

        XCTAssertTrue(DockFileTransfer.transfer([file], into: target, forceCopy: false).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Same volume moves")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("report 2.txt"), encoding: .utf8), "a")
        XCTAssertTrue(DockFileTransfer.transfer([copied], into: target, forceCopy: true).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "⌥ copies")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("copy.txt").path))

        let inTarget = target.appendingPathComponent("copy.txt")
        XCTAssertTrue(DockFileTransfer.transfer([inTarget, root], into: target, forceCopy: false).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("copy 2.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "A folder is never moved into itself")
    }

    func testLoginItemsReadStateBeforeTogglingAndPassPathAsArgument() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = LoginItemRecorder(list: "/Applications/Mail.app\n/Applications/Notes.app/\n")
        let items = DockLoginItems(defaults: defaults, runner: recorder.run)
        items.refreshIfUsed()
        XCTAssertTrue(recorder.calls.isEmpty, "No System Events query before the user uses the feature")
        items.toggle(path: "/Applications/Notes.app")
        for _ in 0..<200 where !items.contains("/Applications/Mail.app") { try await Task.sleep(for: .milliseconds(5)) }
        let calls = recorder.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0], DockLoginItems.listScript)
        XCTAssertEqual(calls[1], DockLoginItems.removeScript + ["/Applications/Notes.app"])
        XCTAssertTrue(defaults.bool(forKey: DockLoginItems.usedKey))
        XCTAssertEqual(DockLoginItems.parse("/A.app\nrelative\n/B.app/\n"), ["/A.app", "/B.app"])
    }

    func testDragOutsideBoundaryUsesPanelFrameWithMargin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let feature = DockFeatureModel(prefs: DockPreferences(defaults: defaults))
        XCTAssertFalse(feature.isOutsideDock(CGPoint(x: 5_000, y: 5_000)), "Unknown frame never removes")
        feature.dockFrame = CGRect(x: 100, y: 8, width: 400, height: 76)
        XCTAssertFalse(feature.isOutsideDock(CGPoint(x: 300, y: 100)))
        XCTAssertTrue(feature.isOutsideDock(CGPoint(x: 300, y: 200)))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "DockSystemFeaturesTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}

private final class LoginItemRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var list: String

    init(list: String) { self.list = list }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        lock.withLock {
            recorded.append(arguments)
            if arguments == DockLoginItems.removeScript + ["/Applications/Notes.app"] {
                list = "/Applications/Mail.app\n"
            }
            return (0, arguments == DockLoginItems.listScript ? list : "")
        }
    }
}

@MainActor
final class DockPreviewSizingTests: XCTestCase {
    func testThumbnailKeepsWindowAspectWithinBounds() {
        let wide = DockPreviewSurface.thumbnailSize(image: CGSize(width: 3_024, height: 1_890), frame: .zero)
        XCTAssertEqual(wide.width, 260)
        XCTAssertEqual(wide.height, 163, accuracy: 1)
        let tall = DockPreviewSurface.thumbnailSize(image: nil, frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        XCTAssertEqual(tall.height, 170)
        XCTAssertEqual(tall.width, 96, "Very narrow windows keep a usable minimum width")
        XCTAssertEqual(DockPreviewSurface.thumbnailSize(image: nil, frame: .zero), CGSize(width: 206, height: 130))
    }

    func testPreviewLayoutIsSizedFromWindowFramesUpFront() {
        let two = DockPreviewSurface.layout(frames: [CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                                                    CGRect(x: 0, y: 0, width: 800, height: 800)], hints: 1)
        XCTAssertEqual(two.width, 260 + 10 + 170)
        XCTAssertEqual(two.thumbnailHeight, 170)
        XCTAssertEqual(two.contentHeight, 170 + 24 + 16)
        let many = DockPreviewSurface.layout(frames: Array(repeating: CGRect(x: 0, y: 0, width: 1_600, height: 1_000), count: 9), hints: 0)
        XCTAssertEqual(many.width, 640, "Wide rows scroll instead of growing the popover")
        let none = DockPreviewSurface.layout(frames: [], hints: 0)
        XCTAssertGreaterThan(none.thumbnailHeight, 0, "Unknown windows still reserve a thumbnail row")
    }
}

@MainActor
final class SystemPermissionsTests: XCTestCase {
    func testEveryPermissionHasSettingsLinkAndOnlyFullDiskAccessIsSettingsOnly() {
        for permission in SystemPermission.allCases {
            XCTAssertNotNil(permission.settingsURL, permission.title)
            XCTAssertFalse(permission.purpose.isEmpty)
            XCTAssertEqual(permission.canRequest, permission != .fullDiskAccess)
        }
        XCTAssertEqual(SystemPermission.automationFinder.automationBundleIdentifier, "com.apple.finder")
        XCTAssertEqual(SystemPermission.automationSystemEvents.automationBundleIdentifier, "com.apple.systemevents")
        XCTAssertNotEqual(SystemPermissionsModel.fullDiskAccessStatus(), .notDetermined)
    }

    func testFinderStyleStackModesStayExplicit() {
        for style in [DockStackStyle.grid, .list, .columns, .gallery] {
            XCTAssertEqual(style.resolved(itemCount: 3, position: .bottom), style)
        }
        XCTAssertEqual(DockStackStyle.grid.title, "Значки")
    }
}
