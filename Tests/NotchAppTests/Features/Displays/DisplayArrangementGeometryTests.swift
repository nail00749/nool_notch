import XCTest
@testable import NotchApp

final class DisplayArrangementGeometryTests: XCTestCase {
    func testMagnetAttractsNearbyCenterAndEdgeButDoesNotPullDistantAlignment() {
        let frames = ["main": CGRect(x: 0, y: 0, width: 200, height: 200),
                      "other": CGRect(x: 200, y: 0, width: 100, height: 80)]
        XCTAssertEqual(DisplayArrangementGeometry.magnetizedOrigin("other", proposedOrigin: CGPoint(x: 205, y: 63),
            frames: frames, tolerance: 8), CGPoint(x: 200, y: 60))
        XCTAssertEqual(DisplayArrangementGeometry.magnetizedOrigin("other", proposedOrigin: CGPoint(x: 205, y: 78),
            frames: frames, tolerance: 8), CGPoint(x: 200, y: 78))
        let distant = CGPoint(x: 800, y: 63)
        XCTAssertEqual(DisplayArrangementGeometry.magnetizedOrigin("other", proposedOrigin: distant,
            frames: frames, tolerance: 8), distant)
    }

    func testVisualCenterMagnetMapsToDesktopCenterDespiteDifferentPanelAspect() throws {
        let main = DisplayInfo(id: "main", displayID: 1, name: "Main", isBuiltin: true, isMain: true,
            mirrorMasterID: nil, modes: [], currentMode: nil, frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let other = DisplayInfo(id: "other", displayID: 2, name: "Wide", isBuiltin: false, isMain: false,
            mirrorMasterID: nil, modes: [], currentMode: nil, frame: CGRect(x: 200, y: 20, width: 100, height: 160),
            physicalSize: CGSize(width: 100, height: 40))
        let frames = [main.id: main.frame, other.id: other.frame]
        let outlines = DisplayArrangementGeometry.previewFrames(frames, displays: [main, other], mainID: main.id)
        XCTAssertEqual(try XCTUnwrap(outlines[other.id]).midY, try XCTUnwrap(outlines[main.id]).midY)
        let preview = DisplayArrangementGeometry.magnetizedOrigin(other.id, proposedOrigin: CGPoint(x: 204, y: 83),
            frames: outlines, tolerance: 8)
        let desktop = try XCTUnwrap(DisplayArrangementGeometry.desktopOrigin(other.id, previewOrigin: preview,
            frames: frames, outlines: outlines))
        let result = DisplayArrangementGeometry.snapped(other.id, proposedOrigin: desktop, frames: frames, mainID: main.id)
        XCTAssertEqual(try XCTUnwrap(result[other.id]).midY, try XCTUnwrap(result[main.id]).midY)
        XCTAssertTrue(DisplayArrangementGeometry.isValid(result))
    }

    func testPhysicalUltrawideAspectIsPreservedDespiteSixteenNineDesktopMode() throws {
        let external = DisplayInfo(id: "external", displayID: 2, name: "Odyssey", isBuiltin: false,
            isMain: false, mirrorMasterID: nil, modes: [], currentMode: nil,
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), physicalSize: CGSize(width: 1182, height: 339))
        let builtin = DisplayInfo(id: "main", displayID: 1, name: "Built-in", isBuiltin: true,
            isMain: true, mirrorMasterID: nil, modes: [], currentMode: nil,
            frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
        let draft = [external.id: external.frame, builtin.id: builtin.frame]
        let preview = DisplayArrangementGeometry.previewFrames(draft, displays: [external, builtin], mainID: builtin.id)
        let outlined = try XCTUnwrap(preview[external.id])
        XCTAssertEqual(outlined.width / outlined.height, 1182.0 / 339.0, accuracy: 0.001)
        XCTAssertEqual(outlined.maxX, try XCTUnwrap(preview[builtin.id]).minX)
        XCTAssertEqual(draft[external.id]?.height, 1440, "Preview must not alter submitted desktop coordinates")
    }

    func testDragSnapsFlushAndKeepsMainAtZero() {
        let frames = ["main": CGRect(x: 0, y: 0, width: 100, height: 100),
                      "second": CGRect(x: 100, y: 0, width: 100, height: 80)]
        let result = DisplayArrangementGeometry.snapped("second", proposedOrigin: CGPoint(x: -120, y: 20),
                                                        frames: frames, mainID: "main")
        XCTAssertEqual(result["second"]?.origin, CGPoint(x: -100, y: 20))
        XCTAssertEqual(result["main"]?.origin, .zero)
        XCTAssertTrue(DisplayArrangementGeometry.isValid(result))
    }

    func testMovingMainTranslatesEveryScreenWithoutChangingRelativePlacement() {
        let frames = ["main": CGRect(x: 0, y: 0, width: 100, height: 100),
                      "second": CGRect(x: 100, y: 0, width: 120, height: 80)]
        let result = DisplayArrangementGeometry.place("main", beside: "second", direction: .below,
                                                      frames: frames, mainID: "main")
        XCTAssertEqual(result["main"]?.origin, .zero)
        XCTAssertEqual(result["second"]?.origin, CGPoint(x: 0, y: -80))
        XCTAssertTrue(DisplayArrangementGeometry.isValid(result))
    }

    func testKeyboardPlacementCannotOverlapAnotherScreenOrBreakConnection() {
        let frames = ["main": CGRect(x: 0, y: 0, width: 100, height: 100),
                      "middle": CGRect(x: 100, y: 0, width: 100, height: 100),
                      "right": CGRect(x: 200, y: 0, width: 100, height: 100)]
        XCTAssertEqual(DisplayArrangementGeometry.place("right", beside: "main", direction: .right,
                                                        frames: frames, mainID: "main"), frames)
        XCTAssertEqual(DisplayArrangementGeometry.place("middle", beside: "main", direction: .above,
                                                        frames: frames, mainID: "main"), frames)
    }

    func testCornerContactGapAndOverlapAreRejected() {
        let main = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(DisplayArrangementGeometry.isValid(["main": main,
                                                           "second": CGRect(x: 100, y: 100, width: 100, height: 100)]))
        XCTAssertFalse(DisplayArrangementGeometry.isValid(["main": main,
                                                           "second": CGRect(x: 101, y: 0, width: 100, height: 100)]))
        XCTAssertFalse(DisplayArrangementGeometry.isValid(["main": main,
                                                           "second": CGRect(x: 99, y: 0, width: 100, height: 100)]))
        XCTAssertTrue(DisplayArrangementGeometry.isValid(["main": main,
                                                          "second": CGRect(x: 100, y: 20, width: 100, height: 100)]))
    }

    func testInvalidGeometryCannotProduceAnApplicableDraft() {
        XCTAssertFalse(DisplayArrangementGeometry.isValid([:]))
        XCTAssertFalse(DisplayArrangementGeometry.isValid(["zero": .zero]))
        XCTAssertFalse(DisplayArrangementGeometry.isValid(["infinite": CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)]))
    }
}
