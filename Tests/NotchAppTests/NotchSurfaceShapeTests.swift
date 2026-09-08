import SwiftUI
import XCTest
@testable import NotchApp

final class NotchSurfaceShapeTests: XCTestCase {
    func testSwitchingExpandedPanelsDoesNotReintroduceCompactInsets() {
        let shape = NotchSurfaceShape(
            compactWindowSize: CGSize(width: 300, height: 60),
            compactSurfaceHeight: 44, expandedHeight: 500,
            holdsExpandedShape: true
        )
        let shortExpandedFrame = CGRect(x: 0, y: 0, width: 500, height: 338)
        XCTAssertEqual(shape.surfaceRect(in: shortExpandedFrame), shortExpandedFrame)
    }

    func testSurfaceFollowsActualIntermediateWindowBoundsWithoutJumpingToExpandedSize() {
        let shape = NotchSurfaceShape(
            compactWindowSize: CGSize(width: 300, height: 60),
            compactSurfaceHeight: 44, expandedHeight: 400
        )
        XCTAssertEqual(shape.surfaceRect(in: CGRect(x: 0, y: 0, width: 300, height: 60)),
                       CGRect(x: 18, y: 0, width: 264, height: 44))
        XCTAssertEqual(shape.surfaceRect(in: CGRect(x: 0, y: 0, width: 400, height: 230)),
                       CGRect(x: 9, y: 0, width: 382, height: 222))
        XCTAssertEqual(shape.surfaceRect(in: CGRect(x: 0, y: 0, width: 500, height: 400)),
                       CGRect(x: 0, y: 0, width: 500, height: 400))
    }
}
