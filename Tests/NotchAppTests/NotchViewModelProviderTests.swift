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

        XCTAssertEqual(model.selectedPanel, .limits)
        XCTAssertEqual(model.numericBadgeCount(for: .limits), 0)
        XCTAssertEqual(model.numericBadgeCount(for: .calendar), 0)
        XCTAssertEqual(model.numericBadgeCount(for: .jira), 0)
        XCTAssertNil(model.numericBadgeCount(for: .music))
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)

        model.isExpanded = true
        await settleMainActorTasks()

        XCTAssertEqual(model.selectedPanel, .limits)
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

    private func makeModel(
        calendarProvider: FakeCalendarProvider = FakeCalendarProvider(),
        nowPlayingProvider: FakeNowPlayingProvider = FakeNowPlayingProvider(),
        jiraProvider: FakeJiraProvider = FakeJiraProvider(),
        preferences: MemoryAppPreferences = MemoryAppPreferences()
    ) -> NotchViewModel {
        NotchViewModel(
            providers: [],
            calendarProvider: calendarProvider,
            nowPlayingProvider: nowPlayingProvider,
            jiraProvider: jiraProvider,
            preferences: preferences
        )
    }

    private func settleMainActorTasks() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }
}
