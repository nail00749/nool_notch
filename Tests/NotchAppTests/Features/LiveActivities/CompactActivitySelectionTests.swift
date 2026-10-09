import Foundation
import XCTest
@testable import NotchApp

final class CompactActivitySelectionTests: XCTestCase {
    func testPagesKeepStablePriorityOrderAndFilterUnavailableActivities() {
        let now = Date(timeIntervalSince1970: 1_000)
        let pages = CompactActivitySelection.pages(
            hasMeeting: true,
            hasTimer: true,
            activities: [
                activity("z-download", kind: .download, updatedAt: now),
                activity("a-call", kind: .call, updatedAt: now.addingTimeInterval(-10)),
                activity("b-call", kind: .call, updatedAt: now.addingTimeInterval(10)),
                activity("native-timer", kind: .timer, sourceID: "nool-timers", updatedAt: now),
                activity("finished", kind: .delivery, state: .completed, updatedAt: now),
                activity("notice", kind: .delivery, state: .notification, updatedAt: now),
                activity("hidden-battery", kind: .battery, eligible: false, updatedAt: now)
            ],
            hasMusic: true,
            nativeTimerSourceID: "nool-timers"
        )

        XCTAssertEqual(pages, [
            .meeting,
            .timer,
            .live("a-call"),
            .live("b-call"),
            .live("z-download"),
            .music
        ])
    }

    func testSelectionFallsBackWhenSelectedPageDisappears() {
        let pages: [CompactActivityPage] = [.meeting, .live("call"), .music]

        XCTAssertEqual(CompactActivitySelection.selectedID("live:gone", from: pages), "meeting")
        XCTAssertEqual(CompactActivitySelection.selectedID("music", from: pages), "music")
        XCTAssertNil(CompactActivitySelection.selectedID("live:gone", from: []))
    }

    func testCycleWrapsInBothDirectionsAndDoesNothingForSinglePage() {
        let pages: [CompactActivityPage] = [.meeting, .timer, .music]

        XCTAssertEqual(CompactActivitySelection.cycledID(from: "music", pages: pages, forward: true), "meeting")
        XCTAssertEqual(CompactActivitySelection.cycledID(from: "meeting", pages: pages, forward: false), "music")
        XCTAssertEqual(CompactActivitySelection.cycledID(from: "timer", pages: [.timer], forward: true), "timer")
    }

    private func activity(
        _ id: String,
        kind: LiveActivityKind,
        sourceID: String = "test",
        state: LiveActivityState = .active,
        eligible: Bool = true,
        updatedAt: Date
    ) -> LiveActivity {
        LiveActivity(
            id: id,
            sourceID: sourceID,
            kind: kind,
            title: id,
            detail: nil,
            state: state,
            progress: nil,
            startedAt: nil,
            endsAt: nil,
            updatedAt: updatedAt,
            isCompactEligible: eligible
        )
    }
}
