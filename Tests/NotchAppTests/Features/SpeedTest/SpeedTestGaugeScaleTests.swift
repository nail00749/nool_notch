import XCTest
@testable import NotchApp

final class SpeedTestGaugeScaleTests: XCTestCase {
    func testNeedleAgreesWithPrintedMarksAndClampsInvalidValues() {
        for (index, value) in SpeedTestGaugeScale.marks.enumerated() {
            XCTAssertEqual(SpeedTestGaugeScale.fraction(value), Double(index) / 4, accuracy: 0.0001)
        }
        for value: Double? in [nil, -.infinity, .infinity, .nan, -1] {
            XCTAssertEqual(SpeedTestGaugeScale.fraction(value), 0)
        }
        XCTAssertEqual(SpeedTestGaugeScale.fraction(20_000), 1)
        XCTAssertEqual(SpeedTestGaugeScale.fraction(550), 0.625, accuracy: 0.0001)
    }
}
