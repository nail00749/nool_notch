import NotchCore
import XCTest
@testable import NotchApp

final class ClaudeUsageGateTests: XCTestCase {
    func testThrottlesRequestsAndKeepsLastLimitsWhileRateLimited() async {
        let gate = ClaudeUsageGate()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let isEmpty = await gate.cachedSnapshot(at: start) == nil
        XCTAssertTrue(isEmpty, "The first request goes to the API")

        let live = QuotaSnapshot(
            providerID: "claude-code-subscription", providerName: "Claude Code",
            windows: [QuotaWindow(id: "claude-code-5h", label: "5h", limit: 100, remaining: 60, resetAt: nil, unit: .percentage)],
            connection: .live, updatedAt: start, sourceURL: nil, message: nil)
        await gate.recordSuccess(live, at: start)
        let throttled = await gate.cachedSnapshot(at: start.addingTimeInterval(30))
        XCTAssertEqual(throttled, live, "Requests within a minute reuse the last answer")
        let allowed = await gate.cachedSnapshot(at: start.addingTimeInterval(61)) == nil
        XCTAssertTrue(allowed)

        let limitedAt = start.addingTimeInterval(61)
        let waiting = await gate.recordRateLimit(until: limitedAt.addingTimeInterval(3_600), sourceURL: nil)
        XCTAssertEqual(waiting.connection, .stale)
        XCTAssertEqual(waiting.windows, live.windows, "Limits stay on screen during the back-off")
        let blocked = await gate.cachedSnapshot(at: limitedAt.addingTimeInterval(1_800))
        XCTAssertEqual(blocked?.windows, live.windows)
        let resumed = await gate.cachedSnapshot(at: limitedAt.addingTimeInterval(3_601)) == nil
        XCTAssertTrue(resumed, "Retry-After is honoured, then requests resume")
    }

    func testRateLimitWithoutPreviousLimitsExplainsTheWait() async {
        let gate = ClaudeUsageGate()
        let snapshot = await gate.recordRateLimit(until: Date().addingTimeInterval(600), sourceURL: nil)
        XCTAssertEqual(snapshot.connection, .unavailable)
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertNotNil(snapshot.message)
    }
}
