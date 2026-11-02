import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class LauncherLayoutFixtureTests: XCTestCase {
    @MainActor
    func testRenderApplicationLayouts() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_LAUNCHER_RENDER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in AppKit fixture using the installed application catalog")
        }
        let suite = "launcher-layout-fixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LauncherSettings(defaults: defaults)
        let model = LauncherModel(settings: settings)
        defer { model.dismiss() }
        await model.applications.refresh()
        model.category = .applications
        for _ in 0..<100 where model.results.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(model.results.count, 5)
        let initial = try XCTUnwrap(model.selectedID)
        settings.applicationLayout = .grid
        XCTAssertTrue(model.moveApplicationHorizontally(1))
        XCTAssertEqual(model.selectedID, model.results[1].id)
        model.move(1)
        XCTAssertEqual(model.selectedID, model.results[6].id)
        model.selectResult(initial)

        let view = LauncherView(model: model, activate: { _, _ in }, reveal: { _ in }, close: {},
                                openSettings: {}, focusInput: {}, requestSelectionAccess: {},
                                pasteAIResponse: { _ in }, chooseAttachments: {}, openWindowLayouts: {},
                                openWorkspaces: {}, captureScreenText: {}, openSpeedTest: {},
                                performAction: { _, _ in })
        for layout in LauncherApplicationLayout.allCases {
            settings.applicationLayout = layout
            let size = NSSize(width: 680, height: 492)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .preferredColorScheme(.dark))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/nool-launcher-\(layout.rawValue).png"))
            window.close()
            XCTAssertEqual(model.selectedID, initial)
        }

        settings.applicationLayout = .grid
        model.query = "a"
        for _ in 0..<100 where model.results.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.moveApplicationHorizontally(-1), "Query editing must keep native caret movement")
        model.move(1)
        XCTAssertEqual(model.selectedID, model.results[1].id, "Queries must allow visiting every tile with ↑/↓")
    }
}
