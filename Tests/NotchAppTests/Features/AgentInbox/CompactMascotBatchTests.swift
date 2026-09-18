import Foundation
import XCTest
@testable import NotchApp

final class CompactMascotBatchTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testBurstKeepsOnePresentationAndOriginalDeadline() throws {
        var batch = CompactMascotBatch()
        let first = notice("one", at: start)
        batch.update([first], at: start)
        let original = try XCTUnwrap(batch.presentation)
        let second = notice("two", at: start.addingTimeInterval(5))
        batch.update([first, second], at: start.addingTimeInterval(5))
        XCTAssertEqual(batch.presentation?.id, original.id)
        XCTAssertEqual(batch.presentation?.expiresAt, start.addingTimeInterval(12))
        batch.update([first, second], at: start.addingTimeInterval(12))
        XCTAssertNil(batch.presentation)
        batch.update([first, second], at: start.addingTimeInterval(15))
        XCTAssertNil(batch.presentation, "Already grouped events must not replay")
        let third = notice("three", at: start.addingTimeInterval(16))
        batch.update([first, second, third], at: start.addingTimeInterval(16))
        XCTAssertNotNil(batch.presentation)
        XCTAssertNotEqual(batch.presentation?.id, original.id)
    }

    func testApprovalTakesPriorityWithoutRestartingPresentation() throws {
        var batch = CompactMascotBatch()
        let live = notice("live", at: start)
        batch.update([live], at: start)
        let original = try XCTUnwrap(batch.presentation)
        let approval = CompactMascotNotice.agent(CompactAgentSignal(
            sessionID: AISessionID(sourceID: "test", sessionID: "approval"),
            kind: .waitingForApproval, observedAt: start.addingTimeInterval(2)
        ))
        batch.update([live, approval], at: start.addingTimeInterval(2))
        XCTAssertEqual(batch.presentation?.notice, approval)
        XCTAssertEqual(batch.presentation?.id, original.id)
        batch.update([live], at: start.addingTimeInterval(3))
        XCTAssertEqual(batch.presentation?.notice, live, "Resolved requests must not remain actionable")
    }

    func testPreviouslyGroupedEventDoesNotReplayAfterBriefSourceGap() throws {
        var batch = CompactMascotBatch()
        let event = notice("one", at: start)
        batch.update([event], at: start)
        XCTAssertNotNil(batch.presentation)
        batch.update([], at: start.addingTimeInterval(12))
        batch.update([event], at: start.addingTimeInterval(13))
        XCTAssertNil(batch.presentation)
    }

    private func notice(_ id: String, at date: Date) -> CompactMascotNotice {
        .live(LiveActivity(
            id: id, sourceID: "test", kind: .download, title: id, detail: nil,
            state: .notification, progress: nil, startedAt: nil, endsAt: nil,
            updatedAt: date, isCompactEligible: true
        ))
    }
}
