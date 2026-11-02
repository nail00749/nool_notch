import XCTest
@testable import NotchApp

final class DisplayServiceTests: XCTestCase {
    func testLegacyModeDescriptionWithoutFlagsStillDecodes() throws {
        let json = #"{"id":1,"width":1920,"height":1080,"pixelWidth":3840,"pixelHeight":2160,"refreshRate":60}"#
        let decoded = try JSONDecoder().decode(DisplayModeOption.self, from: Data(json.utf8))
        XCTAssertNil(decoded.ioFlags)
        XCTAssertEqual(decoded, mode(id: 1))
    }

    func testOdysseyFrequencyPrefersDriverDefaultRegardlessOfEnumerationOrder() {
        let current = DisplayModeOption(id: 436, width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 120, ioFlags: 0x2000003)
        let alternate = DisplayModeOption(id: 434, width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 240, ioFlags: 0x2000003)
        let preferred = DisplayModeOption(id: 435, width: 5120, height: 1440, pixelWidth: 5120, pixelHeight: 1440, refreshRate: 240, ioFlags: 0x2000007)
        for modes in [[alternate, preferred, current], [preferred, current, alternate]] {
            XCTAssertEqual(DisplayModeOption.frequencyVariants(modes, current: current).map(\.id), [435, 436])
            XCTAssertEqual(DisplayModeOption.frequencyVariants(modes, current: alternate).map(\.id), [434, 436])
        }
    }

    func testFrequencyDoesNotChangePixelGeometry() {
        let current = mode(id: 1)
        let other = mode(id: 2, pixelWidth: 4096, pixelHeight: 2304, refreshRate: 120)
        XCTAssertEqual(DisplayModeOption.deduplicated([current, other], currentModeID: 1).count, 2)
        XCTAssertEqual(DisplayModeOption.frequencyVariants([current, other], current: current).map(\.id), [1])
    }

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
