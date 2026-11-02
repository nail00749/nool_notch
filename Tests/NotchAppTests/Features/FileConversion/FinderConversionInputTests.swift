import AppKit
import XCTest
@testable import NotchApp

final class FinderConversionInputTests: XCTestCase {
    func testStableHoldOpensOnceAndReleaseArmsNextHold() {
        var state = FinderConversionHoldState()
        XCTAssertFalse(sample(&state, 0))
        XCTAssertFalse(sample(&state, 0.44))
        XCTAssertTrue(sample(&state, 0.46))
        XCTAssertFalse(sample(&state, 1.2))
        XCTAssertFalse(sample(&state, 1.3, held: false))
        XCTAssertFalse(sample(&state, 1.4))
        XCTAssertTrue(sample(&state, 1.9))
    }

    func testMovingPointerRestartsDwell() {
        var state = FinderConversionHoldState()
        XCTAssertFalse(sample(&state, 0))
        XCTAssertFalse(sample(&state, 0.4, pointer: CGPoint(x: 10, y: 0)))
        XCTAssertFalse(sample(&state, 0.6, pointer: CGPoint(x: 10, y: 0)))
        XCTAssertTrue(sample(&state, 0.86, pointer: CGPoint(x: 10, y: 0)))
    }

    func testCommandClickAndOtherModifiersConsumeWholeHold() {
        for interruption in 0..<3 {
            var state = FinderConversionHoldState()
            XCTAssertFalse(sample(&state, 0))
            XCTAssertFalse(state.update(time: 0.2, pointer: .zero, isFinder: interruption != 0,
                                       modifierHeld: true, hasOtherModifier: interruption == 1,
                                       mouseDown: interruption == 2))
            XCTAssertFalse(sample(&state, 1))
            XCTAssertFalse(sample(&state, 1.1, held: false))
            XCTAssertFalse(sample(&state, 1.2))
            XCTAssertTrue(sample(&state, 1.7))
        }
    }

    func testShortcutConsumesHoldWithoutLaterOpening() {
        var state = FinderConversionHoldState()
        XCTAssertFalse(sample(&state, 0))
        state.consume()
        XCTAssertFalse(sample(&state, 3))
        state.reset()
        XCTAssertFalse(sample(&state, 4))
        XCTAssertTrue(sample(&state, 4.5))
    }

    func testFileURLNormalizationRejectsRemoteAndPathStrings() {
        XCTAssertEqual(FinderConversionSelectionMatching.fileURL("file:///tmp/a%20b.heic")?.path, "/tmp/a b.heic")
        XCTAssertEqual(FinderConversionSelectionMatching.fileURL(URL(fileURLWithPath: "/tmp/a/../b.png"))?.path, "/tmp/b.png")
        XCTAssertNil(FinderConversionSelectionMatching.fileURL("https://example.com/a.heic"))
        XCTAssertNil(FinderConversionSelectionMatching.fileURL("/tmp/a.heic"))
        XCTAssertNil(FinderConversionSelectionMatching.fileURL("file://remote.example.com/a.heic"))
    }

    func testSelectionIsAtomicBoundedAndDeduplicated() {
        let local = URL(fileURLWithPath: "/tmp/a.heic")
        XCTAssertEqual(FinderConversionSelectionMatching.validated(urls: [local, local]), [local])
        XCTAssertNil(FinderConversionSelectionMatching.validated(urls: []))
        XCTAssertNil(FinderConversionSelectionMatching.validated(urls: Array(repeating: local, count: 65)))
        XCTAssertNil(FinderConversionSelectionMatching.validated(urls: [local, URL(string: "https://example.com/a")!]))
    }

    private func sample(_ state: inout FinderConversionHoldState, _ time: TimeInterval,
                        pointer: CGPoint = .zero, held: Bool = true) -> Bool {
        state.update(time: time, pointer: pointer, isFinder: true, modifierHeld: held,
                     hasOtherModifier: false, mouseDown: false)
    }
}
