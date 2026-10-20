import XCTest
@testable import NotchApp

final class DisplayServiceTests: XCTestCase {
    func testModeDeduplicationPreservesCurrentDriverMode() {
        let duplicate = mode(id: 1)
        let current = mode(id: 2)
        let highRefresh = mode(id: 3, refreshRate: 120)
        let lowResolution = mode(id: 4, pixelWidth: 1920, pixelHeight: 1080)

        let result = DisplayModeOption.deduplicated([duplicate, current, highRefresh, lowResolution], currentModeID: 2)

        XCTAssertEqual(result.map(\.id), [3, 2, 4])
        XCTAssertEqual(result.filter(\.isHiDPI).count, 2)
    }

    func testModeDeduplicationKeepsDistinctLogicalSizes() {
        let small = mode(id: 1)
        let large = DisplayModeOption(id: 2, width: 2560, height: 1440,
                                      pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
        XCTAssertEqual(DisplayModeOption.deduplicated([small, large], currentModeID: nil).map(\.id), [2, 1])
    }

    func testGammaDimmingRetainsChannelCalibrationAndDoesNotMutateBaseline() {
        let baseline = DisplayGammaTable(red: [0, 0.4, 1], green: [0, 0.5, 0.9], blue: [0, 0.6, 0.8])

        let first = baseline.dimmed(by: 0.5)
        let next = baseline.dimmed(by: 0.8)

        XCTAssertEqual(first.red, [0, 0.2, 0.5])
        XCTAssertEqual(first.green, [0, 0.25, 0.45])
        XCTAssertEqual(first.blue, [0, 0.3, 0.4])
        XCTAssertEqual(next.red[1], 0.32, accuracy: 0.000_001)
        XCTAssertEqual(next.red[2], 0.8, accuracy: 0.000_001)
        XCTAssertEqual(baseline.red, [0, 0.4, 1])
    }

    func testGammaFactorHasSafeBoundsAndRejectsNonfiniteInput() {
        let baseline = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        XCTAssertEqual(baseline.dimmed(by: -1).red, [0, 0.1])
        XCTAssertEqual(baseline.dimmed(by: 5), baseline)
        XCTAssertEqual(baseline.dimmed(by: .nan), baseline)
        XCTAssertEqual(baseline.dimmed(by: .infinity), baseline)
    }

    private func mode(id: UInt32, pixelWidth: Int = 3840, pixelHeight: Int = 2160,
                      refreshRate: Double = 60) -> DisplayModeOption {
        DisplayModeOption(id: id, width: 1920, height: 1080, pixelWidth: pixelWidth,
                          pixelHeight: pixelHeight, refreshRate: refreshRate)
    }
}
