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
    private var collapseTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var calendarMonthTask: Task<Void, Never>?
    private var hasLoadedCalendar = false
    private var cancellables = Set<AnyCancellable>()
    private let compactAgentSignalController: CompactAgentSignalController

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
        preferences: any AppPreferencesStoring = UserDefaultsAppPreferences()
    ) {
        self.providers = providers
        self.calendarProvider = calendarProvider
        self.nowPlayingProvider = nowPlayingProvider
        self.preferences = preferences
        self.aiSessionStore = aiSessionStore
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
            self.jiraState = state
            if case .loaded = state.list, state.list != previousList {
                self.jiraRefreshedAt = .now
            }
        }
        aiSessionStore.$sessions
            .sink { [weak self] sessions in
                guard let self else { return }
                self.aiSessions = sessions
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
                return aiSessionsUpdatedAt
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
        await jiraProvider.assign(issueKey: issueKey, selection: selection)
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
