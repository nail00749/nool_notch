import CoreGraphics
import XCTest
@testable import NotchApp

final class DisplayImageAdjustmentTests: XCTestCase {
    private let baseline = DisplayGammaTable(red: [0, 0.25, 0.8, 1], green: [0, 0.3, 0.75, 0.9], blue: [0, 0.4, 0.7, 0.85])

    func testNeutralPreservesCalibratedChannelsExactly() {
        XCTAssertEqual(baseline.applying(dimming: 1, adjustment: .neutral), baseline)
        XCTAssertEqual(baseline.dimmed(by: 1), baseline)
        XCTAssertTrue(DisplayImageAdjustment.neutral.isNeutral)
    }

    func testAdjustmentSanitizesFiniteBoundsAndNonfiniteValuesToNeutral() {
        let value = DisplayImageAdjustment(gamma: 9, contrast: 0, temperature: -9, red: -1, green: 2, blue: 0.5).sanitized
        XCTAssertEqual(value, DisplayImageAdjustment(gamma: 2, contrast: 0.5, temperature: -1, red: 0, green: 1, blue: 0.5))
        let nonfinite = DisplayImageAdjustment(gamma: .nan, contrast: .infinity, temperature: -.infinity,
                                               red: .nan, green: .infinity, blue: -.infinity)
        XCTAssertEqual(nonfinite.sanitized, .neutral)
        XCTAssertTrue(nonfinite.isNeutral)
    }

    func testAdjustmentCodableRoundTrip() throws {
        let value = DisplayImageAdjustment(gamma: 1.4, contrast: 1.2, temperature: 0.3, red: 0.9, green: 0.8, blue: 0.7)
        XCTAssertEqual(try JSONDecoder().decode(DisplayImageAdjustment.self, from: JSONEncoder().encode(value)), value)
    }

    func testGammaChangesMidtonesAndContrastIsCenteredAtHalf() {
        let table = DisplayGammaTable(red: [0, 0.25, 0.5, 1], green: [], blue: [])
        let gamma = table.applying(dimming: 1, adjustment: .init(gamma: 2))
        XCTAssertEqual(gamma.red[1], 0.5, accuracy: 0.000_001)
        let contrast = table.applying(dimming: 1, adjustment: .init(contrast: 1.5))
        XCTAssertEqual(contrast.red, [0, 0.125, 0.5, 1])
        let reduced = table.applying(dimming: 1, adjustment: .init(contrast: 0.5))
        XCTAssertEqual(reduced.red, [0.25, 0.375, 0.5, 0.75])
    }

    func testTemperatureReducesOppositeChannelsAndCombinesRGBGains() {
        let white = DisplayGammaTable(red: [1], green: [1], blue: [1])
        let warm = white.applying(dimming: 1, adjustment: .init(temperature: 1))
        XCTAssertEqual(warm.red, [1])
        XCTAssertEqual(warm.green[0], 0.85, accuracy: 0.000_001)
        XCTAssertEqual(warm.blue[0], 0.6, accuracy: 0.000_001)
        let cool = white.applying(dimming: 1, adjustment: .init(temperature: -1, red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(cool.red[0], 0.35, accuracy: 0.000_001)
        XCTAssertEqual(cool.green[0], 0.45, accuracy: 0.000_001)
        XCTAssertEqual(cool.blue, [0.5])
    }

    func testDimmingComposesAfterColorCorrectionUsingOriginalCalibration() {
        let adjustment = DisplayImageAdjustment(gamma: 1.3, contrast: 1.2, temperature: 0.4, red: 0.9)
        let undimmed = baseline.applying(dimming: 1, adjustment: adjustment)
        let dimmed = baseline.applying(dimming: 0.5, adjustment: adjustment)
        for (actual, expected) in zip(dimmed.red + dimmed.green + dimmed.blue, undimmed.red + undimmed.green + undimmed.blue) {
            XCTAssertEqual(actual, expected * 0.5, accuracy: 0.000_001)
        }
        XCTAssertEqual(baseline.red, [0, 0.25, 0.8, 1])
    }

    func testRepeatedAdjustmentsDoNotAccumulateOrMutateBaseline() {
        let first = baseline.applying(dimming: 0.4, adjustment: .init(gamma: 1.7, temperature: 1))
        let second = baseline.applying(dimming: 0.8, adjustment: .init(contrast: 1.2, blue: 0.7))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second, baseline.applying(dimming: 0.8, adjustment: .init(contrast: 1.2, blue: 0.7)))
        XCTAssertEqual(baseline.applying(dimming: 1, adjustment: .neutral), baseline)
    }

    func testAdjustedOutputIsFiniteBoundedAndDimmingKeepsSafeFloor() {
        let invalidSamples = DisplayGammaTable(red: [-1, .nan, .infinity, 2], green: [], blue: [])
        let output = invalidSamples.applying(dimming: -1, adjustment: .init(gamma: 9, contrast: 9, red: 9))
        XCTAssertTrue(output.red.allSatisfy { $0.isFinite && (0...0.1).contains($0) })
        XCTAssertEqual(baseline.applying(dimming: .infinity, adjustment: .neutral), baseline)
        XCTAssertEqual(baseline.applying(dimming: -1, adjustment: .neutral), baseline.dimmed(by: 0.1))
    }
}
