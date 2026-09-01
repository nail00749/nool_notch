import XCTest
@testable import NotchApp

final class CodexQuotaProviderTests: XCTestCase {
    func testUnavailableMessageInterpolatesError() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "test failure" }
        }

        XCTAssertEqual(
            CodexQuotaProvider.unavailableMessage(for: StubError()),
            "Codex app-server: test failure"
        )
    }
}
