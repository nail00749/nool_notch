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

    func testQuarterAndThirdActionsUseVisibleFrameInAXCoordinates() throws {
        let original = WindowLayoutRect(x: -1_700, y: -100, width: 900, height: 650)
        let expected: [(WindowLayoutAction, WindowLayoutRect)] = [
            (.topLeft, .init(x: -1_920, y: -156, width: 960, height: 513)),
            (.topRight, .init(x: -960, y: -156, width: 960, height: 513)),
            (.bottomLeft, .init(x: -1_920, y: 357, width: 960, height: 513)),
            (.bottomRight, .init(x: -960, y: 357, width: 960, height: 513)),
            (.leftThird, .init(x: -1_920, y: -156, width: 640, height: 1_026)),
            (.centerThird, .init(x: -1_280, y: -156, width: 640, height: 1_026)),
            (.rightThird, .init(x: -640, y: -156, width: 640, height: 1_026)),
            (.leftTwoThirds, .init(x: -1_920, y: -156, width: 1_280, height: 1_026)),
            (.rightTwoThirds, .init(x: -1_280, y: -156, width: 1_280, height: 1_026))
        ]
        for (action, target) in expected {
            XCTAssertEqual(WindowLayoutGeometry.target(for: action, current: original,
                                                        screens: [primary, leftDisplay]), target, "\(action)")
            XCTAssertEqual(WindowLayoutGeometry.target(for: action, current: target,
                                                        screens: [primary, leftDisplay]), target,
                           "Repeating a tiling action must not move it again")
        }
    }

    func testDisplayNavigationIsSpatialAndIndependentOfScreenEnumeration() throws {
        let right = WindowLayoutScreen(id: "right",
            frame: .init(x: 1_440, y: 0, width: 1_440, height: 900),
            visibleFrame: .init(x: 1_440, y: 24, width: 1_440, height: 826))
        let current = WindowLayoutRect(x: 360, y: 230.5, width: 720, height: 413)
        let next = try XCTUnwrap(WindowLayoutGeometry.target(for: .nextDisplay, current: current,
                                                           screens: [right, primary, leftDisplay]))
        let previous = try XCTUnwrap(WindowLayoutGeometry.target(for: .previousDisplay, current: current,
                                                               screens: [primary, right, leftDisplay]))
        XCTAssertEqual(WindowLayoutGeometry.screen(for: next, in: [leftDisplay, primary, right])?.id, "right")
        XCTAssertEqual(WindowLayoutGeometry.screen(for: previous, in: [right, primary, leftDisplay])?.id, "left")
        XCTAssertEqual(WindowLayoutGeometry.target(for: .previousDisplay, current: next,
                                                   screens: [leftDisplay, primary, right]), current)
        let wrapped = try XCTUnwrap(WindowLayoutGeometry.target(for: .nextDisplay, current: next,
                                                              screens: [right, primary, leftDisplay]))
        XCTAssertEqual(WindowLayoutGeometry.screen(for: wrapped, in: [leftDisplay, primary, right])?.id, "left")
        XCTAssertNil(WindowLayoutGeometry.target(for: .previousDisplay, current: current, screens: [primary]))
    }

    func testRestoreReturnsOriginalDisplayAndClampsWhenDisconnected() {
        let original = WindowLayoutOriginalPlacement(
            frame: .init(x: -1_700, y: -100, width: 900, height: 650), displayID: leftDisplay.id)
        XCTAssertEqual(WindowLayoutGeometry.originalTarget(original, current: primary.visibleFrame,
                                                           screens: [primary, leftDisplay]), original.frame)
        XCTAssertEqual(WindowLayoutGeometry.originalTarget(original, current: primary.visibleFrame,
                                                           screens: [primary]),
                       .init(x: 0, y: 24, width: 900, height: 650))
        XCTAssertNil(WindowLayoutGeometry.originalTarget(original, current: primary.visibleFrame, screens: []))
    }

    func testRestoreHistoryPreservesFirstSuccessfulPlacementThroughCommandChainsAndFailures() {
        var history = WindowLayoutRestoreHistory<Int>()
        let date = Date(timeIntervalSince1970: 1)
        let original = WindowLayoutOriginalPlacement(frame: .init(x: 150, y: 160, width: 640, height: 480), displayID: "primary")
        let tiled = WindowLayoutOriginalPlacement(frame: primary.visibleFrame, displayID: "primary")
        history.finish(action: .left, didApply: false, pid: 1, launchDate: date, window: 10, original: original)
        XCTAssertNil(history.original(pid: 1, launchDate: date, window: 10))
        history.finish(action: .left, didApply: true, pid: 1, launchDate: date, window: 10, original: original)
        for action in [WindowLayoutAction.left, .maximize, .center, .nextDisplay, .rightTwoThirds] {
            history.finish(action: action, didApply: true, pid: 1, launchDate: date, window: 10, original: tiled)
        }
        XCTAssertEqual(history.original(pid: 1, launchDate: date, window: 10), original)
        history.finish(action: .restore, didApply: false, pid: 1, launchDate: date, window: 10, original: tiled)
        XCTAssertEqual(history.original(pid: 1, launchDate: date, window: 10), original, "A failed restore remains retryable")
        history.finish(action: .restore, didApply: true, pid: 1, launchDate: date, window: 10, original: tiled)
        XCTAssertNil(history.original(pid: 1, launchDate: date, window: 10))
        history.finish(action: .right, didApply: true, pid: 1, launchDate: date, window: 10, original: tiled)
        XCTAssertEqual(history.original(pid: 1, launchDate: date, window: 10), tiled, "A new command chain gets a new original")
    }

    func testRestoreHistorySeparatesWindowsDiscardsReusedPIDsAndBoundsRetention() {
        var history = WindowLayoutRestoreHistory<Int>(limit: 2)
        let date = Date(timeIntervalSince1970: 1)
        let original = WindowLayoutOriginalPlacement(frame: primary.visibleFrame, displayID: primary.id)
        for window in 1...3 {
            history.finish(action: .left, didApply: true, pid: 1, launchDate: date, window: window, original: original)
        }
        XCTAssertNil(history.original(pid: 1, launchDate: date, window: 1))
        XCTAssertEqual(history.original(pid: 1, launchDate: date, window: 2), original)
        XCTAssertEqual(history.original(pid: 1, launchDate: date, window: 3), original)
        XCTAssertNil(history.original(pid: 2, launchDate: date, window: 2))
        XCTAssertNil(history.original(pid: 1, launchDate: date.addingTimeInterval(1), window: 2), "A reused PID cannot restore an old process window")
        XCTAssertNil(history.original(pid: 1, launchDate: date, window: 3), "All entries of the old process must be purged")
        history.finish(action: .left, didApply: true, pid: 1, launchDate: nil, window: 4, original: original)
        XCTAssertNil(history.original(pid: 1, launchDate: nil, window: 4), "Unverifiable process identities must not be cached")
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
