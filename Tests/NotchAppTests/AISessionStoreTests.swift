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
        store.stop()
    }

    private func session(
        _ id: String,
        sourceID: String = "source",
        status: AISessionStatus,
        date: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> AISession {
        AISession(
            id: AISessionID(sourceID: sourceID, sessionID: id),
            agentName: "Agent",
            title: id,
            workspacePath: "/tmp/\(id)",
            modelName: nil,
            status: status,
            lastActivity: date,
            isStale: false
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

    func send(_ sessions: [AISession]) {
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: sessions,
            health: .live,
            updatedAt: .now
        ))
    }
}
