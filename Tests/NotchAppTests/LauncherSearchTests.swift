import Foundation
import XCTest
@testable import NotchApp

final class LauncherSearchTests: XCTestCase {
    func testExactAndPrefixTitleMatchesRankBeforeSparseAndSubtitleMatches() {
        let exact = result(id: "exact", title: "Safari")
        let prefix = result(id: "prefix", title: "Safari Technology Preview")
        let sparse = result(id: "sparse", title: "System Application Framework Interface")
        let subtitle = result(id: "subtitle", title: "Browser", subtitle: "Safari profile")

        XCTAssertEqual(
            LauncherSearch.ranked([subtitle, sparse, prefix, exact], query: "safari").map(\.id),
            ["exact", "prefix", "sparse", "subtitle"]
        )
    }

    func testFuzzySearchRequiresEveryQueryToken() {
        let matching = result(id: "matching", title: "Visual Studio Code")
        let wrong = result(id: "wrong", title: "Visual Studio")

        XCTAssertEqual(LauncherSearch.ranked([wrong, matching], query: "vs code").map(\.id), ["matching"])
    }

    func testRankingDeduplicatesIDsAfterFilteringAndSortsEmptyQuery() {
        let stale = result(id: "same", title: "Old")
        let fresh = result(id: "same", title: "Launcher")
        let alpha = result(id: "alpha", title: "Alpha")

        XCTAssertEqual(LauncherSearch.ranked([stale, fresh, alpha], query: "launcher").map(\.id), ["same"])
        XCTAssertEqual(LauncherSearch.ranked([fresh, alpha], query: "  ").map(\.id), ["alpha", "same"])
    }

    private func result(id: String, title: String, subtitle: String = "") -> LauncherResult {
        LauncherResult(id: id, title: title, subtitle: subtitle, payload: .calculation(title))
    }
}
