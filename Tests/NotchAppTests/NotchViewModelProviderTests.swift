import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class NotchViewModelProviderTests: XCTestCase {
    func testInjectedNowPlayingProviderDrivesViewModel() {
        let nowPlaying = FakeNowPlayingProvider()
        let model = makeModel(nowPlayingProvider: nowPlaying)

        nowPlaying.send(snapshot: .fixture(title: "Injected Track"))
        nowPlaying.send(requiresAccessibilityAccess: true)

        XCTAssertTrue(nowPlaying.didStart)
        XCTAssertEqual(model.nowPlayingSnapshot?.title, "Injected Track")
        XCTAssertTrue(model.nowPlayingRequiresAccessibilityAccess)
    }

    func testViewModelChoosesPollingModeFromVisibleMusicState() {
        let nowPlaying = FakeNowPlayingProvider()
        let model = makeModel(nowPlayingProvider: nowPlaying)

        XCTAssertEqual(nowPlaying.pollingModes, [.background])
        model.selectPanel(.music)
        model.isExpanded = true
        XCTAssertEqual(nowPlaying.pollingModes.last, .visibleMusic)

        model.isExpanded = false
        XCTAssertEqual(nowPlaying.pollingModes.last, .background)
    }

    func testVisibleJiraKeepsMusicPollingInBackground() {
        let nowPlaying = FakeNowPlayingProvider()
        let model = makeModel(nowPlayingProvider: nowPlaying)

        model.selectPanel(.jira)
        model.isExpanded = true

        XCTAssertEqual(nowPlaying.pollingModes.last, .background)
    }

    func testViewModelKeepsJiraBadgeActiveAcrossExpandedPanels() {
        let jira = FakeJiraProvider()
        let model = makeModel(jiraProvider: jira)

        XCTAssertTrue(jira.didStart)
        XCTAssertEqual(jira.visibilities, [false])

        model.selectPanel(.jira)
        XCTAssertEqual(jira.visibilities, [false])

        model.isExpanded = true
        XCTAssertEqual(jira.visibilities, [false, true])

        model.showSettings()
        XCTAssertEqual(jira.visibilities, [false, true, false])

        model.hideSettings()
        XCTAssertEqual(jira.visibilities, [false, true, false, true])

        model.isExpanded = false
        XCTAssertEqual(jira.visibilities.last, false)

        model.isExpanded = true
        model.selectPanel(.music)
        XCTAssertEqual(jira.visibilities.last, true)

        model.setPanelVisible(.jira, isVisible: false)
        XCTAssertEqual(jira.visibilities.last, false)
    }

    func testExpandingNotchLoadsNumericBadgesWithoutSelectingLazyPanels() async {
        let calendar = FakeCalendarProvider()
        calendar.upcomingState = .loaded(
            CalendarSnapshot(upcomingEvents: [], monthEvents: [])
        )
        let jira = FakeJiraProvider()
        let model = makeModel(calendarProvider: calendar, jiraProvider: jira)

        XCTAssertEqual(model.selectedPanel, .ai)
        XCTAssertEqual(model.numericBadgeCount(for: .ai), 0)
        XCTAssertEqual(model.numericBadgeCount(for: .calendar), 0)
        XCTAssertEqual(model.numericBadgeCount(for: .jira), 0)
        XCTAssertNil(model.numericBadgeCount(for: .music))
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)

        model.isExpanded = true
        await settleMainActorTasks()

        XCTAssertEqual(model.selectedPanel, .ai)
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 1)
        XCTAssertEqual(model.calendarState, calendar.upcomingState)
        XCTAssertEqual(jira.visibilities.last, true)
    }

    func testInjectedJiraProviderStateReachesViewModel() {
        let jira = FakeJiraProvider()
        let model = makeModel(jiraProvider: jira)
        let state = JiraProviderState(
            connection: .connected(.fixture()),
            projects: [.appFixture, .webFixture],
            selectedProjectKeys: ["APP"],
            list: .loaded(issues: [.fixture()], total: 1)
        )

        jira.send(state: state)

        XCTAssertEqual(model.jiraState, state)
    }

    func testViewModelDelegatesJiraConnectionIntents() async {
        let jira = FakeJiraProvider()
        let model = makeModel(jiraProvider: jira)

        let checked = await model.checkJiraConnection(
            baseURLText: "https://jira.example.test/company",
            token: "draft-secret"
        )
        let connected = await model.connectJira(
            baseURLText: "https://jira.example.test/company",
            token: "draft-secret"
        )
        model.disconnectJira()

        XCTAssertEqual(checked, .success(.fixture(displayName: "Checked User")))
        XCTAssertEqual(connected, .success(.fixture(displayName: "Connected User")))
        XCTAssertEqual(jira.checkedCredentials.first?.baseURLText, "https://jira.example.test/company")
        XCTAssertEqual(jira.checkedCredentials.first?.token, "draft-secret")
        XCTAssertEqual(jira.connectedCredentials.first?.baseURLText, "https://jira.example.test/company")
        XCTAssertEqual(jira.connectedCredentials.first?.token, "draft-secret")
        XCTAssertEqual(jira.disconnectCallCount, 1)
    }

    func testViewModelDelegatesJiraQueueIntents() async {
        let jira = FakeJiraProvider()
        let model = makeModel(jiraProvider: jira)
        let transition = JiraTransition.doneFixture

        model.refreshJira()
        model.setJiraSelectedProjectKeys(["APP", "WEB"])
        await model.loadJiraTransitions(for: "APP-184")
        await model.submitJiraTransition(issueKey: "APP-184", transition: transition)

        XCTAssertEqual(jira.refreshCallCount, 1)
        XCTAssertEqual(jira.selectedProjectKeySets, [Set(["APP", "WEB"])])
        XCTAssertEqual(jira.loadedTransitionIssueKeys, ["APP-184"])
        XCTAssertEqual(jira.submittedTransitions.count, 1)
        XCTAssertEqual(jira.submittedTransitions.first?.issueKey, "APP-184")
        XCTAssertEqual(jira.submittedTransitions.first?.transition, transition)
    }

    func testViewModelDelegatesJiraWorklog() async {
        let jira = FakeJiraProvider()
        let model = makeModel(jiraProvider: jira)
        let draft = JiraWorklogDraft(hours: 2, minutes: 15, description: "Reviewed pull request")

        let result = await model.submitJiraWorklog(issueKey: "APP-184", draft: draft)

        guard case .success = result else {
            return XCTFail("Expected successful worklog submission, got \(result)")
        }
        XCTAssertEqual(jira.submittedWorklogs.count, 1)
        XCTAssertEqual(jira.submittedWorklogs.first?.issueKey, "APP-184")
        XCTAssertEqual(jira.submittedWorklogs.first?.draft, draft)
    }

    func testViewModelExposesConfiguredJiraBaseURLWithoutCredentials() {
        let preferences = MemoryAppPreferences(
            jiraBaseURLString: "https://jira.example.test/company"
        )
        let model = makeModel(preferences: preferences)

        XCTAssertEqual(model.configuredJiraBaseURLString, "https://jira.example.test/company")
    }

    func testInjectedDiagnosticsReachViewModel() {
        let nowPlaying = FakeNowPlayingProvider()
        let model = makeModel(nowPlayingProvider: nowPlaying)
        let diagnostics = NowPlayingDiagnostics(
            source: .accessibility,
            applicationName: "Yandex Music",
            requiresAccessibilityAccess: false,
            lastSuccessfulUpdate: Date(timeIntervalSinceReferenceDate: 3_000)
        )

        nowPlaying.send(diagnostics: diagnostics)

        XCTAssertEqual(model.nowPlayingDiagnostics, diagnostics)
    }

    func testSettingsAreTransientAndPreservePrimaryPanel() {
        let preferences = MemoryAppPreferences(lastSelectedPanel: .music)
        let model = makeModel(preferences: preferences)

        model.showSettings()
        XCTAssertTrue(model.isShowingSettings)
        XCTAssertEqual(model.selectedPanel, .music)
        XCTAssertEqual(preferences.lastSelectedPanel, .music)

        model.hideSettings()
        XCTAssertFalse(model.isShowingSettings)
        XCTAssertEqual(model.selectedPanel, .music)
    }

    func testSettingsUseBackgroundPollingAndReturnToVisibleMusic() {
        let nowPlaying = FakeNowPlayingProvider()
        let preferences = MemoryAppPreferences(lastSelectedPanel: .music)
        let model = makeModel(
            nowPlayingProvider: nowPlaying,
            preferences: preferences
        )
        model.isExpanded = true
        XCTAssertEqual(nowPlaying.pollingModes.last, .visibleMusic)

        model.showSettings()
        XCTAssertEqual(nowPlaying.pollingModes.last, .background)

        model.hideSettings()
        XCTAssertEqual(nowPlaying.pollingModes.last, .visibleMusic)
    }

    func testInjectedCalendarDeniedStateReachesViewModel() async {
        let calendar = FakeCalendarProvider()
        calendar.upcomingState = .denied
        let model = makeModel(calendarProvider: calendar)

        model.refreshCalendar()
        await settleMainActorTasks()

        XCTAssertEqual(model.calendarState, .denied)
    }

    func testInjectedCalendarMonthEventsReachViewModel() async {
        let calendar = FakeCalendarProvider()
        let event = CalendarEvent(
            id: "event-1",
            title: "Planning",
            startDate: Date(timeIntervalSinceReferenceDate: 2_000),
            endDate: Date(timeIntervalSinceReferenceDate: 2_600),
            isAllDay: false,
            calendarTitle: "Work"
        )
        calendar.upcomingState = .loaded(
            CalendarSnapshot(upcomingEvents: [event], monthEvents: [event])
        )
        let model = makeModel(calendarProvider: calendar)

        model.refreshCalendar()
        await settleMainActorTasks()

        XCTAssertEqual(model.calendarEvents(for: Date()), [event])
    }

    func testAISessionAttentionBadgeOverridesQuotaWarnings() async {
        let source = MemoryAISessionSource()
        let store = AISessionStore(sources: [source])
        let model = makeModel(aiSessionStore: store)
        source.publish([
            aiSession(source: source, status: .waitingForApproval),
            aiSession(source: source, id: "input", status: .waitingForInput)
        ])
        await settleMainActorTasks()

        XCTAssertEqual(model.aiAttentionCount, 2)
        XCTAssertEqual(model.numericBadgeCount(for: .ai), 2)
    }

    func testAISessionCollapsesOnlyAfterSuccessfulOpen() async {
        let source = MemoryAISessionSource()
        let store = AISessionStore(sources: [source])
        let model = makeModel(aiSessionStore: store)
        let session = aiSession(source: source, status: .running)
        source.publish([session])
        await settleMainActorTasks()

        model.isExpanded = true
        source.openResult = false
        model.openAISession(session)
        await settleMainActorTasks()
        XCTAssertTrue(model.isExpanded)

        source.openResult = true
        model.openAISession(session)
        await settleMainActorTasks()
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(source.openedSessionIDs, ["session", "session"])
    }

    func testCodeReviewKeepsRecentCompletedRepositoryVisible() async {
        let source = MemoryAISessionSource()
        let store = AISessionStore(sources: [source])
        let model = makeModel(aiSessionStore: store)
        let completed = aiSession(source: source, status: .completed)

        source.publish([completed])
        await settleMainActorTasks()

        XCTAssertEqual(model.codeReviewSessions.map(\.id), [completed.id])
    }

    func testCodeReviewStateIsSharedBySessionsInTheSameWorkspace() async throws {
        let source = MemoryAISessionSource()
        let store = AISessionStore(sources: [source])
        let snapshot = CodeReviewSnapshot(
            repository: CodeRepositoryContext(
                rootPath: "/tmp/NotchApp",
                branch: "feature/shared",
                remoteURL: "git@gitlab.example.test:team/app.git",
                host: "gitlab.example.test",
                projectPath: "team/app",
                hostKind: .gitlab
            ),
            request: nil
        )
        let provider = CountingCodeReviewProvider(result: .success(snapshot))
        let model = makeModel(aiSessionStore: store, codeReviewProvider: provider)
        let first = aiSession(source: source, id: "first", status: .running)
        let second = aiSession(source: source, id: "second", status: .completed)

        source.publish([first, second])
        await settleMainActorTasks()
        model.isExpanded = true
        model.selectAISection(.sessions)
        for _ in 0..<20 where model.codeReviewState(for: first).snapshot == nil {
            await Task.yield()
        }

        XCTAssertEqual(model.codeReviewSessions.map(\.id), [first.id])
        XCTAssertEqual(model.codeReviewState(for: first).snapshot, snapshot)
        XCTAssertEqual(model.codeReviewState(for: second).snapshot, snapshot)
        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1)
    }

    private func makeModel(
        calendarProvider: FakeCalendarProvider = FakeCalendarProvider(),
        nowPlayingProvider: FakeNowPlayingProvider = FakeNowPlayingProvider(),
        jiraProvider: FakeJiraProvider = FakeJiraProvider(),
        aiSessionStore: AISessionStore = AISessionStore(sources: []),
        codeReviewProvider: any CodeReviewProviding = LocalCodeReviewProvider(),
        preferences: MemoryAppPreferences = MemoryAppPreferences()
    ) -> NotchViewModel {
        NotchViewModel(
            providers: [],
            calendarProvider: calendarProvider,
            nowPlayingProvider: nowPlayingProvider,
            jiraProvider: jiraProvider,
            aiSessionStore: aiSessionStore,
            codeReviewProvider: codeReviewProvider,
            preferences: preferences
        )
    }

    private func aiSession(
        source: MemoryAISessionSource,
        id: String = "session",
        status: AISessionStatus
    ) -> AISession {
        AISession(
            id: AISessionID(sourceID: source.id, sessionID: id),
            agentName: "Agent",
            title: "Task",
            workspacePath: "/tmp/NotchApp",
            modelName: nil,
            status: status,
            lastActivity: .now,
            isStale: false
        )
    }

    private func settleMainActorTasks() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}

private actor CountingCodeReviewProvider: CodeReviewProviding {
    private let result: Result<CodeReviewSnapshot, CodeReviewError>
    private var calls = 0

    init(result: Result<CodeReviewSnapshot, CodeReviewError>) {
        self.result = result
    }

    var callCount: Int { calls }

    func load(workspacePath: String) async -> Result<CodeReviewSnapshot, CodeReviewError> {
        calls += 1
        return result
    }
}
