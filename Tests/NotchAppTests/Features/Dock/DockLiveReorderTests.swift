import XCTest
@testable import NotchApp

final class DockLiveReorderTests: XCTestCase {
    private let order = ["a", "b", "c", "d"]

    func testGapJumpsForwardOnlyAfterCrossingMostOfTheTarget() {
        XCTAssertNil(DockLiveReorder.reordered(order, dragged: "a", target: "b", offset: 20, length: 64))
        XCTAssertEqual(DockLiveReorder.reordered(order, dragged: "a", target: "b", offset: 45, length: 64),
                       ["b", "a", "c", "d"])
        XCTAssertEqual(DockLiveReorder.reordered(order, dragged: "a", target: "d", offset: 50, length: 64),
                       ["b", "c", "d", "a"])
    }

    func testGapJumpsBackwardWithHysteresis() {
        XCTAssertNil(DockLiveReorder.reordered(order, dragged: "d", target: "c", offset: 40, length: 64),
                     "Entering from the trailing side must cross past the middle")
        XCTAssertEqual(DockLiveReorder.reordered(order, dragged: "d", target: "c", offset: 20, length: 64),
                       ["a", "b", "d", "c"])
        XCTAssertEqual(DockLiveReorder.reordered(order, dragged: "c", target: "a", offset: 5, length: 64),
                       ["c", "a", "b", "d"])
    }

    func testReorderingIsStableOnceTheGapIsUnderThePointer() {
        let moved = DockLiveReorder.reordered(order, dragged: "a", target: "b", offset: 45, length: 64)!
        XCTAssertNil(DockLiveReorder.reordered(moved, dragged: "a", target: "a", offset: 45, length: 64))
        XCTAssertNil(DockLiveReorder.reordered(moved, dragged: "zz", target: "b", offset: 45, length: 64))
    }

    func testCommitPlacesBeforeSuccessorOrAtEnd() {
        XCTAssertEqual(DockLiveReorder.successor(of: "b", in: ["a", "b", "c"]), "c")
        XCTAssertNil(DockLiveReorder.successor(of: "c", in: ["a", "b", "c"]))
    }

    func testEdgeZonesIncludeAnOpenGap() {
        XCTAssertTrue(DockLiveReorder.insertsAtEdge(offset: -30, length: 64))
        XCTAssertTrue(DockLiveReorder.insertsAtEdge(offset: 90, length: 64))
        XCTAssertFalse(DockLiveReorder.insertsAtEdge(offset: 32, length: 64))
    }
}
