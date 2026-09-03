import Foundation
import XCTest
@testable import NotchApp

@MainActor
final class MemoryAppPreferences: AppPreferencesStoring {
    var hoverExpansionDelay: TimeInterval
    var lastSelectedPanel: PanelID
    var panelOrder: [PanelID]
    var hiddenPanelIDs: Set<PanelID>
    var startupPanel: PanelID?
    var selectedAISection: AISection
    var hasCompletedPanelSwipe: Bool
    var quotaProviderOrder: [String]
    var hiddenQuotaProviderIDs: Set<String>
    var compactQuotaProviderID: String
    var jiraBaseURLString: String?
    var jiraSelectedProjectKeys: Set<String>
    var jiraPinnedContainers: [JiraPinnedContainer]
    var jiraPinnedIssues: [JiraPinnedIssue]

    init(
        hoverExpansionDelay: TimeInterval = 0.5,
        lastSelectedPanel: PanelID = .ai,
        panelOrder: [PanelID] = PanelID.allCases,
        hiddenPanelIDs: Set<PanelID> = [],
        startupPanel: PanelID? = nil,
        selectedAISection: AISection = .limits,
        hasCompletedPanelSwipe: Bool = false,
        quotaProviderOrder: [String] = UserDefaultsAppPreferences.defaultQuotaProviderOrder,
        hiddenQuotaProviderIDs: Set<String> = [],
        compactQuotaProviderID: String = UserDefaultsAppPreferences.defaultQuotaProviderOrder[0],
        jiraBaseURLString: String? = nil,
        jiraSelectedProjectKeys: Set<String> = [],
        jiraPinnedContainers: [JiraPinnedContainer] = [],
        jiraPinnedIssues: [JiraPinnedIssue] = []
    ) {
        self.hoverExpansionDelay = hoverExpansionDelay
        self.lastSelectedPanel = lastSelectedPanel
        self.panelOrder = panelOrder
        self.hiddenPanelIDs = hiddenPanelIDs
        self.startupPanel = startupPanel
        self.selectedAISection = selectedAISection
        self.hasCompletedPanelSwipe = hasCompletedPanelSwipe
        self.quotaProviderOrder = quotaProviderOrder
        self.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
        self.compactQuotaProviderID = compactQuotaProviderID
        self.jiraBaseURLString = jiraBaseURLString
        self.jiraSelectedProjectKeys = jiraSelectedProjectKeys
        self.jiraPinnedContainers = jiraPinnedContainers
        self.jiraPinnedIssues = jiraPinnedIssues
    }
}

@MainActor
final class MemoryAISessionSource: AISessionSource {
    let id: String
    let displayName: String
    var openResult = true
    private(set) var openedSessionIDs: [String] = []
    private var continuation: AsyncStream<AISessionSourceSnapshot>.Continuation?

    init(id: String = "memory-ai") {
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
        return openResult
    }

    func publish(_ sessions: [AISession], health: AISessionSourceHealth = .live) {
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: sessions,
            health: health,
            updatedAt: .now
        ))
    }
}

@MainActor
final class MemoryJiraCredentialStore: JiraCredentialStoring {
    var token: String?
    var loadError: Error?
    var saveError: Error?
    var deleteError: Error?
    var onSaveToken: (() -> Void)?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() throws -> String? {
        loadCount += 1
        if let loadError { throw loadError }
        return token
    }

    func saveToken(_ token: String) throws {
        saveCount += 1
        onSaveToken?()
        if let saveError { throw saveError }
        self.token = token
    }

    func deleteToken() throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        token = nil
    }
}

@MainActor
final class FakeJiraClient: JiraClientProtocol {
    var currentUserResult: Result<JiraUser, Error> = .success(.fixture())
    var projectsResult: Result<[JiraProject], Error> = .success([.appFixture])
    var boardsResult: Result<[JiraBoard], Error> = .success([])
    var defaultIssuesResult: Result<JiraSearchPage, Error> = .success(.appFixture)
    var boardIssuesResult: Result<JiraSearchPage, Error> = .success(.appFixture)
    var projectIssuesResult: Result<JiraSearchPage, Error> = .success(.appFixture)
    var directIssueResult: Result<JiraIssue, Error> = .success(.fixture())
    var issueResultsByCall: [Int: Result<JiraSearchPage, Error>] = [:]
    var controlledIssueCalls: Set<Int> = []
    var controlledTransitionIssueKeys: Set<String> = []
    var controlledPerformTransitionIssueKeys: Set<String> = []
    var controlledAddWorklogCalls: Set<Int> = []
    var transitionResultsByIssueKey: [String: Result<[JiraTransition], Error>] = [:]
    var performTransitionResult: Result<Void, Error> = .success(())
    var assignableUsersResult: Result<[JiraAssignee], Error> = .success([])
    var assignResult: Result<Void, Error> = .success(())
    var addWorklogResult: Result<Void, Error> = .success(())

    private(set) var currentUserCallCount = 0
    private(set) var projectCallCount = 0
    private(set) var issueCallCount = 0
    private(set) var transitionCallCount = 0
    private(set) var performTransitionCallCount = 0
    private(set) var assignableUsersCallCount = 0
    private(set) var assignCallCount = 0
    private(set) var addWorklogCallCount = 0
    private(set) var issueRequests: [Set<String>] = []
    private(set) var transitionIssueKeys: [String] = []
    private(set) var performedTransitions: [(issueKey: String, transitionID: String)] = []
    private(set) var assigneeSearches: [(projectKey: String, query: String)] = []
    private(set) var assignments: [(issueKey: String, username: String?)] = []
    private(set) var addedWorklogs: [(
        issueKey: String,
        timeSpentSeconds: Int,
        comment: String
    )] = []
    private(set) var transitionCancellationCount = 0
    private(set) var performTransitionCancellationCount = 0

    private var controlledIssueContinuations: [Int: CheckedContinuation<JiraSearchPage, Error>] = [:]
    private var controlledTransitionContinuations: [
        String: CheckedContinuation<[JiraTransition], Error>
    ] = [:]
    private var controlledPerformTransitionContinuations: [
        String: CheckedContinuation<Void, Error>
    ] = [:]
    private var controlledAddWorklogContinuations: [
        Int: CheckedContinuation<Void, Error>
    ] = [:]

    func currentUser(baseURL: URL, token: String) async throws -> JiraUser {
        currentUserCallCount += 1
        return try currentUserResult.get()
    }

    func projects(baseURL: URL, token: String) async throws -> [JiraProject] {
        projectCallCount += 1
        return try projectsResult.get()
    }

    func issues(
        baseURL: URL,
        token: String,
        projectKeys: Set<String>
    ) async throws -> JiraSearchPage {
        issueCallCount += 1
        let call = issueCallCount
        issueRequests.append(projectKeys)

        if controlledIssueCalls.contains(call) {
            return try await withCheckedThrowingContinuation { continuation in
                controlledIssueContinuations[call] = continuation
            }
        }

        return try (issueResultsByCall[call] ?? defaultIssuesResult).get()
    }

    func boards(baseURL: URL, token: String) async throws -> [JiraBoard] {
        try boardsResult.get()
    }

    func boardIssues(
        baseURL: URL,
        token: String,
        boardID: String
    ) async throws -> JiraSearchPage {
        try boardIssuesResult.get()
    }

    func projectIssues(
        baseURL: URL,
        token: String,
        projectKey: String
    ) async throws -> JiraSearchPage {
        try projectIssuesResult.get()
    }

    func issue(baseURL: URL, token: String, issueKey: String) async throws -> JiraIssue {
        try directIssueResult.get()
    }

    func transitions(
        baseURL: URL,
        token: String,
        issueKey: String
    ) async throws -> [JiraTransition] {
        transitionCallCount += 1
        transitionIssueKeys.append(issueKey)
        if controlledTransitionIssueKeys.contains(issueKey) {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    controlledTransitionContinuations[issueKey] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.transitionCancellationCount += 1
                }
            }
        }
        return try (transitionResultsByIssueKey[issueKey] ?? .success([.doneFixture])).get()
    }

    func performTransition(
        baseURL: URL,
        token: String,
        issueKey: String,
        transitionID: String
    ) async throws {
        performTransitionCallCount += 1
        performedTransitions.append((issueKey, transitionID))
        if controlledPerformTransitionIssueKeys.contains(issueKey) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    controlledPerformTransitionContinuations[issueKey] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.performTransitionCancellationCount += 1
                }
            }
            return
        }
        try performTransitionResult.get()
    }

    func assignableUsers(
        baseURL: URL,
        token: String,
        projectKey: String,
        query: String
    ) async throws -> [JiraAssignee] {
        assignableUsersCallCount += 1
        assigneeSearches.append((projectKey, query))
        return try assignableUsersResult.get()
    }

    func assign(
        baseURL: URL,
        token: String,
        issueKey: String,
        username: String?
    ) async throws {
        assignCallCount += 1
        assignments.append((issueKey, username))
        try assignResult.get()
    }

    func addWorklog(
        baseURL: URL,
        token: String,
        issueKey: String,
        timeSpentSeconds: Int,
        comment: String
    ) async throws {
        addWorklogCallCount += 1
        let call = addWorklogCallCount
        addedWorklogs.append((issueKey, timeSpentSeconds, comment))
        if controlledAddWorklogCalls.contains(call) {
            try await withCheckedThrowingContinuation { continuation in
                controlledAddWorklogContinuations[call] = continuation
            }
            return
        }
        try addWorklogResult.get()
    }

    func resumeIssueCall(_ call: Int, with result: Result<JiraSearchPage, Error>) {
        guard let continuation = controlledIssueContinuations.removeValue(forKey: call) else {
            XCTFail("No controlled Jira issue request for call \(call)")
            return
        }
        continuation.resume(with: result)
    }

    func resumeTransitionCall(
        for issueKey: String,
        with result: Result<[JiraTransition], Error>
    ) {
        guard let continuation = controlledTransitionContinuations.removeValue(forKey: issueKey) else {
            XCTFail("No controlled Jira transition request for \(issueKey)")
            return
        }
        continuation.resume(with: result)
    }

    func resumePerformTransitionCall(
        for issueKey: String,
        with result: Result<Void, Error>
    ) {
        guard let continuation = controlledPerformTransitionContinuations.removeValue(forKey: issueKey) else {
            XCTFail("No controlled Jira transition POST for \(issueKey)")
            return
        }
        continuation.resume(with: result)
    }

    func resumeAddWorklogCall(
        _ call: Int,
        with result: Result<Void, Error>
    ) {
        guard let continuation = controlledAddWorklogContinuations.removeValue(forKey: call) else {
            XCTFail("No controlled Jira worklog POST for call \(call)")
            return
        }
        continuation.resume(with: result)
    }
}

@MainActor
final class ControlledJiraPollingSleeper {
    private(set) var callCount = 0
    private(set) var cancellationCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ interval: TimeInterval) async {
        callCount += 1
        let call = callCount
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[call] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancellationCount += 1
            }
        }
    }

    func resume(_ call: Int) {
        guard let continuation = continuations.removeValue(forKey: call) else {
            XCTFail("No controlled Jira polling sleep for call \(call)")
            return
        }
        continuation.resume()
    }

    func resumeAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
final class JiraStateRecorder {
    private(set) var states: [JiraProviderState] = []

    var latest: JiraProviderState? { states.last }

    func record(_ state: JiraProviderState) {
        states.append(state)
    }
}

extension JiraProject {
    static let appFixture = JiraProject(id: "100", key: "APP", name: "Application")
    static let webFixture = JiraProject(id: "200", key: "WEB", name: "Website")
}

extension JiraStatus {
    static let openFixture = JiraStatus(id: "1", name: "Open", categoryKey: "new")
    static let doneFixture = JiraStatus(id: "2", name: "Done", categoryKey: "done")
}

extension JiraIssue {
    static func fixture(
        id: String = "184",
        key: String = "APP-184",
        summary: String = "Provider lifecycle",
        projectKey: String = "APP",
        projectName: String = "Application",
        status: JiraStatus = .openFixture
    ) -> JiraIssue {
        JiraIssue(
            id: id,
            key: key,
            summary: summary,
            projectKey: projectKey,
            projectName: projectName,
            status: status,
            priorityName: "High",
            dueDate: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

extension JiraTransition {
    static let doneFixture = JiraTransition(id: "31", name: "Done", toStatus: .doneFixture)
}

extension JiraUser {
    static func fixture(displayName: String = "Jira User") -> JiraUser {
        JiraUser(displayName: displayName)
    }
}

extension JiraSearchPage {
    static let appFixture = JiraSearchPage(issues: [.fixture()], total: 1)

    static func fixture(issues: [JiraIssue]) -> JiraSearchPage {
        JiraSearchPage(issues: issues, total: issues.count)
    }
}

@MainActor
final class FakeJiraProvider: JiraProviding {
    var onChange: ((JiraProviderState) -> Void)?
    var checkResult: Result<JiraUser, JiraAPIError> = .success(
        .fixture(displayName: "Checked User")
    )
    var connectResult: Result<JiraUser, JiraAPIError> = .success(
        .fixture(displayName: "Connected User")
    )
    var addWorklogResult: Result<Void, JiraAPIError> = .success(())
    var assignResult: Result<Void, JiraAPIError> = .success(())

    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var visibilities: [Bool] = []
    private(set) var refreshCallCount = 0
    private(set) var checkedCredentials: [(baseURLText: String, token: String)] = []
    private(set) var connectedCredentials: [(baseURLText: String, token: String)] = []
    private(set) var disconnectCallCount = 0
    private(set) var selectedProjectKeySets: [Set<String>] = []
    private(set) var loadedTransitionIssueKeys: [String] = []
    private(set) var submittedTransitions: [(issueKey: String, transition: JiraTransition)] = []
    private(set) var assigneeSearches: [(issueKey: String, projectKey: String, query: String)] = []
    private(set) var assignments: [(issueKey: String, selection: JiraAssigneeSelection)] = []
    private(set) var submittedWorklogs: [(issueKey: String, draft: JiraWorklogDraft)] = []

    func start() { didStart = true }
    func stop() { didStop = true }

    func setVisible(_ isVisible: Bool) {
        guard visibilities.last != isVisible else { return }
        visibilities.append(isVisible)
    }

    func refresh() {
        refreshCallCount += 1
    }

    func checkConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        checkedCredentials.append((baseURLText, token))
        return checkResult
    }

    func connect(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        connectedCredentials.append((baseURLText, token))
        return connectResult
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func setSelectedProjectKeys(_ keys: Set<String>) {
        selectedProjectKeySets.append(keys)
    }

    func refreshPinnedCatalog() {}

    func togglePinnedContainer(_ container: JiraPinnedContainer) {}

    func movePinnedContainer(_ container: JiraPinnedContainer, by offset: Int) {}

    func pinIssue(key: String) async {}

    func removePinnedIssue(_ issue: JiraPinnedIssue) {}

    func movePinnedIssue(_ issue: JiraPinnedIssue, by offset: Int) {}

    func selectPinnedSource(_ source: JiraPinnedSourceID) {}

    func refreshPinnedSource() {}

    func loadTransitions(for issueKey: String) async {
        loadedTransitionIssueKeys.append(issueKey)
    }

    func performTransition(issueKey: String, transition: JiraTransition) async {
        submittedTransitions.append((issueKey, transition))
    }

    func searchAssignableUsers(
        issueKey: String,
        projectKey: String,
        query: String
    ) async {
        assigneeSearches.append((issueKey, projectKey, query))
    }

    func assign(
        issueKey: String,
        selection: JiraAssigneeSelection
    ) async -> Result<Void, JiraAPIError> {
        assignments.append((issueKey, selection))
        return assignResult
    }

    func addWorklog(
        issueKey: String,
        draft: JiraWorklogDraft
    ) async -> Result<Void, JiraAPIError> {
        submittedWorklogs.append((issueKey, draft))
        return addWorklogResult
    }

    func send(state: JiraProviderState) {
        onChange?(state)
    }
}

@MainActor
final class FakeCalendarProvider: CalendarProviding {
    var upcomingState: CalendarLoadState = .idle
    var eventsByMonth: [CalendarMonthKey: [CalendarEvent]] = [:]
    private(set) var loadUpcomingEventsCallCount = 0

    func loadUpcomingEvents() async -> CalendarLoadState {
        loadUpcomingEventsCallCount += 1
        return upcomingState
    }

    func loadEvents(for month: Date) async -> [CalendarEvent] {
        eventsByMonth[CalendarMonthKey(date: month)] ?? []
    }
}

@MainActor
final class FakeNowPlayingProvider: NowPlayingProviding {
    var onChange: ((NowPlayingSnapshot?) -> Void)?
    var onAccessStateChange: ((Bool) -> Void)?
    var onDiagnosticsChange: ((NowPlayingDiagnostics) -> Void)?
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var pollingModes: [NowPlayingPollingMode] = []

    func start() { didStart = true }
    func stop() { didStop = true }
    func refresh() {}
    func setPollingMode(_ mode: NowPlayingPollingMode) {
        guard pollingModes.last != mode else { return }
        pollingModes.append(mode)
    }
    func togglePlayPause() {}
    func previousTrack() {}
    func nextTrack() {}
    func seek(to time: TimeInterval) {}
    func openPlayer() {}

    func send(snapshot: NowPlayingSnapshot?) {
        onChange?(snapshot)
    }

    func send(requiresAccessibilityAccess: Bool) {
        onAccessStateChange?(requiresAccessibilityAccess)
    }

    func send(diagnostics: NowPlayingDiagnostics) {
        onDiagnosticsChange?(diagnostics)
    }
}

extension NowPlayingSnapshot {
    static func fixture(
        id: String = "fixture-id",
        title: String = "Track",
        elapsed: TimeInterval = 10,
        playbackState: NowPlayingPlaybackState = .playing,
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 1_000)
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            id: id,
            title: title,
            artist: "Artist",
            album: "Album",
            appName: "Player",
            artworkData: nil,
            duration: 180,
            elapsedTime: elapsed,
            playbackRate: playbackState.isPlaying ? 1 : 0,
            playbackState: playbackState,
            updatedAt: updatedAt
        )
    }
}
