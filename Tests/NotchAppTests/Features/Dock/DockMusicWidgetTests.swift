import XCTest
@testable import NotchApp

final class DockMusicWidgetTests: XCTestCase {
    func testOneTrackChangePerScrollGesture() {
        XCTAssertNil(DockScrollWheelNSView.step(for: 10, consumed: false), "Small nudges do nothing")
        XCTAssertEqual(DockScrollWheelNSView.step(for: 30, consumed: false), 1)
        XCTAssertEqual(DockScrollWheelNSView.step(for: -30, consumed: false), -1)
        XCTAssertNil(DockScrollWheelNSView.step(for: 300, consumed: true), "Momentum doesn't skip several tracks")
    }

    func testBottomPanelGainsHeadroomAboveTheStripOnly() {
        let strip = CGRect(x: 100, y: 8, width: 600, height: 64)
        let frame = DockLayout.windowFrame(strip: strip, position: .bottom, scale: 1)
        XCTAssertEqual(frame.minY, strip.minY)
        XCTAssertEqual(frame.width, strip.width)
        XCTAssertEqual(frame.height, strip.height + DockLayout.headroom(scale: 1))
        XCTAssertGreaterThan(DockLayout.headroom(scale: 1), 14, "Room for the 14 pt launch bounce")
        let right = DockLayout.windowFrame(strip: CGRect(x: 900, y: 100, width: 76, height: 500), position: .right, scale: 1)
        XCTAssertEqual(right.maxX, 976)
    }
}
