import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class WindowLayoutTests: XCTestCase {
    private let primary = WindowLayoutScreen(
        id: "primary",
        frame: .init(x: 0, y: 0, width: 1_440, height: 900),
        visibleFrame: .init(x: 0, y: 24, width: 1_440, height: 826)
    )
    private let leftDisplay = WindowLayoutScreen(
        id: "left",
        frame: .init(x: -1_920, y: -180, width: 1_920, height: 1_080),
        visibleFrame: .init(x: -1_920, y: -156, width: 1_920, height: 1_026)
    )

    func testHalfActionsUseVisibleFrameWithNegativeDisplayOrigin() {
        let original = WindowLayoutRect(x: -1_700, y: -100, width: 900, height: 650)
        let screens = [primary, leftDisplay]

        XCTAssertEqual(
            WindowLayoutGeometry.target(for: .left, current: original, screens: screens),
            WindowLayoutRect(x: -1_920, y: -156, width: 960, height: 1_026)
        )
        XCTAssertEqual(
            WindowLayoutGeometry.target(for: .right, current: original, screens: screens),
            WindowLayoutRect(x: -960, y: -156, width: 960, height: 1_026)
        )
    }

    func testCenterClampsOversizedWindowIntoVisibleFrame() {
        let original = WindowLayoutRect(x: 200, y: 50, width: 2_000, height: 1_200)
        XCTAssertEqual(
            WindowLayoutGeometry.target(for: .center, current: original, screens: [primary]),
            primary.visibleFrame
        )
    }

    func testNextDisplayScalesAndClampsRelativePosition() {
        let current = WindowLayoutRect(x: 360, y: 230.5, width: 720, height: 413)
        let target = WindowLayoutGeometry.target(
            for: .nextDisplay, current: current, screens: [primary, leftDisplay]
        )
        XCTAssertEqual(target, WindowLayoutRect(x: -1_440, y: 100.5,
                                                width: 960, height: 513))
        XCTAssertNil(WindowLayoutGeometry.target(for: .nextDisplay,
                                                current: current, screens: [primary]))
    }

    func testSavedLayoutDecodesAndRemovalPersists() throws {
        let suiteName = "WindowLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = SavedWindowLayout(
            id: UUID(),
            name: "Рабочий стол",
            windows: [SavedWindowPlacement(
                bundleIdentifier: "com.example.Editor",
                windowTitle: "Document",
                ordinal: 0,
                displayID: "left",
                normalizedFrame: WindowLayoutRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
            )]
        )
        defaults.set(try JSONEncoder().encode([layout]), forKey: "nool.windowLayouts.v1")

        let manager = WindowLayoutManager(defaults: defaults)
        XCTAssertEqual(manager.layouts, [layout])

        manager.removeLayout(id: layout.id)
        XCTAssertTrue(WindowLayoutManager(defaults: defaults).layouts.isEmpty)
    }

    func testLauncherCommandsAreSearchableOnlyInAllCategoryWithQuery() {
        let layout = SavedWindowLayout(id: UUID(), name: "Разработка", windows: [])
        XCTAssertTrue(LauncherResult.windowCommands(layouts: [layout], query: "", category: .all).isEmpty)
        for category in LauncherCategory.allCases where category != .all {
            XCTAssertTrue(LauncherResult.windowCommands(layouts: [layout], query: "окно", category: category).isEmpty)
        }
        let commands = LauncherResult.windowCommands(layouts: [layout], query: "окно", category: .all)
        let left = LauncherModel.searchResults(commands, clipboard: [], query: "слева", category: .all)
        XCTAssertTrue(left.contains { $0.payload == .windowAction(.left) })
        let saved = LauncherModel.searchResults(commands, clipboard: [], query: "Разработка", category: .all)
        XCTAssertEqual(saved.first?.payload, .windowLayout(layout.id))
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
    }
}
