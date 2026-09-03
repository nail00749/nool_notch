import AppKit
import Combine
import Foundation
import NotchCore

enum NotchTransientSurface: Hashable {
    case jiraFilters
    case jiraSearch
    case jiraWorklog(String)
    case jiraTransitions(String)
    case jiraAssignee(String)
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded = false {
        didSet {
            updateProviderActivity()
            if isExpanded, oldValue == false {
                refreshPanelBadges()
            }
        }
    }
    @Published private(set) var isContextMenuVisible = false
    @Published private(set) var activeTransientSurfaces: Set<NotchTransientSurface> = []
    @Published private(set) var transientSurfaceDismissalRequest = 0
    @Published var expandedContentVisible = false
    @Published private(set) var selectedPanel: PanelID
    @Published private(set) var panelOrder: [PanelID]
    @Published private(set) var hiddenPanelIDs: Set<PanelID>
    @Published private(set) var startupPanel: PanelID?
    @Published private(set) var selectedAISection: AISection
    @Published private(set) var aiSessions: [AISession] = []
    @Published private(set) var compactAgentSignal: CompactAgentSignal?
    @Published private(set) var aiSourceHealth: [String: AISessionSourceHealth] = [:]
    @Published private(set) var aiSessionsUpdatedAt: Date?
    @Published private(set) var respondingAISessionIDs: Set<AISessionID> = []
    @Published private(set) var aiResponseErrors: [AISessionID: String] = [:]
    @Published private(set) var aiJiraIssueKeys: [AISessionID: String] = [:]
    @Published private(set) var aiLinkedJiraIssues: [String: JiraIssue] = [:]
    @Published private(set) var aiLinkedJiraErrors: [String: JiraAPIError] = [:]
    @Published private(set) var aiLinkedJiraLoadingKeys: Set<String> = []
    @Published private(set) var codeReviewStates: [AISessionID: CodeReviewLoadState] = [:]
    @Published private(set) var newReviewActivityCounts: [AISessionID: Int] = [:]
    @Published private(set) var codeReviewsUpdatedAt: Date?
    @Published private(set) var hasCompletedPanelSwipe: Bool
    @Published private(set) var hoverExpansionDelay: TimeInterval
    @Published var calendarViewMode: CalendarViewMode = .list
    @Published private(set) var snapshots: [String: QuotaSnapshot]
    @Published private(set) var quotaProviderOrder: [String]
    @Published private(set) var hiddenQuotaProviderIDs: Set<String>
    @Published private(set) var compactQuotaProviderID: String
    @Published private(set) var calendarState: CalendarLoadState = .idle
    @Published private(set) var calendarEventsByMonth: [CalendarMonthKey: [CalendarEvent]] = [:]
    @Published private(set) var loadingCalendarMonth: CalendarMonthKey?
    @Published private(set) var nowPlayingSnapshot: NowPlayingSnapshot?
    @Published private(set) var nowPlayingRequiresAccessibilityAccess = false
    @Published private(set) var nowPlayingDiagnostics = NowPlayingDiagnostics.unavailable
    @Published private(set) var jiraState = JiraProviderState()
    @Published private(set) var calendarRefreshedAt: Date?
    @Published private(set) var jiraRefreshedAt: Date?
    @Published private(set) var isShowingSettings = false

    let providers: [any QuotaProvider]
    private let preferences: any AppPreferencesStoring
    private let calendarProvider: any CalendarProviding
    private let nowPlayingProvider: any NowPlayingProviding
    private let jiraProvider: any JiraProviding
    private let aiSessionStore: AISessionStore
    private let codeReviewProvider: any CodeReviewProviding
    private var collapseTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var calendarMonthTask: Task<Void, Never>?
    private var codeReviewTasks: [AISessionID: Task<Void, Never>] = [:]
    private var codeReviewGenerations: [AISessionID: UUID] = [:]
    private var codeReviewWorkspacePaths: [AISessionID: String] = [:]
    private var codeReviewPollingTask: Task<Void, Never>?
    private var reviewActivityBaselines: [AISessionID: (requestID: String, ids: Set<String>)] = [:]
    private var hasLoadedCalendar = false
    private var cancellables = Set<AnyCancellable>()
    private let compactAgentSignalController: CompactAgentSignalController
    let aiSourceNames: [String: String]

    init(
        providers: [any QuotaProvider] = [
            CodexQuotaProvider(),
            ClaudeQuotaProvider(),
            OllamaQuotaProvider()
        ],
        calendarProvider: any CalendarProviding = CalendarEventProvider(),
        nowPlayingProvider: any NowPlayingProviding = NowPlayingProvider(),
        jiraProvider: (any JiraProviding)? = nil,
        aiSessionStore: AISessionStore = AISessionStore(sources: []),
        codeReviewProvider: any CodeReviewProviding = LocalCodeReviewProvider(),
        preferences: any AppPreferencesStoring = UserDefaultsAppPreferences()
    ) {
        self.providers = providers
        self.calendarProvider = calendarProvider
        self.nowPlayingProvider = nowPlayingProvider
        self.preferences = preferences
        self.aiSessionStore = aiSessionStore
        self.codeReviewProvider = codeReviewProvider
        self.aiSourceNames = aiSessionStore.sourceNames
        self.jiraProvider = jiraProvider ?? JiraProvider(
            client: JiraClient(),
            credentialStore: KeychainJiraCredentialStore(),
            preferences: preferences
        )
        self.compactAgentSignalController = CompactAgentSignalController()
        let panelOrder = preferences.panelOrder
        let hiddenPanelIDs = preferences.hiddenPanelIDs
        let visiblePanels = panelOrder.filter { hiddenPanelIDs.contains($0) == false }
        let preferredPanel = preferences.startupPanel ?? preferences.lastSelectedPanel
        self.panelOrder = panelOrder
        self.hiddenPanelIDs = hiddenPanelIDs
        self.startupPanel = preferences.startupPanel
        self.selectedAISection = preferences.selectedAISection
        self.hasCompletedPanelSwipe = preferences.hasCompletedPanelSwipe
        self.selectedPanel = visiblePanels.contains(preferredPanel)
            ? preferredPanel
            : visiblePanels.first ?? .ai
        self.hoverExpansionDelay = preferences.hoverExpansionDelay
        let providerIDs = providers.map(\.id)
        let quotaProviderOrder = Self.normalizedQuotaProviderOrder(
            preferences.quotaProviderOrder,
            availableProviderIDs: providerIDs
        )
        var hiddenQuotaProviderIDs = preferences.hiddenQuotaProviderIDs
            .intersection(providerIDs)
        if hiddenQuotaProviderIDs.count >= providerIDs.count,
           let fallback = quotaProviderOrder.first {
            hiddenQuotaProviderIDs.remove(fallback)
        }
        let visibleQuotaProviderIDs = quotaProviderOrder.filter {
            hiddenQuotaProviderIDs.contains($0) == false
        }
        let preferredCompactProviderID = preferences.compactQuotaProviderID
        self.quotaProviderOrder = quotaProviderOrder
        self.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
        self.compactQuotaProviderID = visibleQuotaProviderIDs.contains(preferredCompactProviderID)
            ? preferredCompactProviderID
            : visibleQuotaProviderIDs.first ?? ""
        self.snapshots = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (
                provider.id,
                QuotaSnapshot.unavailable(
                    providerID: provider.id,
                    providerName: provider.displayName,
                    sourceURL: provider.sourceURL,
                    message: "Обновляю данные…"
                )
            )
        })
        preferences.quotaProviderOrder = quotaProviderOrder
        preferences.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
        preferences.compactQuotaProviderID = compactQuotaProviderID
        compactAgentSignalController.onChange = { [weak self] signal in
            self?.compactAgentSignal = signal
        }

        for provider in providers {
            guard let ollamaProvider = provider as? OllamaQuotaProvider else { continue }
            let providerID = ollamaProvider.id
            ollamaProvider.prepare { [weak self] in
                self?.refresh(providerID: providerID)
            }
        }

        nowPlayingProvider.onChange = { [weak self] snapshot in
            self?.nowPlayingSnapshot = snapshot
        }
        nowPlayingProvider.onAccessStateChange = { [weak self] requiresAccess in
            self?.nowPlayingRequiresAccessibilityAccess = requiresAccess
        }
        nowPlayingProvider.onDiagnosticsChange = { [weak self] diagnostics in
            self?.nowPlayingDiagnostics = diagnostics
        }
        self.jiraProvider.onChange = { [weak self] state in
            guard let self else { return }
            let previousList = self.jiraState.list
            let wasConfigured = self.isJiraConnectionConfigured(self.jiraState.connection)
            self.jiraState = state
            if case .loaded = state.list, state.list != previousList {
                self.jiraRefreshedAt = .now
            }
            if wasConfigured == false,
               self.isJiraConnectionConfigured(state.connection) {
                self.loadMissingAISessionJiraIssues(retryingFailures: true)
            }
        }
        aiSessionStore.$sessions
            .sink { [weak self] sessions in
                guard let self else { return }
                self.aiSessions = sessions
                self.updateAISessionJiraLinks(for: sessions)
                self.reconcileCodeReviews(for: sessions)
                self.compactAgentSignalController.consume(
                    sessions,
                    hasReceivedSnapshot: self.aiSessionStore.lastUpdatedAt != nil
                )
            }
            .store(in: &cancellables)
        aiSessionStore.$sourceHealth
            .sink { [weak self] health in self?.aiSourceHealth = health }
            .store(in: &cancellables)
        aiSessionStore.$lastUpdatedAt
            .sink { [weak self] date in self?.aiSessionsUpdatedAt = date }
            .store(in: &cancellables)
        updateProviderActivity()
        aiSessionStore.start()
        self.jiraProvider.start()
        nowPlayingProvider.start()
        refresh()
    }

    func snapshot(for providerID: String) -> QuotaSnapshot? {
        snapshots[providerID]
    }

    var orderedQuotaProviders: [any QuotaProvider] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        return quotaProviderOrder.compactMap { providersByID[$0] }
    }

    var visibleQuotaProviders: [any QuotaProvider] {
        orderedQuotaProviders.filter { hiddenQuotaProviderIDs.contains($0.id) == false }
    }

    var compactQuotaProviderName: String {
        providers.first(where: { $0.id == compactQuotaProviderID })?.displayName
            ?? "Лимит"
    }

    var compactWeeklyRemainingRatio: Double? {
        weeklyQuotaWindow(for: compactQuotaProviderID)?.remainingRatio
    }

    func canHideQuotaProvider(_ providerID: String) -> Bool {
        hiddenQuotaProviderIDs.contains(providerID) == false
            && visibleQuotaProviders.count > 1
    }

    func setQuotaProviderVisible(_ providerID: String, isVisible: Bool) {
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if isVisible {
            hiddenQuotaProviderIDs.remove(providerID)
            refresh(providerID: providerID)
        } else {
            guard canHideQuotaProvider(providerID) else { return }
            hiddenQuotaProviderIDs.insert(providerID)
            if compactQuotaProviderID == providerID,
               let fallback = visibleQuotaProviders.first {
                compactQuotaProviderID = fallback.id
                preferences.compactQuotaProviderID = fallback.id
            }
        }
        preferences.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
    }

    func moveQuotaProvider(_ providerID: String, by offset: Int) {
        guard let sourceIndex = quotaProviderOrder.firstIndex(of: providerID) else { return }
        let destinationIndex = sourceIndex + offset
        guard quotaProviderOrder.indices.contains(destinationIndex) else { return }
        quotaProviderOrder.swapAt(sourceIndex, destinationIndex)
        preferences.quotaProviderOrder = quotaProviderOrder
    }

    func setCompactQuotaProvider(_ providerID: String) {
        guard visibleQuotaProviders.contains(where: { $0.id == providerID }) else { return }
        compactQuotaProviderID = providerID
        preferences.compactQuotaProviderID = providerID
    }

    func canBeginAuthentication(for providerID: String) -> Bool {
        providers.first(where: { $0.id == providerID }) is any QuotaProviderAuthenticating
    }

    func refreshAllQuotaProviders() {
        refresh()
    }

    func selectPanel(_ panel: PanelID) {
        guard visiblePanels.contains(panel) else { return }
        selectedPanel = panel
        preferences.lastSelectedPanel = panel
        updateProviderActivity()
    }

    func selectAISection(_ section: AISection) {
        selectedAISection = section
        preferences.selectedAISection = section
        updateProviderActivity()
        if section == .sessions {
            refreshCodeReviews()
        }
    }

    var codeReviewSessions: [AISession] {
        let repositories = aiSessions.filter { $0.workspacePath?.isEmpty == false }
        let ordered = repositories.filter(\.status.isActive)
            + repositories.filter { $0.status.isActive == false }.prefix(3)
        var seenWorkspaces: Set<String> = []
        return ordered.filter { session in
            guard let workspacePath = session.workspacePath else { return false }
            return seenWorkspaces.insert(workspacePath).inserted
        }
    }

    func codeReviewState(for session: AISession) -> CodeReviewLoadState {
        if let direct = codeReviewStates[session.id] {
            return direct
        }
        guard let representativeID = codeReviewRepresentativeID(for: session) else {
            return .idle
        }
        return codeReviewStates[representativeID] ?? .idle
    }

    func newReviewActivityCount(for session: AISession) -> Int {
        if let direct = newReviewActivityCounts[session.id] {
            return direct
        }
        guard let representativeID = codeReviewRepresentativeID(for: session) else {
            return 0
        }
        return newReviewActivityCounts[representativeID, default: 0]
    }

    func refreshCodeReviews() {
        for session in codeReviewSessions {
            refreshCodeReview(for: session)
        }
    }

    func openCodeReview(_ request: CodeReviewRequest, for session: AISession) {
        acknowledgeReviewActivity(for: session)
        NSWorkspace.shared.open(request.url)
    }

    var aiAttentionCount: Int {
        aiSessions.filter { $0.status.needsAttention }.count
    }

    func openAISession(_ session: AISession) {
        Task { @MainActor [weak self] in
            guard let self, await self.aiSessionStore.open(session) else { return }
            self.isExpanded = false
        }
    }

    func respondToAISession(_ session: AISession, response: AISessionResponse) {
        guard let request = session.attentionRequest,
              respondingAISessionIDs.contains(session.id) == false else { return }
        respondingAISessionIDs.insert(session.id)
        aiResponseErrors.removeValue(forKey: session.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.aiSessionStore.respond(
                to: session,
                requestID: request.id,
                response: response
            )
            self.respondingAISessionIDs.remove(session.id)
            if succeeded == false {
                self.aiResponseErrors[session.id] = "Не удалось отправить ответ. Открой задачу в Codex."
            }
        }
    }

    func aiSourceName(for session: AISession) -> String {
        if session.id.sourceID == "local-agents" {
            return session.agentName
        }
        return aiSourceNames[session.id.sourceID] ?? session.agentName
    }

    func jiraIssueKey(for session: AISession) -> String? {
        aiJiraIssueKeys[session.id]
    }

    func linkedJiraIssue(for session: AISession) -> JiraIssue? {
        jiraIssueKey(for: session).flatMap { aiLinkedJiraIssues[$0] }
    }

    func linkedJiraError(for session: AISession) -> JiraAPIError? {
        jiraIssueKey(for: session).flatMap { aiLinkedJiraErrors[$0] }
    }

    func isLinkedJiraIssueLoading(for session: AISession) -> Bool {
        jiraIssueKey(for: session).map(aiLinkedJiraLoadingKeys.contains) ?? false
    }

    func retryLinkedJiraIssue(for session: AISession) {
        guard let key = jiraIssueKey(for: session) else { return }
        Task { await loadLinkedJiraIssue(key: key, force: true) }
    }

    func openJiraIssue(_ issue: JiraIssue) {
        guard let baseURL = configuredJiraBaseURLString,
              let url = issue.browserURL(baseURL: baseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    var visiblePanels: [PanelID] {
        panelOrder.filter { hiddenPanelIDs.contains($0) == false }
    }

    var visibleCompactAgentSignal: CompactAgentSignal? {
        visiblePanels.contains(.ai) ? compactAgentSignal : nil
    }

    func openCompactAgentSessions() {
        guard let signal = visibleCompactAgentSignal else { return }
        compactAgentSignalController.acknowledge(signal)
        cancelScheduledCollapse()
        selectPanel(.ai)
        selectAISection(.sessions)
        isExpanded = true
    }

    func canHidePanel(_ panel: PanelID) -> Bool {
        visiblePanels.contains(panel) && visiblePanels.count > 1
    }

    func setPanelVisible(_ panel: PanelID, isVisible: Bool) {
        if isVisible {
            hiddenPanelIDs.remove(panel)
        } else {
            guard canHidePanel(panel) else { return }
            hiddenPanelIDs.insert(panel)
            if startupPanel == panel {
                startupPanel = nil
                preferences.startupPanel = nil
            }
            if selectedPanel == panel, let fallback = visiblePanels.first {
                selectedPanel = fallback
                preferences.lastSelectedPanel = fallback
            }
        }
        preferences.hiddenPanelIDs = hiddenPanelIDs
        updateProviderActivity()
    }

    func movePanel(_ panel: PanelID, by offset: Int) {
        guard let sourceIndex = panelOrder.firstIndex(of: panel) else { return }
        let destinationIndex = sourceIndex + offset
        guard panelOrder.indices.contains(destinationIndex) else { return }
        panelOrder.swapAt(sourceIndex, destinationIndex)
        preferences.panelOrder = panelOrder
    }

    func setStartupPanel(_ panel: PanelID?) {
        guard panel == nil || panel.map(visiblePanels.contains) == true else { return }
        startupPanel = panel
        preferences.startupPanel = panel
    }

    func acknowledgePanelSwipe() {
        guard hasCompletedPanelSwipe == false else { return }
        hasCompletedPanelSwipe = true
        preferences.hasCompletedPanelSwipe = true
    }

    func lastUpdatedAt(for panel: PanelID) -> Date? {
        switch panel {
        case .ai:
            if selectedAISection == .sessions {
                return [aiSessionsUpdatedAt, codeReviewsUpdatedAt]
                    .compactMap { $0 }
                    .max()
            }
            return visibleQuotaProviders.compactMap { snapshots[$0.id] }
                .filter { $0.connection != .unavailable }
                .map(\.updatedAt)
                .max()
        case .calendar:
            return calendarRefreshedAt
        case .music:
            return nowPlayingDiagnostics.lastSuccessfulUpdate ?? nowPlayingSnapshot?.updatedAt
        case .jira:
            return jiraRefreshedAt
        }
    }

    func numericBadgeCount(
        for panel: PanelID,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int? {
        switch panel {
        case .ai:
            if aiAttentionCount > 0 { return aiAttentionCount }
            let newReviewActivity = newReviewActivityCounts.values.reduce(0, +)
            if newReviewActivity > 0 { return newReviewActivity }
            return visibleQuotaProviders.compactMap { snapshots[$0.id] }
                .flatMap(\.windows)
                .filter { ($0.remainingRatio ?? 1) < 0.2 }
                .count
        case .calendar:
            guard case .loaded(let snapshot) = calendarState else { return 0 }
            return snapshot.upcomingEvents.filter {
                calendar.isDate($0.startDate, inSameDayAs: now)
            }.count
        case .music:
            return nil
        case .jira:
            switch jiraState.list {
            case .loaded(let issues, _):
                return issues.count
            case .loading(let previous), .failed(_, let previous):
                return previous?.count ?? 0
            case .idle:
                return 0
            }
        }
    }

    func setHoverExpansionDelay(_ delay: TimeInterval) {
        let normalized = NotchHoverPolicy.expansionDelay(configuredDelay: delay)
        hoverExpansionDelay = normalized
        preferences.hoverExpansionDelay = normalized
    }

    func showSettings() {
        guard isShowingSettings == false else { return }
        isShowingSettings = true
        updateProviderActivity()
    }

    func hideSettings() {
        guard isShowingSettings else { return }
        isShowingSettings = false
        updateProviderActivity()
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func cancelScheduledCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    var isTransientSurfaceVisible: Bool {
        isContextMenuVisible || activeTransientSurfaces.isEmpty == false
    }

    func transientSurfaceDidPresent(_ surface: NotchTransientSurface) {
        activeTransientSurfaces.insert(surface)
        cancelScheduledCollapse()
    }

    func transientSurfaceDidDisappear(_ surface: NotchTransientSurface) {
        activeTransientSurfaces.remove(surface)
    }

    func scheduleCollapse(
        after delay: TimeInterval = NotchHoverPolicy.collapseGracePeriod,
        onlyIf shouldCollapse: @escaping @MainActor () -> Bool = { true }
    ) {
        cancelScheduledCollapse()
        collapseTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard shouldCollapse() else {
                self?.collapseTask = nil
                return
            }
            guard self?.isTransientSurfaceVisible == false else {
                self?.transientSurfaceDismissalRequest += 1
                self?.collapseTask = nil
                return
            }
            self?.isExpanded = false
            self?.collapseTask = nil
        }
    }

    func contextMenuDidBeginTracking() {
        isContextMenuVisible = true
        cancelScheduledCollapse()
    }

    func contextMenuDidEndTracking() {
        isContextMenuVisible = false
        scheduleCollapse()
    }

    func refresh() {
        for provider in visibleQuotaProviders {
            refresh(provider: provider)
        }
    }

    func loadCalendarIfNeeded() {
        guard hasLoadedCalendar == false else { return }
        refreshCalendar()
    }

    func refreshCalendar() {
        hasLoadedCalendar = true
        calendarTask?.cancel()
        calendarMonthTask?.cancel()
        calendarEventsByMonth.removeAll()
        loadingCalendarMonth = nil
        calendarState = .loading
        calendarTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.calendarProvider.loadUpcomingEvents()
            guard Task.isCancelled == false else { return }
            self.calendarState = state
            if case .loaded(let snapshot) = state {
                self.calendarEventsByMonth[CalendarMonthKey(date: Date())] = snapshot.monthEvents
                self.calendarRefreshedAt = .now
            }
            self.calendarTask = nil
        }
    }

    func refreshNowPlaying() {
        nowPlayingProvider.refresh()
    }

    func nowPlayingTogglePlayPause() {
        nowPlayingProvider.togglePlayPause()
    }

    func nowPlayingPreviousTrack() {
        nowPlayingProvider.previousTrack()
    }

    func nowPlayingNextTrack() {
        nowPlayingProvider.nextTrack()
    }

    func nowPlayingSeek(to time: TimeInterval) {
        nowPlayingProvider.seek(to: time)
    }

    func openNowPlayingApplication() {
        nowPlayingProvider.openPlayer()
    }

    var configuredJiraBaseURLString: String? {
        preferences.jiraBaseURLString
    }

    func checkJiraConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        await jiraProvider.checkConnection(baseURLText: baseURLText, token: token)
    }

    func connectJira(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        await jiraProvider.connect(baseURLText: baseURLText, token: token)
    }

    func disconnectJira() {
        jiraProvider.disconnect()
    }

    func refreshJira() {
        jiraProvider.refresh()
    }

    func setJiraSelectedProjectKeys(_ keys: Set<String>) {
        jiraProvider.setSelectedProjectKeys(keys)
    }

    func refreshJiraPinnedCatalog() {
        jiraProvider.refreshPinnedCatalog()
    }

    func toggleJiraPinnedContainer(_ container: JiraPinnedContainer) {
        jiraProvider.togglePinnedContainer(container)
    }

    func moveJiraPinnedContainer(_ container: JiraPinnedContainer, by offset: Int) {
        jiraProvider.movePinnedContainer(container, by: offset)
    }

    func pinJiraIssue(key: String) async {
        await jiraProvider.pinIssue(key: key)
    }

    func removeJiraPinnedIssue(_ issue: JiraPinnedIssue) {
        jiraProvider.removePinnedIssue(issue)
    }

    func moveJiraPinnedIssue(_ issue: JiraPinnedIssue, by offset: Int) {
        jiraProvider.movePinnedIssue(issue, by: offset)
    }

    func selectJiraPinnedSource(_ source: JiraPinnedSourceID) {
        jiraProvider.selectPinnedSource(source)
    }

    func refreshJiraPinnedSource() {
        jiraProvider.refreshPinnedSource()
    }

    func loadJiraTransitions(for issueKey: String) async {
        await jiraProvider.loadTransitions(for: issueKey)
    }

    func submitJiraTransition(issueKey: String, transition: JiraTransition) async {
        await jiraProvider.performTransition(issueKey: issueKey, transition: transition)
        await loadLinkedJiraIssue(key: issueKey, force: true)
    }

    func searchJiraAssignees(
        issueKey: String,
        projectKey: String,
        query: String
    ) async {
        await jiraProvider.searchAssignableUsers(
            issueKey: issueKey,
            projectKey: projectKey,
            query: query
        )
    }

    func assignJiraIssue(
        issueKey: String,
        selection: JiraAssigneeSelection
    ) async -> Result<Void, JiraAPIError> {
        let result = await jiraProvider.assign(issueKey: issueKey, selection: selection)
        if case .success = result {
            await loadLinkedJiraIssue(key: issueKey, force: true)
        }
        return result
    }

    func submitJiraWorklog(
        issueKey: String,
        draft: JiraWorklogDraft
    ) async -> Result<Void, JiraAPIError> {
        await jiraProvider.addWorklog(issueKey: issueKey, draft: draft)
    }

    func calendarEvents(for month: Date) -> [CalendarEvent] {
        calendarEventsByMonth[CalendarMonthKey(date: month)] ?? []
    }

    func loadCalendarMonthIfNeeded(for month: Date) {
        guard case .loaded = calendarState else { return }

        let monthKey = CalendarMonthKey(date: month)
        guard calendarEventsByMonth[monthKey] == nil else { return }

        calendarMonthTask?.cancel()
        loadingCalendarMonth = monthKey
        calendarMonthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let events = await self.calendarProvider.loadEvents(for: month)
            guard Task.isCancelled == false else { return }
            self.calendarEventsByMonth[monthKey] = events
            if self.loadingCalendarMonth == monthKey {
                self.loadingCalendarMonth = nil
            }
            self.calendarMonthTask = nil
        }
    }

    func beginAuthentication(for providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) as? any QuotaProviderAuthenticating else {
            return
        }

        provider.beginAuthentication { [weak self] in
            self?.refresh(providerID: providerID)
        }
    }

    private func refresh(provider: any QuotaProvider) {
        Task { @MainActor [weak self] in
            let snapshot = await provider.loadSnapshot()
            self?.snapshots[provider.id] = snapshot
        }
    }

    private func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return
        }
        refresh(provider: provider)
    }

    private func updateAISessionJiraLinks(for sessions: [AISession]) {
        aiJiraIssueKeys = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            AISessionJiraLink.issueKey(for: session).map { (session.id, $0) }
        })

        let visibleKeys = Set(aiJiraIssueKeys.values)
        aiLinkedJiraIssues = aiLinkedJiraIssues.filter { visibleKeys.contains($0.key) }
        aiLinkedJiraErrors = aiLinkedJiraErrors.filter { visibleKeys.contains($0.key) }
        aiLinkedJiraLoadingKeys.formIntersection(visibleKeys)
        loadMissingAISessionJiraIssues(retryingFailures: false)
    }

    private func loadMissingAISessionJiraIssues(retryingFailures: Bool) {
        for key in Set(aiJiraIssueKeys.values) {
            guard aiLinkedJiraIssues[key] == nil,
                  aiLinkedJiraLoadingKeys.contains(key) == false,
                  retryingFailures || aiLinkedJiraErrors[key] == nil else { continue }
            Task { await loadLinkedJiraIssue(key: key, force: retryingFailures) }
        }
    }

    private func loadLinkedJiraIssue(key: String, force: Bool) async {
        guard force || aiLinkedJiraIssues[key] == nil,
              aiLinkedJiraLoadingKeys.contains(key) == false else { return }
        aiLinkedJiraLoadingKeys.insert(key)
        aiLinkedJiraErrors.removeValue(forKey: key)
        let result = await jiraProvider.issue(key: key)
        aiLinkedJiraLoadingKeys.remove(key)
        switch result {
        case .success(let issue):
            aiLinkedJiraIssues[key] = issue
            aiLinkedJiraErrors.removeValue(forKey: key)
        case .failure(let error):
            aiLinkedJiraErrors[key] = error
        }
    }

    private func isJiraConnectionConfigured(_ connection: JiraConnectionState) -> Bool {
        switch connection {
        case .ready, .connected, .validated:
            true
        case .notConfigured, .validating, .failed:
            false
        }
    }

    private func weeklyQuotaWindow(for providerID: String) -> QuotaWindow? {
        guard let windows = snapshots[providerID]?.windows else { return nil }
        return windows.first {
            $0.label == "7d" && $0.unit == .percentage
        } ?? windows.first {
            $0.label.hasSuffix("· 7d") && $0.unit == .percentage
        }
    }

    private static func normalizedQuotaProviderOrder(
        _ preferredOrder: [String],
        availableProviderIDs: [String]
    ) -> [String] {
        let available = Set(availableProviderIDs)
        var seen: Set<String> = []
        let known = preferredOrder.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        return known + availableProviderIDs.filter { seen.insert($0).inserted }
    }

    private func updateProviderActivity() {
        let mode: NowPlayingPollingMode = isExpanded
            && selectedPanel == .music
            && isShowingSettings == false
            ? .visibleMusic
            : .background
        nowPlayingProvider.setPollingMode(mode)

        jiraProvider.setVisible(
            isExpanded
                && visiblePanels.contains(.jira)
                && isShowingSettings == false
        )

        let showsCodeReviews = isExpanded
            && selectedPanel == .ai
            && selectedAISection == .sessions
            && isShowingSettings == false
        if showsCodeReviews {
            if codeReviewPollingTask == nil {
                refreshCodeReviews()
                codeReviewPollingTask = Task { @MainActor [weak self] in
                    while Task.isCancelled == false {
                        try? await Task.sleep(for: .seconds(30))
                        guard Task.isCancelled == false else { return }
                        self?.refreshCodeReviews()
                    }
                }
            }
        } else {
            codeReviewPollingTask?.cancel()
            codeReviewPollingTask = nil
            for task in codeReviewTasks.values {
                task.cancel()
            }
            codeReviewTasks.removeAll()
            codeReviewGenerations.removeAll()
        }
    }

    private func refreshCodeReview(for session: AISession) {
        guard let workspacePath = session.workspacePath,
              workspacePath.isEmpty == false,
              codeReviewTasks[session.id] == nil else { return }
        let previous = codeReviewStates[session.id]?.snapshot
        codeReviewStates[session.id] = .loading(previous: previous)
        codeReviewWorkspacePaths[session.id] = workspacePath
        let generation = UUID()
        codeReviewGenerations[session.id] = generation
        codeReviewTasks[session.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.codeReviewProvider.load(workspacePath: workspacePath)
            guard self.codeReviewGenerations[session.id] == generation else { return }
            self.codeReviewTasks[session.id] = nil
            self.codeReviewGenerations[session.id] = nil
            guard Task.isCancelled == false,
                  self.aiSessions.contains(where: {
                      $0.id == session.id
                          && $0.workspacePath == workspacePath
                  }) else { return }
            switch result {
            case .success(let snapshot):
                self.recordReviewActivity(snapshot.request, for: session.id)
                self.codeReviewStates[session.id] = .loaded(snapshot)
                self.codeReviewsUpdatedAt = .now
            case .failure(let error):
                self.codeReviewStates[session.id] = .failed(error, previous: previous)
            }
        }
    }

    private func recordReviewActivity(_ request: CodeReviewRequest?, for sessionID: AISessionID) {
        guard let request else {
            reviewActivityBaselines.removeValue(forKey: sessionID)
            newReviewActivityCounts.removeValue(forKey: sessionID)
            return
        }
        guard let baseline = reviewActivityBaselines[sessionID], baseline.requestID == request.id else {
            reviewActivityBaselines[sessionID] = (request.id, request.reviewerActivityIDs)
            newReviewActivityCounts[sessionID] = 0
            return
        }
        let newIDs = request.reviewerActivityIDs.subtracting(baseline.ids)
        if newIDs.isEmpty == false {
            newReviewActivityCounts[sessionID, default: 0] += newIDs.count
        }
        reviewActivityBaselines[sessionID] = (
            request.id,
            baseline.ids.union(request.reviewerActivityIDs)
        )
    }

    private func acknowledgeReviewActivity(for session: AISession) {
        let representativeID = codeReviewRepresentativeID(for: session) ?? session.id
        newReviewActivityCounts[representativeID] = 0
    }

    private func codeReviewRepresentativeID(for session: AISession) -> AISessionID? {
        guard let workspacePath = session.workspacePath else { return nil }
        return codeReviewSessions.first {
            $0.workspacePath == workspacePath
        }?.id
    }

    private func reconcileCodeReviews(for sessions: [AISession]) {
        let visibleSessions = codeReviewSessions
        let visibleIDs = Set(visibleSessions.map(\.id))
        for id in Array(codeReviewStates.keys) where visibleIDs.contains(id) == false {
            codeReviewTasks[id]?.cancel()
            codeReviewTasks.removeValue(forKey: id)
            codeReviewGenerations.removeValue(forKey: id)
            codeReviewStates.removeValue(forKey: id)
            codeReviewWorkspacePaths.removeValue(forKey: id)
            reviewActivityBaselines.removeValue(forKey: id)
            newReviewActivityCounts.removeValue(forKey: id)
        }

        for session in visibleSessions {
            guard let workspacePath = session.workspacePath, workspacePath.isEmpty == false else {
                continue
            }
            guard let loadedPath = codeReviewWorkspacePaths[session.id],
                  loadedPath != workspacePath else { continue }
            codeReviewTasks[session.id]?.cancel()
            codeReviewTasks.removeValue(forKey: session.id)
            codeReviewGenerations.removeValue(forKey: session.id)
            codeReviewStates.removeValue(forKey: session.id)
            codeReviewWorkspacePaths.removeValue(forKey: session.id)
            reviewActivityBaselines.removeValue(forKey: session.id)
            newReviewActivityCounts.removeValue(forKey: session.id)
        }
        if isExpanded,
           selectedPanel == .ai,
           selectedAISection == .sessions,
           isShowingSettings == false {
            for session in visibleSessions where codeReviewStates[session.id] == nil {
                refreshCodeReview(for: session)
            }
        }
    }

    private func refreshPanelBadges() {
        refresh()
        if visiblePanels.contains(.calendar) {
            refreshCalendar()
        }
        if visiblePanels.contains(.music) {
            refreshNowPlaying()
        }
    }
}
