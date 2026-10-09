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

    func testSideControlsKeepExpandedSurfaceCenteredInsideWiderWindow() {
        let shape = NotchSurfaceShape(
            compactWindowSize: CGSize(width: 300, height: 60),
            compactSurfaceHeight: 44,
            expandedHeight: 400,
            expandedSurfaceWidth: 500
        )

        XCTAssertEqual(
            shape.surfaceRect(in: CGRect(x: 0, y: 0, width: 620, height: 400)),
            CGRect(x: 60, y: 0, width: 500, height: 400)
        )
    }

    func testExpandedInteractionRegionIncludesSurfaceAndButtonsButExcludesEmptyLanes() {
        let surfaceShape = NotchSurfaceShape(
            compactWindowSize: CGSize(width: 300, height: 60),
            compactSurfaceHeight: 44,
            expandedHeight: 400,
            expandedSurfaceWidth: 500,
            holdsExpandedShape: true
        )
        let interactionShape = NotchRootInteractionShape(
            isExpanded: true,
            expandedSurfaceShape: surfaceShape,
            sideControlsTop: 56,
            leadingButtonCount: 2,
            trailingButtonCount: 2,
            excludesLeadingMascotLane: false
        )
        let panelBounds = CGRect(x: 0, y: 0, width: 620, height: 400)
        let path = interactionShape.path(in: panelBounds)

        XCTAssertTrue(path.contains(CGPoint(x: 70, y: 200)))
        XCTAssertTrue(path.contains(CGPoint(x: 21, y: 77)))
        XCTAssertTrue(path.contains(CGPoint(x: 599, y: 129)))
        XCTAssertFalse(path.contains(CGPoint(x: 21, y: 103)))
        XCTAssertFalse(path.contains(CGPoint(x: 599, y: 103)))
    }
}
