import Foundation
import XCTest
@testable import NotchApp

final class JiraProviderTests: XCTestCase {
    @MainActor
    func testVisibleConfiguredProviderLoadsProjectsAndIssues() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()

        provider.start()
        provider.setVisible(true)
        await waitUntil { recorder.latest?.list == .loaded(issues: [.fixture()], total: 1) }

        XCTAssertEqual(recorder.latest?.projects, [.appFixture])
        XCTAssertEqual(loadedIssues(in: recorder.latest), [.fixture()])
        XCTAssertEqual(client.projectCallCount, 1)
        XCTAssertEqual(client.issueCallCount, 1)
    }

    @MainActor
    func testUnconfiguredStartDoesNotUseNetwork() {
        let client = FakeJiraClient()
        let credentials = MemoryJiraCredentialStore()
        let preferences = MemoryAppPreferences()
        let recorder = JiraStateRecorder()
        let provider = makeProvider(client, credentials, preferences, recorder: recorder)

        provider.start()

        XCTAssertEqual(recorder.latest?.connection, .notConfigured)
        XCTAssertEqual(client.currentUserCallCount, 0)
        XCTAssertEqual(client.projectCallCount, 0)
        XCTAssertEqual(client.issueCallCount, 0)
        XCTAssertEqual(client.transitionCallCount, 0)
        XCTAssertEqual(client.performTransitionCallCount, 0)
    }

    @MainActor
    func testHiddenProviderDoesNotRefresh() async {
        let (provider, client, _, _, _) = makeConfiguredProvider(pollingInterval: 0.01)

        provider.start()
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(client.issueCallCount, 0)
        XCTAssertEqual(client.projectCallCount, 0)
    }

    @MainActor
    func testSelectingProjectsPersistsAndRefreshesExactKeys() async {
        let (provider, client, _, preferences, _) = makeConfiguredProvider()
        provider.start()
        provider.setVisible(true)
        await waitUntil { client.issueCallCount == 1 }

        provider.setSelectedProjectKeys(["APP", "WEB"])
        await waitUntil { client.issueCallCount == 2 }

        XCTAssertEqual(preferences.jiraSelectedProjectKeys, ["APP", "WEB"])
        XCTAssertEqual(client.issueRequests.last, ["APP", "WEB"])
    }

    @MainActor
    func testNewestRefreshWins() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.controlledIssueCalls = [1, 2]
        let older = JiraSearchPage.fixture(issues: [.fixture(summary: "Older")])
        let newer = JiraSearchPage.fixture(issues: [.fixture(summary: "Newer")])

        provider.start()
        provider.setVisible(true)
        await waitUntil { client.issueCallCount == 1 }
        provider.refresh()
        await waitUntil { client.issueCallCount == 2 }

        client.resumeIssueCall(2, with: .success(newer))
        await waitUntil { loadedIssues(in: recorder.latest)?.first?.summary == "Newer" }
        client.resumeIssueCall(1, with: .success(older))
        await settle()

        XCTAssertEqual(loadedIssues(in: recorder.latest)?.first?.summary, "Newer")
    }

    @MainActor
    func testLeavingPanelCancelsPolling() async {
        let (provider, client, _, _, _) = makeConfiguredProvider(pollingInterval: 0.01)
        provider.start()
        provider.setVisible(true)
        await waitUntil { client.issueCallCount >= 1 }

        provider.setVisible(false)
        let countAfterLeaving = client.issueCallCount
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(client.issueCallCount, countAfterLeaving)
    }

    @MainActor
    func testCheckConnectionDoesNotPersistCredentials() async {
        let client = FakeJiraClient()
        client.currentUserResult = .success(.fixture(displayName: "Ada"))
        let credentials = MemoryJiraCredentialStore()
        let preferences = MemoryAppPreferences()
        let recorder = JiraStateRecorder()
        let provider = makeProvider(client, credentials, preferences, recorder: recorder)

        let result = await provider.checkConnection(
            baseURLText: "https://jira.example.com",
            token: "temporary-secret"
        )

        XCTAssertEqual(try? result.get(), .fixture(displayName: "Ada"))
        XCTAssertNil(preferences.jiraBaseURLString)
        XCTAssertNil(credentials.token)
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertTrue(recorder.states.isEmpty)
    }

    @MainActor
    func testSecuritySensitiveBaseURLsAreRejectedWithoutNetworkOrPersistence() async {
        let invalidBaseURLs = [
            "http://jira.example.com",
            "https://user@jira.example.com",
            "https://user:secret@jira.example.com",
            "https://jira.example.com/team?expand=all",
            "https://jira.example.com/team#credentials"
        ]

        for baseURL in invalidBaseURLs {
            let client = FakeJiraClient()
            let credentials = MemoryJiraCredentialStore()
            let preferences = MemoryAppPreferences()
            let recorder = JiraStateRecorder()
            let provider = makeProvider(client, credentials, preferences, recorder: recorder)

            let check = await provider.checkConnection(baseURLText: baseURL, token: "secret")
            let connect = await provider.connect(baseURLText: baseURL, token: "secret")

            XCTAssertEqual(check, .failure(.invalidBaseURL), baseURL)
            XCTAssertEqual(connect, .failure(.invalidBaseURL), baseURL)
            XCTAssertEqual(client.currentUserCallCount, 0, baseURL)
            XCTAssertEqual(credentials.saveCount, 0, baseURL)
            XCTAssertNil(credentials.token, baseURL)
            XCTAssertNil(preferences.jiraBaseURLString, baseURL)
            XCTAssertTrue(recorder.states.isEmpty, baseURL)
        }
    }

    @MainActor
    func testHTTPSPathPrefixRemainsValidForCheckAndConnect() async {
        let client = FakeJiraClient()
        let credentials = MemoryJiraCredentialStore()
        let preferences = MemoryAppPreferences()
        let recorder = JiraStateRecorder()
        let provider = makeProvider(client, credentials, preferences, recorder: recorder)

        let check = await provider.checkConnection(
            baseURLText: "https://jira.example.com/gateway/jira",
            token: "temporary-secret"
        )
        let connect = await provider.connect(
            baseURLText: "https://jira.example.com/gateway/jira",
            token: "stored-secret"
        )

        XCTAssertEqual(try? check.get(), .fixture())
        XCTAssertEqual(try? connect.get(), .fixture())
        XCTAssertEqual(client.currentUserCallCount, 2)
        XCTAssertEqual(credentials.token, "stored-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://jira.example.com/gateway/jira")
    }

    @MainActor
    func testStoredSecuritySensitiveBaseURLPublishesInvalidBaseURL() {
        for baseURL in [
            "http://jira.example.com",
            "https://user:secret@jira.example.com/team?expand=all#fragment"
        ] {
            let client = FakeJiraClient()
            let credentials = MemoryJiraCredentialStore(token: "stored-secret")
            let preferences = MemoryAppPreferences(jiraBaseURLString: baseURL)
            let recorder = JiraStateRecorder()
            let provider = makeProvider(client, credentials, preferences, recorder: recorder)

            provider.start()

            XCTAssertEqual(recorder.latest?.connection, .failed(.invalidBaseURL), baseURL)
            XCTAssertEqual(client.currentUserCallCount, 0, baseURL)
            XCTAssertEqual(client.projectCallCount, 0, baseURL)
            XCTAssertEqual(client.issueCallCount, 0, baseURL)
        }
    }

    @MainActor
    func testConnectRevalidatesBeforePersisting() async {
        let client = FakeJiraClient()
        client.currentUserResult = .success(.fixture(displayName: "Grace"))
        let credentials = MemoryJiraCredentialStore()
        let preferences = MemoryAppPreferences()
        let recorder = JiraStateRecorder()
        credentials.onSaveToken = {
            XCTAssertEqual(client.currentUserCallCount, 1)
            XCTAssertNil(preferences.jiraBaseURLString)
        }
        let provider = makeProvider(client, credentials, preferences, recorder: recorder)

        let result = await provider.connect(
            baseURLText: "https://jira.example.com/team",
            token: "keychain-only-secret"
        )

        XCTAssertEqual(try? result.get(), .fixture(displayName: "Grace"))
        XCTAssertEqual(client.currentUserCallCount, 1)
        XCTAssertEqual(credentials.saveCount, 1)
        XCTAssertEqual(credentials.token, "keychain-only-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://jira.example.com/team")
        XCTAssertEqual(recorder.latest?.connection, .connected(.fixture(displayName: "Grace")))
    }

    @MainActor
    func testSuccessfulReconnectCancelsOldTransitionAndRejectsLateCompletion() async {
        let (provider, client, credentials, preferences, recorder) = makeConfiguredProvider()
        client.controlledPerformTransitionIssueKeys = ["APP-184"]
        client.currentUserResult = .success(.fixture(displayName: "New Connection"))
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }

        let oldSubmission = Task {
            await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)
        }
        await waitUntil { client.performTransitionCallCount == 1 }

        let result = await provider.connect(
            baseURLText: "https://new-jira.example.com/team",
            token: "new-secret"
        )
        await waitUntil {
            client.issueCallCount == 2
                && recorder.latest?.connection == .connected(.fixture(displayName: "New Connection"))
        }
        await waitUntil { client.performTransitionCancellationCount == 1 }
        let stateCountAfterReconnect = recorder.states.count
        let issueCountAfterReconnect = client.issueCallCount

        client.resumePerformTransitionCall(for: "APP-184", with: .success(()))
        await oldSubmission.value
        await settle()

        XCTAssertEqual(try? result.get(), .fixture(displayName: "New Connection"))
        XCTAssertEqual(credentials.token, "new-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://new-jira.example.com/team")
        XCTAssertFalse(recorder.states.dropFirst(stateCountAfterReconnect).contains { state in
            loadedIssues(in: state)?.first?.status == .doneFixture
        })
        XCTAssertEqual(client.issueCallCount, issueCountAfterReconnect)
    }

    @MainActor
    func testFailedReconnectPersistencePreservesOldBackgroundLifecycle() async {
        let sleeper = ControlledJiraPollingSleeper()
        let (provider, client, credentials, preferences, recorder) = makeConfiguredProvider(
            pollingInterval: 60,
            pollingSleeper: sleeper.sleep
        )
        let oldUser = JiraUser.fixture(displayName: "Old Connection")
        client.currentUserResult = .success(oldUser)
        provider.start()
        let oldConnection = await provider.connect(
            baseURLText: "https://jira.example.com/old",
            token: "old-secret"
        )
        provider.setVisible(true)
        await waitUntil { client.issueCallCount == 1 && sleeper.callCount == 1 }

        client.controlledPerformTransitionIssueKeys = ["APP-184"]
        let oldSubmission = Task {
            await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)
        }
        await waitUntil { client.performTransitionCallCount == 1 }

        client.currentUserResult = .success(.fixture(displayName: "Rejected New Connection"))
        credentials.saveError = JiraCredentialError.keychainStatus(-1)
        let result = await provider.connect(
            baseURLText: "https://new-jira.example.com/team",
            token: "rejected-new-secret"
        )
        await settle()

        XCTAssertEqual(try? oldConnection.get(), oldUser)
        if case let .failure(error) = result {
            XCTAssertEqual(error, .network)
        } else {
            XCTFail("Expected failed credential persistence")
        }
        XCTAssertEqual(credentials.token, "old-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://jira.example.com/old")
        XCTAssertEqual(recorder.latest?.connection, .connected(oldUser))
        XCTAssertEqual(client.performTransitionCancellationCount, 0)
        XCTAssertEqual(sleeper.cancellationCount, 0)

        let issueCountBeforePolling = client.issueCallCount
        sleeper.resume(1)
        await waitUntil { client.issueCallCount > issueCountBeforePolling }

        provider.setVisible(false)
        sleeper.resumeAll()
        client.resumePerformTransitionCall(for: "APP-184", with: .failure(JiraAPIError.forbidden))
        await oldSubmission.value
        await settle()
    }

    @MainActor
    func testDisconnectDeletesConfigurationAndCancelsWork() async {
        let (provider, client, credentials, preferences, recorder) = makeConfiguredProvider(
            selectedProjectKeys: ["APP"],
            pollingInterval: 0.01
        )
        provider.start()
        provider.setVisible(true)
        await waitUntil { client.issueCallCount >= 1 }

        provider.disconnect()
        let countAfterDisconnect = client.issueCallCount
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(credentials.token)
        XCTAssertNil(preferences.jiraBaseURLString)
        XCTAssertEqual(preferences.jiraSelectedProjectKeys, [])
        XCTAssertEqual(recorder.latest, JiraProviderState())
        XCTAssertEqual(credentials.deleteCount, 1)
        XCTAssertEqual(client.issueCallCount, countAfterDisconnect)
    }

    @MainActor
    func testDisconnectDeleteFailurePreservesConfigurationAndPublishesFailure() async {
        let (provider, client, credentials, preferences, recorder) = makeConfiguredProvider(
            selectedProjectKeys: ["APP", "WEB"],
            pollingInterval: 0.01
        )
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }
        let stateBeforeDisconnect = recorder.latest
        credentials.deleteError = JiraCredentialError.keychainStatus(-1)

        provider.disconnect()
        let issueCountAfterDisconnect = client.issueCallCount
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(credentials.token, "stored-secret")
        XCTAssertEqual(preferences.jiraBaseURLString, "https://jira.example.com")
        XCTAssertEqual(preferences.jiraSelectedProjectKeys, ["APP", "WEB"])
        XCTAssertEqual(recorder.latest?.connection, .failed(.network))
        XCTAssertEqual(recorder.latest?.projects, stateBeforeDisconnect?.projects)
        XCTAssertEqual(recorder.latest?.list, stateBeforeDisconnect?.list)
        XCTAssertEqual(client.issueCallCount, issueCountAfterDisconnect)
    }

    @MainActor
    func testDisconnectCancelsInFlightTransitionPostAndIgnoresLateCompletion() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.controlledPerformTransitionIssueKeys = ["APP-184"]
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }

        let submission = Task {
            await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)
        }
        await waitUntil { client.performTransitionCallCount == 1 }

        provider.disconnect()
        await waitUntil { client.performTransitionCancellationCount == 1 }
        let disconnectedState = recorder.latest
        client.resumePerformTransitionCall(for: "APP-184", with: .success(()))
        await submission.value
        await settle()

        XCTAssertEqual(disconnectedState, JiraProviderState())
        XCTAssertEqual(recorder.latest, disconnectedState)
    }

    @MainActor
    func testStopCancelsInFlightTransitionLoadAndIgnoresLateCompletion() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.controlledTransitionIssueKeys = ["APP-184"]
        provider.start()

        let load = Task {
            await provider.loadTransitions(for: "APP-184")
        }
        await waitUntil { client.transitionCallCount == 1 }

        provider.stop()
        await waitUntil { client.transitionCancellationCount == 1 }
        let stateCountAfterStop = recorder.states.count
        client.resumeTransitionCall(for: "APP-184", with: .success([.doneFixture]))
        await load.value
        await settle()

        XCTAssertEqual(recorder.states.count, stateCountAfterStop)
        XCTAssertNotEqual(recorder.latest?.transitionsByIssueKey["APP-184"], .loaded([.doneFixture]))
    }

    @MainActor
    func testOldPollingLoopCannotRefreshAfterRapidHideAndShow() async {
        let sleeper = ControlledJiraPollingSleeper()
        let (provider, client, _, _, _) = makeConfiguredProvider(
            pollingInterval: 60,
            pollingSleeper: sleeper.sleep
        )
        provider.start()
        provider.setVisible(true)
        await waitUntil { client.issueCallCount == 1 && sleeper.callCount == 1 }

        provider.setVisible(false)
        provider.setVisible(true)
        await waitUntil { client.issueCallCount == 2 && sleeper.callCount == 2 }
        let issueCountAfterShowing = client.issueCallCount

        sleeper.resume(1)
        try? await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(client.issueCallCount, issueCountAfterShowing)
        provider.setVisible(false)
        sleeper.resumeAll()
        await settle()
    }

    @MainActor
    func testInvalidConfiguredBaseURLIsPreservedAcrossRefreshAndTransitions() async {
        let (provider, client, _, preferences, recorder) = makeConfiguredProvider()
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }
        let projectCallCount = client.projectCallCount
        preferences.jiraBaseURLString = "ftp://jira.example.com"

        provider.refresh()
        await provider.loadTransitions(for: "APP-184")
        await provider.performTransition(issueKey: "WEB-72", transition: .doneFixture)

        XCTAssertEqual(
            recorder.states.last { state in
                if case .failed = state.list { return true }
                return false
            }?.list,
            .failed(error: .invalidBaseURL, previous: [.fixture()])
        )
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["APP-184"],
            .failed(error: .invalidBaseURL, previous: nil)
        )
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["WEB-72"],
            .failed(error: .invalidBaseURL, previous: nil)
        )
        XCTAssertEqual(client.projectCallCount, projectCallCount)
        XCTAssertEqual(client.transitionCallCount, 0)
        XCTAssertEqual(client.performTransitionCallCount, 0)
    }

    @MainActor
    func testProjectUnauthorizedStopsPollingUntilSuccessfulConnect() async {
        let sleeper = ControlledJiraPollingSleeper()
        let (provider, client, _, _, recorder) = makeConfiguredProvider(
            pollingInterval: 60,
            pollingSleeper: sleeper.sleep
        )
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil && sleeper.callCount == 1 }

        client.projectsResult = .failure(JiraAPIError.unauthorized)
        sleeper.resume(1)
        await waitUntil {
            recorder.latest?.list == .failed(error: .unauthorized, previous: [.fixture()])
        }

        XCTAssertEqual(recorder.latest?.connection, .failed(.unauthorized))
        await waitUntil(timeout: .milliseconds(100)) { sleeper.cancellationCount == 1 }
        let projectCallsAfterFailure = client.projectCallCount
        sleeper.resumeAll()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(client.projectCallCount, projectCallsAfterFailure)

        provider.setVisible(false)
        sleeper.resumeAll()
        let projectCallsBeforeShowing = client.projectCallCount
        provider.setVisible(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(client.projectCallCount, projectCallsBeforeShowing)

        client.projectsResult = .success([.appFixture])
        let issueCallsBeforeReconnect = client.issueCallCount
        let reconnect = await provider.connect(
            baseURLText: "https://jira.example.com/gateway",
            token: "renewed-secret"
        )
        await waitUntil { client.issueCallCount > issueCallsBeforeReconnect }

        XCTAssertEqual(try? reconnect.get(), .fixture())
        XCTAssertEqual(recorder.latest?.connection, .connected(.fixture()))
        provider.setVisible(false)
        sleeper.resumeAll()
    }

    @MainActor
    func testSearchUnauthorizedFailsConnectionAndPreservesListFailure() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.defaultIssuesResult = .failure(JiraAPIError.unauthorized)

        provider.start()
        provider.setVisible(true)
        await waitUntil { recorder.latest?.list == .failed(error: .unauthorized, previous: nil) }

        XCTAssertEqual(recorder.latest?.connection, .failed(.unauthorized))
        XCTAssertEqual(client.projectCallCount, 1)
        XCTAssertEqual(client.issueCallCount, 1)
        provider.setVisible(false)
    }

    @MainActor
    func testTransitionLoadUnauthorizedFailsConnectionAndRow() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.transitionResultsByIssueKey["APP-184"] = .failure(JiraAPIError.unauthorized)
        provider.start()

        await provider.loadTransitions(for: "APP-184")

        XCTAssertEqual(recorder.latest?.connection, .failed(.unauthorized))
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["APP-184"],
            .failed(error: .unauthorized, previous: nil)
        )
        XCTAssertEqual(client.transitionCallCount, 1)
        provider.setVisible(true)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(client.projectCallCount, 0)
        XCTAssertEqual(client.issueCallCount, 0)
        provider.setVisible(false)
    }

    @MainActor
    func testTransitionPostUnauthorizedPreservesRowAndStopsPollingWithoutRetry() async {
        let sleeper = ControlledJiraPollingSleeper()
        let (provider, client, _, _, recorder) = makeConfiguredProvider(
            pollingInterval: 60,
            pollingSleeper: sleeper.sleep
        )
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil && sleeper.callCount == 1 }
        await provider.loadTransitions(for: "APP-184")
        client.performTransitionResult = .failure(JiraAPIError.unauthorized)

        await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)

        XCTAssertEqual(recorder.latest?.connection, .failed(.unauthorized))
        XCTAssertEqual(loadedIssues(in: recorder.latest)?.first?.status, .openFixture)
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["APP-184"],
            .failed(error: .unauthorized, previous: [.doneFixture])
        )
        XCTAssertEqual(client.performTransitionCallCount, 1)
        await waitUntil(timeout: .milliseconds(100)) { sleeper.cancellationCount == 1 }
        let projectCallsAfterFailure = client.projectCallCount
        let issueCallsAfterFailure = client.issueCallCount
        sleeper.resumeAll()
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(client.projectCallCount, projectCallsAfterFailure)
        XCTAssertEqual(client.issueCallCount, issueCallsAfterFailure)
        XCTAssertEqual(client.performTransitionCallCount, 1)
        provider.setVisible(false)
        sleeper.resumeAll()
    }

    @MainActor
    func testFailedTransitionPreservesStatusAndDoesNotRetry() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.transitionResultsByIssueKey["APP-184"] = .success([.doneFixture])
        client.performTransitionResult = .failure(JiraAPIError.forbidden)
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }
        await provider.loadTransitions(for: "APP-184")

        await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)

        XCTAssertEqual(loadedIssues(in: recorder.latest)?.first?.status, .openFixture)
        XCTAssertEqual(client.performTransitionCallCount, 1)
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["APP-184"],
            .failed(error: .forbidden, previous: [.doneFixture])
        )
    }

    @MainActor
    func testSuccessfulTransitionUpdatesThenReconciles() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        client.controlledIssueCalls = [2]
        provider.start()
        provider.setVisible(true)
        await waitUntil { loadedIssues(in: recorder.latest) != nil }

        await provider.performTransition(issueKey: "APP-184", transition: .doneFixture)
        await waitUntil { client.issueCallCount == 2 }

        let optimisticState = recorder.states.first {
            loadedIssues(in: $0)?.first?.status == .doneFixture
        }
        XCTAssertNotNil(optimisticState)
        XCTAssertEqual(optimisticState?.transitionsByIssueKey["APP-184"], .idle)
        XCTAssertEqual(client.performTransitionCallCount, 1)
        XCTAssertEqual(client.issueCallCount, 2)

        client.resumeIssueCall(
            2,
            with: .success(.fixture(issues: [.fixture(status: .doneFixture)]))
        )
        await waitUntil { loadedIssues(in: recorder.latest)?.first?.status == .doneFixture }
    }

    @MainActor
    func testTransitionStateIsScopedByIssueKey() async {
        let (provider, client, _, _, recorder) = makeConfiguredProvider()
        let webTransition = JiraTransition(
            id: "41",
            name: "Start",
            toStatus: JiraStatus(id: "3", name: "In Progress", categoryKey: "indeterminate")
        )
        client.transitionResultsByIssueKey["WEB-72"] = .success([webTransition])
        client.transitionResultsByIssueKey["APP-184"] = .failure(JiraAPIError.rateLimited)
        provider.start()

        await provider.loadTransitions(for: "WEB-72")
        await provider.loadTransitions(for: "APP-184")

        let appLoading = recorder.states.last {
            $0.transitionsByIssueKey["APP-184"] == .loading
        }
        XCTAssertEqual(appLoading?.transitionsByIssueKey["WEB-72"], .loaded([webTransition]))
        XCTAssertEqual(
            recorder.latest?.transitionsByIssueKey["APP-184"],
            .failed(error: .rateLimited, previous: nil)
        )
        XCTAssertEqual(recorder.latest?.transitionsByIssueKey["WEB-72"], .loaded([webTransition]))
        XCTAssertEqual(client.transitionIssueKeys, ["WEB-72", "APP-184"])
    }
}

@MainActor
private func makeConfiguredProvider(
    selectedProjectKeys: Set<String> = ["APP"],
    pollingInterval: TimeInterval = 60,
    pollingSleeper: (@MainActor (TimeInterval) async -> Void)? = nil
) -> (
    JiraProvider,
    FakeJiraClient,
    MemoryJiraCredentialStore,
    MemoryAppPreferences,
    JiraStateRecorder
) {
    let client = FakeJiraClient()
    let credentials = MemoryJiraCredentialStore(token: "stored-secret")
    let preferences = MemoryAppPreferences(
        jiraBaseURLString: "https://jira.example.com",
        jiraSelectedProjectKeys: selectedProjectKeys
    )
    let recorder = JiraStateRecorder()
    let provider = makeProvider(
        client,
        credentials,
        preferences,
        pollingInterval: pollingInterval,
        pollingSleeper: pollingSleeper,
        recorder: recorder
    )
    return (provider, client, credentials, preferences, recorder)
}

@MainActor
private func makeProvider(
    _ client: FakeJiraClient,
    _ credentials: MemoryJiraCredentialStore,
    _ preferences: MemoryAppPreferences,
    pollingInterval: TimeInterval = 60,
    pollingSleeper: (@MainActor (TimeInterval) async -> Void)? = nil,
    recorder: JiraStateRecorder
) -> JiraProvider {
    let provider: JiraProvider
    if let pollingSleeper {
        provider = JiraProvider(
            client: client,
            credentialStore: credentials,
            preferences: preferences,
            pollingInterval: pollingInterval,
            pollingSleeper: pollingSleeper
        )
    } else {
        provider = JiraProvider(
            client: client,
            credentialStore: credentials,
            preferences: preferences,
            pollingInterval: pollingInterval
        )
    }
    provider.onChange = recorder.record
    return provider
}

@MainActor
private func loadedIssues(in state: JiraProviderState?) -> [JiraIssue]? {
    guard case let .loaded(issues, _)? = state?.list else { return nil }
    return issues
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(condition(), "Timed out waiting for asynchronous Jira provider state")
}

@MainActor
private func settle() async {
    for _ in 0..<10 {
        await Task.yield()
    }
}
