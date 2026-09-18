import Foundation
import XCTest
@testable import NotchApp

final class LiveActivityTests: XCTestCase {
    func testActiveTimerWinsCompactSlotOverLowBattery() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let battery = LiveActivity(
            id: "battery",
            sourceID: "system-battery",
            kind: .battery,
            title: "Батарея",
            detail: "12%",
            state: .active,
            progress: 0.12,
            startedAt: nil,
            endsAt: nil,
            updatedAt: now.addingTimeInterval(10),
            isCompactEligible: true
        )
        let timer = LiveActivity(
            id: "timer-focus",
            sourceID: "external-timers",
            kind: .timer,
            title: "Фокус",
            detail: nil,
            state: .active,
            progress: 0.5,
            startedAt: now.addingTimeInterval(-300),
            endsAt: now.addingTimeInterval(300),
            updatedAt: now,
            isCompactEligible: true
        )

        let primary = try XCTUnwrap(
            LiveActivityFeed.primaryCompactActivity(in: [battery, timer])
        )

        XCTAssertEqual(primary.id, "timer-focus")
        XCTAssertEqual(
            try XCTUnwrap(primary.remainingDuration(at: now)),
            300,
            accuracy: 0.001
        )
    }

    func testPanelOnlyBatteryDoesNotReplaceCompactContent() {
        let activity = LiveActivity(
            id: "battery",
            sourceID: "system-battery",
            kind: .battery,
            title: "Батарея",
            detail: "84%",
            state: .active,
            progress: 0.84,
            startedAt: nil,
            endsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            isCompactEligible: false
        )

        XCTAssertNil(LiveActivityFeed.primaryCompactActivity(in: [activity]))
    }

    func testCompletedTimerLeavesCompactSlot() {
        let now = Date(timeIntervalSince1970: 1_000)
        let activity = LiveActivity(
            id: "timer-tea",
            sourceID: "external-timers",
            kind: .timer,
            title: "Чай",
            detail: nil,
            state: .completed,
            progress: 1,
            startedAt: now.addingTimeInterval(-300),
            endsAt: now,
            updatedAt: now,
            isCompactEligible: true
        )

        XCTAssertNil(LiveActivityFeed.primaryCompactActivity(in: [activity]))
        XCTAssertEqual(activity.remainingDuration(at: now.addingTimeInterval(20)), 0)
    }
}
