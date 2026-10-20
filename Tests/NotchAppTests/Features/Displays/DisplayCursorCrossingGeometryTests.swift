import CoreGraphics
import XCTest
@testable import NotchApp

final class DisplayCursorCrossingGeometryTests: XCTestCase {
    private let source = DisplayCursorCrossingScreen(uuid: "source", displayID: 1,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100))

    func testAllFourOutwardDirectionsProjectInsideFacingTarget() {
        let cases: [(CGRect, CGPoint, CGVector, CGPoint)] = [
            (CGRect(x: 100, y: 20, width: 100, height: 60), CGPoint(x: 99, y: 10), CGVector(dx: 3, dy: 0), CGPoint(x: 102, y: 22)),
            (CGRect(x: -100, y: 20, width: 100, height: 60), CGPoint(x: 0.5, y: 10), CGVector(dx: -3, dy: 0), CGPoint(x: -2, y: 22)),
            (CGRect(x: 20, y: 100, width: 60, height: 100), CGPoint(x: 10, y: 99), CGVector(dx: 0, dy: 3), CGPoint(x: 22, y: 102)),
            (CGRect(x: 20, y: -100, width: 60, height: 100), CGPoint(x: 10, y: 0.5), CGVector(dx: 0, dy: -3), CGPoint(x: 22, y: -2))
        ]
        for (frame, location, delta, expected) in cases {
            let target = screen("target", 2, frame)
            let result = DisplayCursorCrossingGeometry.destination(location: location, delta: delta, displays: [source, target])
            XCTAssertEqual(result, .init(source: source, target: target, point: expected))
        }
    }

    func testAnyNeighborCoveringCurrentSpanLeavesNativeCrossingAlone() {
        let top = screen("top", 2, CGRect(x: 100, y: 0, width: 100, height: 60))
        let bottom = screen("bottom", 3, CGRect(x: 100, y: 60, width: 100, height: 40))
        XCTAssertNil(destination(CGPoint(x: 99, y: 59.75), CGVector(dx: 2, dy: 0), [source, bottom, top]))
        XCTAssertNil(destination(CGPoint(x: 99, y: 60), CGVector(dx: 2, dy: 0), [source, top, bottom]))
    }

    func testWideScreenAboveNarrowScreenUsesNearestInsideCornerOnlyOnUncoveredSpan() {
        let below = screen("below", 2, CGRect(x: 30, y: 100, width: 40, height: 100))
        XCTAssertEqual(destination(CGPoint(x: 90, y: 99), CGVector(dx: 0, dy: 4), [source, below])?.point,
                       CGPoint(x: 68, y: 102))
        XCTAssertNil(destination(CGPoint(x: 50, y: 99), CGVector(dx: 0, dy: 4), [source, below]))
        XCTAssertTrue(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source, below]))
    }

    func testDominantAxisPreventsAlongEdgeJumpAndHorizontalWinsExactCornerTie() {
        let right = screen("right", 2, CGRect(x: 100, y: 20, width: 100, height: 60))
        let below = screen("below", 3, CGRect(x: 20, y: 100, width: 60, height: 100))
        XCTAssertNil(destination(CGPoint(x: 99, y: 10), CGVector(dx: 1, dy: 4), [source, right]))
        XCTAssertEqual(destination(CGPoint(x: 99, y: 99), CGVector(dx: 4, dy: 4), [source, below, right])?.target, right)
        XCTAssertEqual(destination(CGPoint(x: 99, y: 99), CGVector(dx: 4, dy: 5), [source, below, right])?.target, below)
    }

    func testNoOutwardIntentOrCursorAwayFromEdgeDoesNotJump() {
        let right = screen("right", 2, CGRect(x: 100, y: 20, width: 100, height: 60))
        for delta in [CGVector.zero, CGVector(dx: -5, dy: 0), CGVector(dx: 0, dy: 5)] {
            XCTAssertNil(destination(CGPoint(x: 99, y: 10), delta, [source, right]))
        }
        XCTAssertNil(destination(CGPoint(x: 98, y: 10), CGVector(dx: 10, dy: 0), [source, right]))
        XCTAssertNotNil(destination(CGPoint(x: 98.75, y: 10), CGVector(dx: 1, dy: 0), [source, right]))
    }

    func testNearestProjectionWinsAndUUIDBreaksEqualDistanceIndependentOfInputOrder() {
        let a = screen("a", 2, CGRect(x: 100, y: 0, width: 100, height: 20))
        let z = screen("z", 3, CGRect(x: 100, y: 80, width: 100, height: 20))
        let delta = CGVector(dx: 3, dy: 0)
        XCTAssertEqual(destination(CGPoint(x: 99, y: 50), delta, [source, z, a])?.target, a)
        XCTAssertEqual(destination(CGPoint(x: 99, y: 70), delta, [source, a, z])?.target, z)
    }

    func testUnionOfThreeScreenNativeCoverageDoesNotRequireMonitoring() {
        let a = screen("a", 2, CGRect(x: 100, y: 0, width: 100, height: 40))
        let b = screen("b", 3, CGRect(x: 100, y: 40, width: 100, height: 60))
        XCTAssertFalse(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source, a, b]))
        let gap = screen("b", 3, CGRect(x: 100, y: 50, width: 100, height: 50))
        XCTAssertTrue(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source, a, gap]))
    }

    func testAlignedDisplaysAndIsolatedDisplayHaveNoUnalignedRoutes() {
        let aligned = screen("aligned", 2, CGRect(x: 100, y: 0, width: 100, height: 100))
        XCTAssertFalse(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source]))
        XCTAssertFalse(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source, aligned]))
    }

    func testGapsDiagonalContactAndRemoteDisplaysAreNeverDestinations() {
        for frame in [CGRect(x: 100.6, y: 20, width: 100, height: 60),
                      CGRect(x: 100, y: 100, width: 100, height: 100),
                      CGRect(x: 1000, y: 20, width: 100, height: 60)] {
            let target = screen("target", 2, frame)
            XCTAssertNil(destination(CGPoint(x: 99, y: 10), CGVector(dx: 3, dy: 0), [source, target]))
            XCTAssertFalse(DisplayCursorCrossingGeometry.hasUnalignedEdges(in: [source, target]))
        }
    }

    func testHalfPointFacingPlaneToleranceAndFractionalNegativeCoordinates() {
        let left = screen("left", 1, CGRect(x: -200.25, y: -50.5, width: 100, height: 100))
        let right = screen("right", 2, CGRect(x: -99.75, y: -20.25, width: 100, height: 50))
        let result = destination(CGPoint(x: -101.25, y: -40), CGVector(dx: 3, dy: 0), [right, left])
        XCTAssertEqual(result?.source, left)
        XCTAssertEqual(result?.point, CGPoint(x: -97.75, y: -18.25))
    }

    func testSourceMembershipIsMaxExclusiveAndCannotSelectASeamOrOutsidePointByGuessing() {
        let right = screen("right", 2, CGRect(x: 100, y: 20, width: 100, height: 60))
        XCTAssertNil(destination(CGPoint(x: 100, y: 10), CGVector(dx: 3, dy: 0), [source, right]))
        XCTAssertNil(destination(CGPoint(x: 99, y: 100), CGVector(dx: 3, dy: 0), [source, right]))
        XCTAssertNil(destination(CGPoint(x: -1, y: 10), CGVector(dx: 3, dy: 0), [source, right]))
    }

    func testInvalidOverlappingAndDuplicateScreensAreExcludedFailClosed() {
        let right = screen("right", 2, CGRect(x: 100, y: 20, width: 100, height: 60))
        let invalidFrames = [CGRect.zero, CGRect(x: 100, y: 20, width: 7, height: 60),
                             CGRect(x: CGFloat.nan, y: 20, width: 100, height: 60),
                             CGRect(x: 100, y: 20, width: CGFloat.infinity, height: 60)]
        for frame in invalidFrames {
            XCTAssertNil(destination(CGPoint(x: 99, y: 10), CGVector(dx: 3, dy: 0), [source, screen("right", 2, frame)]))
        }
        for ambiguous in [screen("right", 3, CGRect(x: 300, y: 0, width: 100, height: 100)),
                          screen("other", 2, CGRect(x: 300, y: 0, width: 100, height: 100)),
                          screen("overlap", 3, CGRect(x: 150, y: 30, width: 100, height: 100))] {
            XCTAssertNil(destination(CGPoint(x: 99, y: 10), CGVector(dx: 3, dy: 0), [source, right, ambiguous]))
        }
    }

    func testNonfiniteInputAndEmptyTopologyNeverProduceWarp() {
        XCTAssertNil(destination(CGPoint(x: CGFloat.nan, y: 0), CGVector(dx: 1, dy: 0), [source]))
        XCTAssertNil(destination(CGPoint(x: 99, y: 0), CGVector(dx: CGFloat.infinity, dy: 0), [source]))
        XCTAssertNil(destination(CGPoint(x: 99, y: 0), CGVector(dx: 1, dy: 0), []))
    }

    private func screen(_ uuid: String, _ id: UInt32, _ frame: CGRect) -> DisplayCursorCrossingScreen {
        .init(uuid: uuid, displayID: id, frame: frame)
    }
    private func destination(_ location: CGPoint, _ delta: CGVector, _ displays: [DisplayCursorCrossingScreen]) -> DisplayCursorCrossingDestination? {
        DisplayCursorCrossingGeometry.destination(location: location, delta: delta, displays: displays)
    }
}
