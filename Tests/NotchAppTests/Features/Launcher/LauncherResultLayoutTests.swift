import XCTest
@testable import NotchApp

final class LauncherResultLayoutTests: XCTestCase {
    func testMixedResultsKeepRankingAndNonApplicationsSpanRows() {
        let apps = (0..<7).map(application)
        let command = LauncherResult(id: "command", title: "Result", subtitle: "", payload: .calculation("42"))
        let results = [command] + apps + [command] + [application(8)]
        let rows = LauncherResultLayout.rows(results)
        XCTAssertEqual(rows.map(\.count), [1, 5, 2, 1, 1])
        XCTAssertEqual(rows.flatMap { $0 }, results)
    }

    func testVerticalMovementUsesVisualRowsAndClampsShortFinalRow() {
        let apps = (0..<12).map(application)
        XCTAssertEqual(LauncherResultLayout.verticalSelection(current: "4", offset: 1, results: apps), "9")
        XCTAssertEqual(LauncherResultLayout.verticalSelection(current: "9", offset: 1, results: apps), "11")
        XCTAssertEqual(LauncherResultLayout.verticalSelection(current: "11", offset: 1, results: apps), "11")
        XCTAssertEqual(LauncherResultLayout.verticalSelection(current: "1", offset: -1, results: apps), "1")
        XCTAssertEqual(LauncherResultLayout.verticalSelection(current: "11", offset: -1, results: apps), "6")
        XCTAssertNil(LauncherResultLayout.verticalSelection(current: nil, offset: 1, results: []))
    }

    func testHorizontalMovementStaysInRow() {
        let apps = (0..<7).map(application)
        XCTAssertEqual(LauncherResultLayout.horizontalSelection(current: "3", offset: 1, results: apps), "4")
        XCTAssertEqual(LauncherResultLayout.horizontalSelection(current: "4", offset: 1, results: apps), "4")
        XCTAssertEqual(LauncherResultLayout.horizontalSelection(current: "5", offset: -1, results: apps), "5")
        XCTAssertEqual(LauncherResultLayout.horizontalSelection(current: "6", offset: -1, results: apps), "5")
    }

    private func application(_ index: Int) -> LauncherResult {
        LauncherResult(id: "\(index)", title: "App \(index)", subtitle: "",
                       payload: .application(URL(fileURLWithPath: "/Applications/App\(index).app")))
    }
}
