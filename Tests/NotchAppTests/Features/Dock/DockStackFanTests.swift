import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockStackFanTests: XCTestCase {
    func testFanRowsRiseAlongArcAndStayInsideTheWindow() {
        let layout = DockFanLayout(rows: 11)
        var previous = layout.iconCenter(0)
        XCTAssertEqual(previous.x, layout.origin.x, accuracy: 1, "The first icon sits above the stack icon")
        for row in 1..<layout.rows {
            let point = layout.iconCenter(row)
            XCTAssertLessThan(point.y, previous.y, "Rows rise")
            XCTAssertGreaterThan(point.x, previous.x, "The arc bends away from the stack")
            XCTAssertGreaterThan(layout.angle(row), layout.angle(row - 1))
            previous = point
        }
        let top = layout.iconCenter(layout.rows - 1)
        XCTAssertGreaterThanOrEqual(top.y - DockFanLayout.rowHeight / 2, 0)
        XCTAssertLessThanOrEqual(top.x + DockFanLayout.iconSize / 2, layout.size.width)
        XCTAssertGreaterThanOrEqual(layout.origin.x - DockFanLayout.rowWidth + DockFanLayout.iconSize / 2, 0,
                                    "Labels of the first row fit on the left")
        XCTAssertLessThan(layout.angle(layout.rows - 1), .pi / 6, "A subtle fan, not a spiral")
    }

    func testFanWindowAnchorsAboveDockAndStaysOnScreen() {
        let layout = DockFanLayout(rows: 6)
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 943)
        let frame = layout.windowFrame(anchor: CGRect(x: 700, y: 10, width: 64, height: 64), dockTop: 84, screen: screen)
        XCTAssertEqual(frame.minY, 86)
        XCTAssertEqual(frame.minX + layout.origin.x, 732, accuracy: 0.5)
        let edge = layout.windowFrame(anchor: CGRect(x: 1_480, y: 10, width: 30, height: 64), dockTop: 84, screen: screen)
        XCTAssertLessThanOrEqual(edge.maxX, screen.maxX)
    }

    func testPresenterTracksInteractionAndDismissal() throws {
        _ = NSApplication.shared
        guard NSScreen.screens.first != nil else { throw XCTSkip("Requires an AppKit display") }
        let presenter = DockFanPresenter()
        var states: [Bool] = []
        let file = DockStackFile(url: URL(fileURLWithPath: "/tmp/a.pdf"), title: "a.pdf", isDirectory: false, modifiedAt: nil)
        presenter.present(element: DockElement(id: "stack:/tmp", kind: .stack, title: "tmp", directoryPath: "/tmp"),
                          files: [file], provider: DockFileStackProvider(),
                          anchor: CGRect(x: 400, y: 10, width: 64, height: 64), dockTop: 84,
                          screen: NSScreen.screens[0].visibleFrame, interactionChanged: { states.append($0) })
        XCTAssertEqual(presenter.presentedID, "stack:/tmp")
        XCTAssertNotNil(presenter.window)
        XCTAssertTrue(try XCTUnwrap(presenter.window).backgroundColor == .clear)
        presenter.dismiss()
        XCTAssertNil(presenter.presentedID)
        XCTAssertNil(presenter.window)
        XCTAssertEqual(states, [true, false])
        presenter.dismiss()
        XCTAssertEqual(states, [true, false], "Dismissal reports once")
    }

    /// Visual check: NOOL_FAN_SNAPSHOT=/path.png renders the fan with sample files.
    func testRenderFanSnapshotWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["NOOL_FAN_SNAPSHOT"] else { throw XCTSkip("Snapshot not requested") }
        let names = ["Юлтыев_НВ_Расчетный_лист_Август_2026.pdf", "Расчетный лист.pdf", "Invoice-OSPSU54Y-0001.pdf",
                     "Юлтыев Наиль Вадимович.pdf", "resume.pdf", "Screenshot 2026-10-20.png", "notes.txt"]
        let files = names.map { DockStackFile(url: URL(fileURLWithPath: "/tmp/\($0)"), title: $0, isDirectory: false, modifiedAt: nil) }
        let layout = DockFanLayout(rows: files.count + 1)
        let view = DockFanView(element: DockElement(kind: .stack, title: "Загрузки", directoryPath: "/tmp"), files: files,
                               provider: DockFileStackProvider(), layout: layout, dismiss: {})
            .background(Color(white: 0.85))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: output))
    }
}
