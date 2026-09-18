import Foundation
import XCTest
@testable import NotchApp

final class JiraLifecycleTests: XCTestCase {
    @MainActor
    func testSuccessfulReconnectDropsOldServerListBeforeItsFirstRefresh() async {
        let client = FakeJiraClient()
        let preferences = MemoryAppPreferences(jiraBaseURLString: "https://old.example.test")
        let provider = JiraProvider(
            client: client,
            credentialStore: MemoryJiraCredentialStore(token: "old-fixture"),
            preferences: preferences
        )
        var latest: JiraProviderState?
        provider.onChange = { latest = $0 }
        provider.start()
        defer { provider.stop() }
        provider.setVisible(true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while latest?.projects.isEmpty != false, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(latest?.projects.count, 1)
        provider.setVisible(false)
        await provider.loadTransitions(for: "APP-184")
        XCTAssertEqual(latest?.transitionsByIssueKey["APP-184"], .loaded([.doneFixture]))

        _ = await provider.connect(baseURLText: "https://new.example.test", token: "new-fixture")

        XCTAssertEqual(latest?.list, .idle)
        XCTAssertEqual(latest?.projects, [])
        XCTAssertEqual(latest?.transitionsByIssueKey, [:])
    }

    @MainActor
    func testLateIssueSuccessAfterDisconnectDoesNotReturnUsableIssue() async {
        let (provider, client, credentials, preferences, recorder) = makeLifecycleProvider()
        let request = Task { await provider.issue(key: "APP-184") }
        await waitForDirectIssueCall(client, count: 1)

        provider.disconnect()
        client.resumeDirectIssueCall(1, with: .success(client.issue))

        let result = await request.value
        XCTAssertEqual(result, .failure(.network))
        XCTAssertNil(credentials.token)
        XCTAssertNil(preferences.jiraBaseURLString)
        XCTAssertEqual(recorder.latest?.connection, .notConfigured)
    }

    @MainActor
    func testLateIssueUnauthorizedAfterReconnectDoesNotInvalidateNewConnection() async {
        let (provider, client, credentials, preferences, recorder) = makeLifecycleProvider()
        let request = Task { await provider.issue(key: "APP-184") }
        await waitForDirectIssueCall(client, count: 1)

        let newUser = JiraUser(displayName: "New Connection")
        client.currentUser = newUser
        let reconnect = await provider.connect(
            baseURLText: "https://new-jira.example.com/team",
            token: "new-secret"
        )
        client.resumeDirectIssueCall(1, with: .failure(JiraAPIError.unauthorized))

        let result = await request.value
        XCTAssertEqual(result, .failure(.unauthorized))
        XCTAssertEqual(reconnect, .success(newUser))
        XCTAssertEqual(credentials.token, "new-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://new-jira.example.com/team")
        XCTAssertEqual(recorder.latest?.connection, .connected(newUser))
    }

    @MainActor
    func testLatePinSuccessAfterDisconnectDoesNotPersistPin() async {
        let (provider, client, _, preferences, recorder) = makeLifecycleProvider()
        let pin = Task { await provider.pinIssue(key: "APP-184") }
        await waitForDirectIssueCall(client, count: 1)

        provider.disconnect()
        client.resumeDirectIssueCall(1, with: .success(client.issue))
        await pin.value

        XCTAssertEqual(preferences.jiraPinnedIssues, [])
        XCTAssertEqual(recorder.latest?.pinned.issues, [])
        XCTAssertFalse(recorder.latest?.pinned.isPinningIssue ?? true)
        XCTAssertNil(recorder.latest?.pinned.pinIssueError)
    }

    @MainActor
    func testLatePinUnauthorizedAfterReconnectDoesNotChangeNewConnection() async {
        let (provider, client, credentials, preferences, recorder) = makeLifecycleProvider()
        let pin = Task { await provider.pinIssue(key: "APP-184") }
        await waitForDirectIssueCall(client, count: 1)

        let newUser = JiraUser(displayName: "New Connection")
        client.currentUser = newUser
        _ = await provider.connect(
            baseURLText: "https://new-jira.example.com/team",
            token: "new-secret"
        )
        client.resumeDirectIssueCall(1, with: .failure(JiraAPIError.unauthorized))
        await pin.value

        XCTAssertEqual(credentials.token, "new-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://new-jira.example.com/team")
        XCTAssertEqual(recorder.latest?.connection, .connected(newUser))
        XCTAssertFalse(recorder.latest?.pinned.isPinningIssue ?? true)
        XCTAssertNil(recorder.latest?.pinned.pinIssueError)
    }

    @MainActor
    func testConcurrentDuplicatePinsShareOneRequestAndPersistOnePin() async {
        let (provider, client, _, preferences, recorder) = makeLifecycleProvider()
        let first = Task { await provider.pinIssue(key: "APP-184") }
        await waitForDirectIssueCall(client, count: 1)

        let second = Task { await provider.pinIssue(key: "APP-184") }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(client.directIssueCallCount, 1)
        XCTAssertTrue(recorder.latest?.pinned.isPinningIssue ?? false)

        client.resumeDirectIssueCall(1, with: .success(client.issue))
        if client.directIssueCallCount == 2 {
            client.resumeDirectIssueCall(2, with: .success(client.issue))
        }
        await first.value
        await second.value

        let expected = [JiraPinnedIssue(key: "APP-184", summary: "Provider lifecycle")]
        XCTAssertEqual(preferences.jiraPinnedIssues, expected)
        XCTAssertEqual(recorder.latest?.pinned.issues, expected)
        XCTAssertFalse(recorder.latest?.pinned.isPinningIssue ?? true)
    }
}

@MainActor
private func makeLifecycleProvider() -> (
    JiraProvider,
    LifecycleJiraClient,
    MemoryJiraCredentialStore,
    MemoryAppPreferences,
    LifecycleJiraStateRecorder
) {
    let client = LifecycleJiraClient()
    let credentials = MemoryJiraCredentialStore(token: "stored-secret")
    let preferences = MemoryAppPreferences(jiraBaseURLString: "https://jira.example.com")
    let recorder = LifecycleJiraStateRecorder()
    let provider = JiraProvider(
        client: client,
        credentialStore: credentials,
        preferences: preferences
    )
    provider.onChange = recorder.record
    return (provider, client, credentials, preferences, recorder)
}

@MainActor
private func waitForDirectIssueCall(
    _ client: LifecycleJiraClient,
    count: Int,
    timeout: Duration = .seconds(1)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while client.directIssueCallCount < count, clock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(client.directIssueCallCount, count, "Timed out waiting for direct Jira issue request")
}

@MainActor
private final class LifecycleJiraStateRecorder {
    private(set) var latest: JiraProviderState?

    func record(_ state: JiraProviderState) {
        latest = state
    }
}

@MainActor
private final class LifecycleJiraClient: JiraClientProtocol {
    var currentUser = JiraUser(displayName: "Stored Connection")
    let issue = JiraIssue(
        id: "184",
        key: "APP-184",
        summary: "Provider lifecycle",
        projectKey: "APP",
        projectName: "Application",
        status: JiraStatus(id: "1", name: "Open", categoryKey: "new"),
        priorityName: nil,
        dueDate: nil,
        updatedAt: nil
    )

    private(set) var directIssueCallCount = 0
    private var directIssueContinuations: [Int: CheckedContinuation<JiraIssue, Error>] = [:]

    func currentUser(baseURL: URL, token: String) async throws -> JiraUser {
        currentUser
    }

    func projects(baseURL: URL, token: String) async throws -> [JiraProject] { [] }

    func issues(
        baseURL: URL,
        token: String,
        projectKeys: Set<String>,
        scope: JiraIssueScope,
        startAt: Int,
        maxResults: Int
    ) async throws -> JiraSearchPage {
        JiraSearchPage(issues: [], total: 0)
    }

    func boards(baseURL: URL, token: String) async throws -> [JiraBoard] { [] }

    func boardIssues(
        baseURL: URL,
        token: String,
        boardID: String
    ) async throws -> JiraSearchPage {
        JiraSearchPage(issues: [], total: 0)
    }

    func projectIssues(
        baseURL: URL,
        token: String,
        projectKey: String
    ) async throws -> JiraSearchPage {
        JiraSearchPage(issues: [], total: 0)
    }

    func issue(baseURL: URL, token: String, issueKey: String) async throws -> JiraIssue {
        directIssueCallCount += 1
        let call = directIssueCallCount
        return try await withCheckedThrowingContinuation { continuation in
            directIssueContinuations[call] = continuation
        }
    }

    func transitions(baseURL: URL, token: String, issueKey: String) async throws -> [JiraTransition] { [] }

    func performTransition(
        baseURL: URL,
        token: String,
        issueKey: String,
        transitionID: String
    ) async throws {}

    func assignableUsers(
        baseURL: URL,
        token: String,
        projectKey: String,
        query: String
    ) async throws -> [JiraAssignee] { [] }

    func assign(
        baseURL: URL,
        token: String,
        issueKey: String,
        username: String?
    ) async throws {}

    func addWorklog(
        baseURL: URL,
        token: String,
        issueKey: String,
        timeSpentSeconds: Int,
        comment: String
    ) async throws {}

    func resumeDirectIssueCall(_ call: Int, with result: Result<JiraIssue, Error>) {
        guard let continuation = directIssueContinuations.removeValue(forKey: call) else {
            XCTFail("No direct Jira issue request for call \(call)")
            return
        }
        continuation.resume(with: result)
    }
}
