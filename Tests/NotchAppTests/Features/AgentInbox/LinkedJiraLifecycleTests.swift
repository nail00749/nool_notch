import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class LinkedJiraLifecycleTests: XCTestCase {
    func testDisconnectClearsAlreadyLoadedLinkedIssue() async {
        let jira = FakeJiraProvider()
        jira.issueLoader = { _ in .success(.fixture(key: "APP-184")) }
        let (model, source) = makeModel(jira: jira)
        await publishSession(to: source, model: model)
        await waitUntil { model.aiLinkedJiraIssues["APP-184"] != nil }

        model.disconnectJira()

        XCTAssertTrue(model.aiLinkedJiraIssues.isEmpty)
        XCTAssertTrue(model.aiLinkedJiraErrors.isEmpty)
        XCTAssertTrue(model.aiLinkedJiraLoadingKeys.isEmpty)
    }

    func testLateLinkedIssueCannotReappearAfterDisconnect() async {
        let jira = FakeJiraProvider()
        var finish: CheckedContinuation<Result<JiraIssue, JiraAPIError>, Never>?
        jira.issueLoader = { _ in await withCheckedContinuation { finish = $0 } }
        let (model, source) = makeModel(jira: jira)
        await publishSession(to: source, model: model)
        await waitUntil { finish != nil }

        model.disconnectJira()
        finish?.resume(returning: .success(.fixture(key: "APP-184")))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(model.aiLinkedJiraIssues.isEmpty)
        XCTAssertTrue(model.aiLinkedJiraErrors.isEmpty)
        XCTAssertTrue(model.aiLinkedJiraLoadingKeys.isEmpty)
    }

    func testSuccessfulReconnectReloadsLinkedIssueEvenForTheSameUser() async {
        let jira = FakeJiraProvider()
        jira.issueLoader = { _ in .success(.fixture(key: "APP-184", summary: "Old server")) }
        let (model, source) = makeModel(jira: jira)
        await publishSession(to: source, model: model)
        await waitUntil { model.aiLinkedJiraIssues["APP-184"] != nil }
        jira.issueLoader = { _ in .success(.fixture(key: "APP-184", summary: "New server")) }

        _ = await model.connectJira(baseURLText: "https://new.example.test", token: "fixture")
        await waitUntil { model.aiLinkedJiraIssues["APP-184"]?.summary == "New server" }

        XCTAssertEqual(model.aiLinkedJiraIssues["APP-184"]?.summary, "New server")
    }

    private func makeModel(jira: FakeJiraProvider) -> (NotchViewModel, MemoryAISessionSource) {
        let source = MemoryAISessionSource()
        let model = NotchViewModel(
            providers: [],
            calendarProvider: FakeCalendarProvider(),
            nowPlayingProvider: FakeNowPlayingProvider(),
            liveActivityCenter: LiveActivityCenter(additionalSources: []),
            jiraProvider: jira,
            aiSessionStore: AISessionStore(sources: [source]),
            preferences: MemoryAppPreferences()
        )
        return (model, source)
    }

    private func publishSession(to source: MemoryAISessionSource, model: NotchViewModel) async {
        for _ in 0..<10 { await Task.yield() }
        source.publish([AISession(
            id: AISessionID(sourceID: source.id, sessionID: "session"),
            agentName: "Agent", title: "Task", workspacePath: "/tmp/APP-184",
            modelName: nil, status: .completed, lastActivity: .now, isStale: false
        )])
        await waitUntil { model.aiJiraIssueKeys.values.contains("APP-184") }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(predicate())
    }
}
