import Foundation
import NotchCore
import XCTest
@testable import NotchApp

@MainActor
final class NotchViewModelProviderTests: XCTestCase {
    func testQuotaRefreshIsPrefetchedAndHoverRefreshesOnlyWhenStale() async {
        let provider = RecordingQuotaProvider()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let model = makeModel(providers: [provider], now: { currentDate })
        await settleMainActorTasks()

        let initialCallCount = await provider.callCount
        XCTAssertEqual(initialCallCount, 1)

        model.isCompactHovered = true
        await settleMainActorTasks()
        let freshHoverCallCount = await provider.callCount
        XCTAssertEqual(freshHoverCallCount, 1)

        model.isCompactHovered = false
        currentDate = currentDate.addingTimeInterval(11)
        model.isCompactHovered = true
        await settleMainActorTasks()
        let staleHoverCallCount = await provider.callCount
        XCTAssertEqual(staleHoverCallCount, 2)
    }

    func testOpeningNotchRefreshesStaleQuotaWithoutWaitingForLimitsPanel() async {
        let provider = RecordingQuotaProvider()
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let model = makeModel(providers: [provider], now: { currentDate })
        await settleMainActorTasks()
        let initialCallCount = await provider.callCount
        XCTAssertEqual(initialCallCount, 1)

        currentDate = currentDate.addingTimeInterval(11)
        model.isExpanded = true
        await settleMainActorTasks()

        let expandedCallCount = await provider.callCount
        XCTAssertEqual(expandedCallCount, 2)
    }

    func testSideModeKeepsEdgeTriggerIndependentFromNotchHoverAndExpansion() async {
        let providers = [RecordingQuotaProvider(id: "first"), RecordingQuotaProvider(id: "second")]
        let preferences = MemoryAppPreferences(
            quotaProviderOrder: ["first", "second"],
            compactQuotaProviderID: "first",
            compactQuotaDisplayMode: .wave,
            quotaPanelEdge: .right
        )
        let model = makeModel(providers: providers, preferences: preferences)
        await settleMainActorTasks()

        XCTAssertTrue(model.shouldEnableQuotaEdgePanel)
        XCTAssertFalse(model.shouldEnableQuotaCornerStack)
        model.isCompactHovered = true
        XCTAssertTrue(model.shouldEnableQuotaEdgePanel)
        model.isExpanded = true
        XCTAssertTrue(model.shouldEnableQuotaEdgePanel)
        model.setCompactQuotaDisplayMode(.top)
        XCTAssertFalse(model.shouldEnableQuotaEdgePanel)
        model.setQuotaPanelEdge(.left)
        model.setQuotaStackCorner(.topRight)
        model.setCompactQuotaDisplayMode(.stack)
        XCTAssertFalse(model.shouldEnableQuotaEdgePanel)
        XCTAssertTrue(model.shouldEnableQuotaCornerStack)
        XCTAssertEqual(preferences.quotaPanelEdge, .left)
        XCTAssertEqual(preferences.quotaStackCorner, .topRight)
    }

    func testRunningAndPausedTimerAppearInCompactAndCancelClearsIt() {
        let model = makeModel()
        model.timerSource.create(duration: 300)
        XCTAssertEqual(model.compactTimer?.countdownText, "05:00")
        XCTAssertTrue(model.usesWideCompactLayout)
        XCTAssertFalse(model.isExpanded)
        model.timerSource.toggle()
        XCTAssertEqual(model.compactTimer?.state, .paused)
        model.timerSource.cancel()
        XCTAssertNil(model.compactTimer)
        XCTAssertFalse(model.usesWideCompactLayout)
    }

    func testAgentAttentionSuppressesCompactTimerWithoutStoppingIt() async {
        let source = MemoryAISessionSource()
        let model = makeModel(aiSessionStore: AISessionStore(sources: [source]))
        model.timerSource.create(duration: 300)
        source.publish([aiSession(source: source, status: .waitingForApproval)])
        await settleMainActorTasks()
        XCTAssertNil(model.compactTimer)
        XCTAssertEqual(model.timerSource.snapshot?.state, .active)
        source.publish([aiSession(source: source, status: .running)])
        await settleMainActorTasks()
        XCTAssertNotNil(model.compactTimer)
        model.timerSource.cancel()
    }

    func testHiddenCalendarIgnoresLateLoadAfterReenable() async {
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        var finishOldLoad: CheckedContinuation<CalendarLoadState, Never>?
        calendar.upcomingLoader = { await withCheckedContinuation { finishOldLoad = $0 } }
        let model = makeModel(calendarProvider: calendar)
        await settleMainActorTasks()
        XCTAssertNotNil(finishOldLoad)
        model.setPanelVisible(.calendar, isVisible: false)
        calendar.upcomingLoader = nil
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: []))
        model.setPanelVisible(.calendar, isVisible: true)
        await settleMainActorTasks()
        let obsoleteEvent = CalendarEvent(id: "old", title: "Cancelled meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        finishOldLoad?.resume(returning: .loaded(CalendarSnapshot(upcomingEvents: [obsoleteEvent], monthEvents: [])))
        await settleMainActorTasks()
        XCTAssertNil(model.upcomingMeetingReminder)
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 2)
    }

    func testManualRefreshKeepsReminderUntilReplacementArrives() async {
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let event = CalendarEvent(id: "meeting", title: "Test meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let model = makeModel(calendarProvider: calendar)
        await settleMainActorTasks()
        var finish: CheckedContinuation<CalendarLoadState, Never>?
        calendar.upcomingLoader = { await withCheckedContinuation { finish = $0 } }
        model.refreshCalendar()
        await settleMainActorTasks()
        XCTAssertEqual(model.calendarState, .loading)
        XCTAssertEqual(model.compactMeetingReminder?.event, event)
        XCTAssertNotNil(finish)
        finish?.resume(returning: .loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: [])))
        await settleMainActorTasks()
        XCTAssertNil(model.compactMeetingReminder)
    }

    func testEnablingCalendarLoadsReminderImmediately() async {
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let event = CalendarEvent(id: "meeting", title: "Test meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let model = makeModel(calendarProvider: calendar,
            preferences: MemoryAppPreferences(hiddenPanelIDs: [.calendar]))
        await settleMainActorTasks()
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
        model.setPanelVisible(.calendar, isVisible: true)
        await settleMainActorTasks()
        XCTAssertEqual(model.compactMeetingReminder?.event, event)
        model.setPanelVisible(.calendar, isVisible: false)
        XCTAssertNil(model.upcomingMeetingReminder)
    }

    func testReminderLoadsWhileCollapsedOnlyWithExistingPermission() async {
        let calendar = FakeCalendarProvider()
        let noAccessModel = makeModel(calendarProvider: calendar)
        await settleMainActorTasks()
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
        XCTAssertNil(noAccessModel.compactMeetingReminder)

        calendar.canLoadWithoutPrompt = true
        let event = CalendarEvent(id: "meeting", title: "Test meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let model = makeModel(calendarProvider: calendar)
        await settleMainActorTasks()
        XCTAssertFalse(model.isExpanded)
        XCTAssertEqual(model.compactMeetingReminder?.event, event)
        XCTAssertTrue(model.usesWideCompactLayout)
    }

    func testAgentAttentionTakesPriorityOverMeetingReminder() async {
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let event = CalendarEvent(id: "meeting", title: "Test meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let source = MemoryAISessionSource()
        let model = makeModel(calendarProvider: calendar, aiSessionStore: AISessionStore(sources: [source]))
        await settleMainActorTasks()
        XCTAssertNotNil(model.compactMeetingReminder)
        source.publish([aiSession(source: source, status: .waitingForApproval)])
        await settleMainActorTasks()
        XCTAssertNil(model.compactMeetingReminder)
        source.publish([aiSession(source: source, status: .completed)])
        await settleMainActorTasks()
        XCTAssertNotNil(model.compactMeetingReminder)
    }

    func testCalendarRefreshClearsRemovedMeetingReminder() async {
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let event = CalendarEvent(id: "meeting", title: "Test meeting",
            startDate: Date().addingTimeInterval(120), endDate: Date().addingTimeInterval(1800),
            isAllDay: false, calendarTitle: "Test")
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let model = makeModel(calendarProvider: calendar)
        await settleMainActorTasks()
        XCTAssertNotNil(model.compactMeetingReminder)
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [], monthEvents: []))
        model.refreshCalendar()
        await settleMainActorTasks()
        XCTAssertNil(model.compactMeetingReminder)
    }

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

    func testSearchDoesNotRequestCalendarAccessWhenCalendarIsHidden() async {
        let calendar = FakeCalendarProvider()
        let model = makeModel(
            calendarProvider: calendar,
            preferences: MemoryAppPreferences(hiddenPanelIDs: [.calendar])
        )
        await settleMainActorTasks()

        model.openUtility(.search)
        await settleMainActorTasks()

        XCTAssertEqual(model.activeUtility, .search)
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
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
        model.setJiraIssueScope(.allAccessible)
        model.loadMoreJiraIssues()
        await model.loadJiraTransitions(for: "APP-184")
        await model.submitJiraTransition(issueKey: "APP-184", transition: transition)

        XCTAssertEqual(jira.refreshCallCount, 1)
        XCTAssertEqual(jira.selectedProjectKeySets, [Set(["APP", "WEB"])])
        XCTAssertEqual(jira.selectedIssueScopes, [.allAccessible])
        XCTAssertEqual(jira.loadMoreIssuesCallCount, 1)
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
        providers: [any QuotaProvider] = [],
        calendarProvider: FakeCalendarProvider = FakeCalendarProvider(),
        nowPlayingProvider: FakeNowPlayingProvider = FakeNowPlayingProvider(),
        jiraProvider: FakeJiraProvider = FakeJiraProvider(),
        aiSessionStore: AISessionStore = AISessionStore(sources: []),
        codeReviewProvider: any CodeReviewProviding = LocalCodeReviewProvider(),
        preferences: MemoryAppPreferences = MemoryAppPreferences(),
        now: @escaping @MainActor () -> Date = Date.init
    ) -> NotchViewModel {
        NotchViewModel(
            providers: providers,
            calendarProvider: calendarProvider,
            nowPlayingProvider: nowPlayingProvider,
            jiraProvider: jiraProvider,
            aiSessionStore: aiSessionStore,
            codeReviewProvider: codeReviewProvider,
            preferences: preferences,
            now: now
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

private actor RecordingQuotaProvider: QuotaProvider {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let sourceURL: URL? = nil
    private(set) var callCount = 0

    init(id: String = "quota") {
        self.id = id
        self.displayName = id
    }

    func loadSnapshot() async -> QuotaSnapshot {
        callCount += 1
        return QuotaSnapshot(
            providerID: id,
            providerName: displayName,
            windows: [
                QuotaWindow(
                    id: "weekly",
                    label: "7d",
                    limit: 100,
                    remaining: 75,
                    resetAt: nil,
                    unit: .percentage
                )
            ],
            connection: .live,
            updatedAt: .now,
            sourceURL: nil,
            message: nil
        )
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
