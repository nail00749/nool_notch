import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class CodeReviewStoreTests: XCTestCase {
    func testDeduplicatesWorkspacesAndKeepsThreeRecentInactiveSessions() {
        let store = CodeReviewStore(provider: DeferredCodeReviewProvider())
        let active = session(id: "active", workspace: "/tmp/active", status: .running)
        let completed = (1...4).map {
            session(id: "completed-\($0)", workspace: "/tmp/completed-\($0)", status: .completed)
        }

        store.updateSessions([active] + completed)

        XCTAssertEqual(store.codeReviewSessions.map(\.id), [active.id] + completed.prefix(3).map(\.id))
    }

    func testReplacementCancelsOldWorkspaceAndIgnoresItsLateResult() async {
        let provider = DeferredCodeReviewProvider()
        let store = CodeReviewStore(provider: provider)
        let original = session(id: "session", workspace: "/tmp/old", status: .running)
        let replacement = session(id: "session", workspace: "/tmp/new", status: .running)

        store.updateSessions([original])
        store.setVisible(true)
        await waitForCalls(provider, count: 1)

        store.updateSessions([replacement])
        await waitForCalls(provider, count: 2)

        await provider.completeNext(.success(snapshot(rootPath: "/tmp/old")))
        await settleTasks()
        XCTAssertNil(store.codeReviewState(for: replacement).snapshot)

        let expected = snapshot(rootPath: "/tmp/new")
        await provider.completeNext(.success(expected))
        await settleTasks()
        XCTAssertEqual(store.codeReviewState(for: replacement).snapshot, expected)
    }

    func testStopIgnoresLateProviderResult() async {
        let provider = DeferredCodeReviewProvider()
        let store = CodeReviewStore(provider: provider)
        let current = session(id: "session", workspace: "/tmp/current", status: .running)

        store.updateSessions([current])
        store.setVisible(true)
        await waitForCalls(provider, count: 1)
        store.stop()

        await provider.completeNext(.success(snapshot(rootPath: "/tmp/current")))
        await settleTasks()

        XCTAssertNil(store.codeReviewState(for: current).snapshot)
        XCTAssertNil(store.codeReviewsUpdatedAt)
    }

    func testCountsNewReviewerActivityAndAcknowledgesIt() async {
        let provider = DeferredCodeReviewProvider()
        let store = CodeReviewStore(provider: provider)
        let current = session(id: "session", workspace: "/tmp/current", status: .running)

        store.updateSessions([current])
        store.setVisible(true)
        await waitForCalls(provider, count: 1)
        await provider.completeNext(.success(snapshot(rootPath: "/tmp/current", activityIDs: ["one"])))
        await settleTasks()

        store.refreshCodeReviews()
        await waitForCalls(provider, count: 2)
        await provider.completeNext(.success(snapshot(rootPath: "/tmp/current", activityIDs: ["one", "two"])))
        await settleTasks()

        XCTAssertEqual(store.newReviewActivityCount(for: current), 1)
        store.acknowledgeReviewActivity(for: current)
        XCTAssertEqual(store.newReviewActivityCount(for: current), 0)
    }

    private func session(
        id: String,
        workspace: String,
        status: AISessionStatus
    ) -> AISession {
        AISession(
            id: AISessionID(sourceID: "test", sessionID: id),
            agentName: "Agent",
            title: "Task",
            workspacePath: workspace,
            modelName: nil,
            status: status,
            lastActivity: Date(timeIntervalSince1970: 1_000),
            isStale: false
        )
    }

    private func snapshot(rootPath: String, activityIDs: Set<String> = []) -> CodeReviewSnapshot {
        let request = CodeReviewRequest(
            provider: .github,
            number: "42",
            title: "Review",
            url: URL(string: "https://github.com/example/project/pull/42")!,
            diffURL: URL(string: "https://github.com/example/project/pull/42/files")!,
            state: "OPEN",
            isDraft: false,
            authorLogin: "author",
            mergeState: .ready,
            ciState: .passed,
            completedChecks: 1,
            totalChecks: 1,
            reviewerActivityIDs: activityIDs,
            updatedAt: nil
        )
        return CodeReviewSnapshot(
            repository: CodeRepositoryContext(
                rootPath: rootPath,
                branch: "main",
                remoteURL: "git@github.com:example/project.git",
                host: "github.com",
                projectPath: "example/project",
                hostKind: .github
            ),
            request: request
        )
    }

    private func waitForCalls(_ provider: DeferredCodeReviewProvider, count: Int) async {
        for _ in 0..<100 {
            if await provider.callCount >= count { return }
            await Task.yield()
        }
        XCTFail("Provider did not receive \(count) requests")
    }

    private func settleTasks() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

private actor DeferredCodeReviewProvider: CodeReviewProviding {
    private var continuations: [CheckedContinuation<Result<CodeReviewSnapshot, CodeReviewError>, Never>] = []
    private(set) var callCount = 0

    func load(workspacePath: String) async -> Result<CodeReviewSnapshot, CodeReviewError> {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeNext(_ result: Result<CodeReviewSnapshot, CodeReviewError>) {
        guard continuations.isEmpty == false else { return }
        continuations.removeFirst().resume(returning: result)
    }
}
