import AppKit
import XCTest
@testable import NotchApp

final class DockHoverTitleTests: XCTestCase {
    @MainActor
    func testTitlesFaceScreenInteriorAtEveryDockEdge() {
        let screen = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        let anchor = CGRect(x: -900, y: 100, width: 64, height: 60)
        let size = CGSize(width: 140, height: 32)
        let bottom = DockHoverTitlePresenter.frame(size: size, anchor: anchor, screen: screen, position: .bottom)
        XCTAssertEqual(bottom.midX, anchor.midX)
        XCTAssertEqual(bottom.minY, anchor.maxY + 8)
        let left = DockHoverTitlePresenter.frame(size: size, anchor: anchor, screen: screen, position: .left)
        XCTAssertEqual(left.minX, anchor.maxX + 8)
        XCTAssertEqual(left.midY, anchor.midY)
        let right = DockHoverTitlePresenter.frame(size: size, anchor: anchor, screen: screen, position: .right)
        XCTAssertEqual(right.maxX, anchor.minX - 8)
        XCTAssertEqual(right.midY, anchor.midY)
    }

    @MainActor
    func testTitleClampsToDisplayAndNeverChangesParentFrame() {
        _ = NSApplication.shared
        let screen = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        let frame = DockHoverTitlePresenter.frame(size: CGSize(width: 280, height: 32),
                                                 anchor: CGRect(x: -20, y: 975, width: 20, height: 25),
                                                 screen: screen, position: .bottom)
        XCTAssertTrue(screen.contains(frame))
        let parent = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let anchor = NSView(frame: CGRect(x: 40, y: 0, width: 64, height: 60))
        parent.contentView?.addSubview(anchor)
        parent.orderFrontRegardless()
        defer { parent.close() }
        let presenter = DockHoverTitlePresenter()
        presenter.anchor = anchor
        let original = parent.frame
        presenter.show(title: "Terminal", position: .bottom)
        XCTAssertNotNil(presenter.panel)
        XCTAssertEqual(presenter.panel?.ignoresMouseEvents, true)
        XCTAssertEqual(presenter.panel?.parent, parent)
        XCTAssertEqual(parent.frame, original)
        let shortWidth = try! XCTUnwrap(presenter.panel).frame.width
        XCTAssertGreaterThan(shortWidth, 65, "The title must use its full measured width")
        let longTitle = String(repeating: "Длинное название приложения ", count: 5)
        presenter.show(title: longTitle, position: .bottom)
        let bubble = try! XCTUnwrap(presenter.panel)
        let label = bubble.contentView?.subviews.first as? NSTextField
        XCTAssertEqual(label?.stringValue, longTitle)
        XCTAssertEqual(label?.maximumNumberOfLines, 0)
        XCTAssertEqual(label?.lineBreakMode, .byCharWrapping)
        XCTAssertLessThanOrEqual(bubble.frame.width, 432)
        XCTAssertGreaterThan(bubble.frame.height, 40)
        XCTAssertEqual(parent.frame, original)
        presenter.hide()
        XCTAssertNil(presenter.panel)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }
}
