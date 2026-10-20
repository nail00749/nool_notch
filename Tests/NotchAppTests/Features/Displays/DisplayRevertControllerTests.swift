import XCTest
@testable import NotchApp

@MainActor
final class DisplayRevertControllerTests: XCTestCase {
    func testTimeoutRevertsOnceAndDismissesConfirmation() async {
        let reverted = expectation(description: "Trial expires")
        reverted.assertForOverFulfill = true
        let controller = DisplayRevertController(showsWindow: false, timeout: .milliseconds(30))
        controller.present(displayID: 1, confirm: { XCTFail("Expired trial must not be confirmed") },
                           revert: { reverted.fulfill() })
        await fulfillment(of: [reverted], timeout: 2)
        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.secondsRemaining, 0)
        controller.revert()
    }

    func testConfirmationCancelsTimeout() async throws {
        let controller = DisplayRevertController(showsWindow: false, timeout: .milliseconds(30))
        var confirmations = 0
        var reverts = 0
        controller.present(displayID: 1, confirm: { confirmations += 1 }, revert: { reverts += 1 })
        controller.confirm()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(reverts, 0)
        XCTAssertFalse(controller.isPresented)
    }
}
