import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class AISessionStoreTests: XCTestCase {
    func testPresentationKeepsAllActiveAndOnlyTenInactive() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let active = [
            session("approval", status: .waitingForApproval, date: now),
            session("input", status: .waitingForInput, date: now.addingTimeInterval(-1)),
            session("running", status: .running, date: now.addingTimeInterval(-2))
        ]
        let inactive = (0..<14).map { index in
            session(
                "inactive-\(index)",
                status: .completed,
                date: now.addingTimeInterval(TimeInterval(-10 - index))
            )
        }

        let presented = AISessionStore.presentationSessions(active + inactive)

        XCTAssertEqual(presented.count, 13)
        XCTAssertEqual(presented.prefix(3).map(\.id.sessionID), ["approval", "input", "running"])
        XCTAssertEqual(presented.filter { $0.status.isActive == false }.count, 10)
    }

    func testStoreReplacesOnlyEmittingSourceAndRoutesOpen() async {
        let first = FakeAISessionSource(id: "first")
        let second = FakeAISessionSource(id: "second")
        let store = AISessionStore(sources: [first, second])
        store.start()

        first.send([session("same", sourceID: first.id, status: .running)])
        second.send([session("same", sourceID: second.id, status: .waitingForInput)])
        await settle()

        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.attentionCount, 1)

        first.send([session("replacement", sourceID: first.id, status: .completed)])
        await settle()

        XCTAssertEqual(Set(store.sessions.map(\.id)), [
            AISessionID(sourceID: first.id, sessionID: "replacement"),
            AISessionID(sourceID: second.id, sessionID: "same")
        ])

        let opened = await store.open(store.sessions.first { $0.id.sourceID == second.id }!)
        XCTAssertTrue(opened)
        XCTAssertEqual(second.openedSessionIDs, ["same"])

        let responded = await store.respond(
            to: store.sessions.first { $0.id.sourceID == second.id }!,
            requestID: "request-1",
            response: .approveOnce
        )
        XCTAssertTrue(responded)
        XCTAssertEqual(second.responses.count, 1)
        store.stop()
    }

    func testActivityTrackerCountsOnlyRunningIntervals() {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        var tracker = AISessionActivityTracker()
        let health = ["source": AISessionSourceHealth.live]

        var result = tracker.update(
            sessions: [session("timed", status: .running)],
            sourceHealth: health,
            at: start
        )
        XCTAssertEqual(result[0].activeDuration(at: start), 0)

        result = tracker.update(
            sessions: [session("timed", status: .waitingForApproval)],
            sourceHealth: health,
            at: start.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(result[0].activeDuration(at: start.addingTimeInterval(15 * 60)), 10 * 60)

        result = tracker.update(
            sessions: [session("timed", status: .running)],
            sourceHealth: health,
            at: start.addingTimeInterval(20 * 60)
        )
        result = tracker.update(
            sessions: [session("timed", status: .completed)],
            sourceHealth: health,
            at: start.addingTimeInterval(25 * 60)
        )

        XCTAssertEqual(result[0].activeDuration(at: start.addingTimeInterval(40 * 60)), 15 * 60)
    }

    func testActivityTrackerPausesWhileSourceIsStale() {
        let start = Date(timeIntervalSinceReferenceDate: 30_000)
        var tracker = AISessionActivityTracker()
        _ = tracker.update(
            sessions: [session("stale", status: .running)],
            sourceHealth: ["source": .live],
            at: start
        )

        var result = tracker.update(
            sessions: [session("stale", status: .running, isStale: true)],
            sourceHealth: ["source": .stale(message: nil)],
            at: start.addingTimeInterval(2 * 60)
        )
        result = tracker.update(
            sessions: [session("stale", status: .running, isStale: true)],
            sourceHealth: ["source": .stale(message: nil)],
            at: start.addingTimeInterval(8 * 60)
        )

        XCTAssertEqual(result[0].activeDuration(at: start.addingTimeInterval(8 * 60)), 2 * 60)
    }

    private func session(
        _ id: String,
        sourceID: String = "source",
        status: AISessionStatus,
        date: Date = Date(timeIntervalSinceReferenceDate: 1_000),
        isStale: Bool = false
    ) -> AISession {
        AISession(
            id: AISessionID(sourceID: sourceID, sessionID: id),
            agentName: "Agent",
            title: id,
            workspacePath: "/tmp/\(id)",
            modelName: nil,
            status: status,
            lastActivity: date,
            isStale: isStale
        )
    }

    private func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }
}

@MainActor
private final class FakeAISessionSource: AISessionSource {
    let id: String
    let displayName: String
    private var continuation: AsyncStream<AISessionSourceSnapshot>.Continuation?
    private(set) var openedSessionIDs: [String] = []
    private(set) var responses: [(String, String, AISessionResponse)] = []

    init(id: String) {
        self.id = id
        self.displayName = id
    }

    func snapshots() -> AsyncStream<AISessionSourceSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func open(sessionID: String) async -> Bool {
        openedSessionIDs.append(sessionID)
        return true
    }

    func respond(
        sessionID: String,
        requestID: String,
        response: AISessionResponse
    ) async -> Bool {
        responses.append((sessionID, requestID, response))
        return true
    }

    func send(_ sessions: [AISession]) {
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: sessions,
            health: .live,
            updatedAt: .now
        ))
    }
}
