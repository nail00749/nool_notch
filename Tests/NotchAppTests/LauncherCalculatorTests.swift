import XCTest
@testable import NotchApp

final class LauncherCalculatorTests: XCTestCase {
    func testEvaluatesPrecedenceParenthesesUnaryAndExponentiation() {
        XCTAssertEqual(LauncherCalculator.evaluate("2 + 3 * 4"), "14")
        XCTAssertEqual(LauncherCalculator.evaluate("(2 + 3) * 4"), "20")
        XCTAssertEqual(LauncherCalculator.evaluate("-2^2 + 2^-1"), "-3.5")
        XCTAssertEqual(LauncherCalculator.evaluate("2 ^ 3 ^ 2"), "512")
    }

    func testRejectsNamesMalformedAndNonFiniteExpressions() {
        XCTAssertNil(LauncherCalculator.evaluate(""))
        XCTAssertNil(LauncherCalculator.evaluate("Open Safari"))
        XCTAssertNil(LauncherCalculator.evaluate("2 +"))
        XCTAssertNil(LauncherCalculator.evaluate("(2 + 3"))
        XCTAssertNil(LauncherCalculator.evaluate("1 / 0"))
        XCTAssertNil(LauncherCalculator.evaluate("10 ^ 10000"))
    }

    func testRejectsExcessiveInputAndNesting() {
        XCTAssertNil(LauncherCalculator.evaluate(String(repeating: "1+", count: 129) + "1"))
        XCTAssertNil(LauncherCalculator.evaluate(String(repeating: "(", count: 33) + "1" + String(repeating: ")", count: 33)))
    }
}
