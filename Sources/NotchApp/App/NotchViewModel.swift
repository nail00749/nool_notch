import AppKit
import Combine
import Foundation
import NotchCore

enum NotchTransientSurface: Hashable {
    case scratchpadExport
    case recentCapturesFolderPicker
    case jiraFilters
    case jiraSearch
    case jiraWorklog(String)
    case jiraTransitions(String)
    case jiraAssignee(String)

    var utilityModule: AppModuleID? {
        switch self {
        case .scratchpadExport: .scratchpad
        case .recentCapturesFolderPicker: .recentCaptures
        default: nil
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isCompactHovered = false {
        didSet {
            if isCompactHovered, oldValue == false {
                refreshQuotaProviders(ifOlderThan: 10)
            }
        }
    }
    @Published private(set) var activeUtility: NotchUtilityPanel? {
        didSet {
            if oldValue == .scratchpad, activeUtility != .scratchpad { scratchpad.setActive(false) }
            if oldValue == .recentCaptures, activeUtility != .recentCaptures { recentCaptures.setActive(false) }
            if activeUtility != nil { musicLyrics.deactivate() }
            if activeUtility != nil { musicQueue.setActive(false) }
        }
    }
    let scratchpad = ScratchpadStore()
    let recentCaptures: RecentCapturesStore
    let musicLyrics: MusicLyricsStore
    let musicQueue: YandexMusicQueueStore
    @Published var isFileDropTargeted = false
    @Published private(set) var isChoosingShelfFiles = false
    let fileShelfStore = FileShelfStore()
    var onOpenFileActions: (([URL]) -> Void)?
    var onRecognizeText: (([URL]) -> Void)?

    func recognizeText(_ urls: [URL]) {
        guard modules.isEnabled(.fileShelf), modules.isEnabled(.textRecognition) else { return }
        onRecognizeText?(urls)
    }

    func openFileActions(_ urls: [URL]) {
        guard modules.isEnabled(.fileShelf), !urls.isEmpty else { return }
        onOpenFileActions?(urls)
    }
    @Published var isExpanded = false {
        didSet {
            if isExpanded == false {
                activeUtility = nil
                isExpansionPinned = false
                hasRequestedCollapse = false
                cancelScheduledCollapse()
            }
            updateProviderActivity()
            if isExpanded, oldValue == false {
                refreshQuotaProviders(ifOlderThan: 10)
                refreshPanelBadges()
            }
        }
    }
    @Published private(set) var isExpansionPinned = false
    private var hasRequestedCollapse = false
    @Published private(set) var isContextMenuVisible = false
    @Published private(set) var activeTransientSurfaces: Set<NotchTransientSurface> = []
    @Published private(set) var transientSurfaceDismissalRequest = 0
    @Published var expandedContentVisible = false
    // Set by the coordinator after the SwiftUI viewport animation completes.
    @Published var expansionSurfaceSettled = false
    @Published private(set) var selectedPanel: PanelID
    @Published private(set) var panelOrder: [PanelID]
    @Published private(set) var hiddenPanelIDs: Set<PanelID>
    @Published private(set) var startupPanel: PanelID?
    @Published private(set) var opensOverviewOnExpansion: Bool
    @Published private(set) var selectedAISection: AISection
    @Published private(set) var aiSessions: [AISession] = []
    @Published private(set) var compactAgentSignal: CompactAgentSignal?
    @Published private(set) var compactMascotPresentation: CompactMascotPresentation?
    private var compactMascotBatch = CompactMascotBatch()
    private var compactMascotExpiryTask: Task<Void, Never>?
    @Published private(set) var aiSourceHealth: [String: AISessionSourceHealth] = [:]
    @Published private(set) var aiSessionsUpdatedAt: Date?
    @Published private(set) var respondingAISessionIDs: Set<AISessionID> = []
    @Published private(set) var aiResponseErrors: [AISessionID: String] = [:]
    @Published private(set) var aiJiraIssueKeys: [AISessionID: String] = [:]
    @Published private(set) var aiLinkedJiraIssues: [String: JiraIssue] = [:]
    @Published private(set) var aiLinkedJiraErrors: [String: JiraAPIError] = [:]
    @Published private(set) var aiLinkedJiraLoadingKeys: Set<String> = []
    var codeReviewStates: [AISessionID: CodeReviewLoadState] { codeReviews.codeReviewStates }
    var newReviewActivityCounts: [AISessionID: Int] { codeReviews.newReviewActivityCounts }
    var codeReviewsUpdatedAt: Date? { codeReviews.codeReviewsUpdatedAt }
    @Published private(set) var hasCompletedPanelSwipe: Bool
    @Published private(set) var hoverExpansionDelay: TimeInterval
    @Published var calendarViewMode: CalendarViewMode = .list
    var snapshots: [String: QuotaSnapshot] { modules.isEnabled(.quotas) ? quotas.snapshots : [:] }
    var quotaProviderOrder: [String] { quotas.quotaProviderOrder }
    var hiddenQuotaProviderIDs: Set<String> { quotas.hiddenQuotaProviderIDs }
    var compactQuotaProviderID: String { quotas.compactQuotaProviderID }
    var compactQuotaDisplayMode: CompactQuotaDisplayMode { quotas.compactQuotaDisplayMode }
    var quotaPanelEdge: QuotaPanelEdge { quotas.quotaPanelEdge }
    var quotaStackCorner: QuotaStackCorner { quotas.quotaStackCorner }
    var calendarState: CalendarLoadState { modules.isEnabled(.calendar) ? calendar.calendarState : .idle }
    var upcomingMeetingReminder: MeetingReminder? { modules.isEnabled(.calendar) ? calendar.upcomingMeetingReminder : nil }
    private var dockMusicVisible = false
    private var dockCalendarEnabled = false
    var calendarEventsByMonth: [CalendarMonthKey: [CalendarEvent]] { modules.isEnabled(.calendar) ? calendar.calendarEventsByMonth : [:] }
    var loadingCalendarMonth: CalendarMonthKey? { calendar.loadingCalendarMonth }
    @Published private(set) var nowPlayingSnapshot: NowPlayingSnapshot?
    @Published private(set) var nowPlayingRequiresAccessibilityAccess = false
    @Published private(set) var nowPlayingDiagnostics = NowPlayingDiagnostics.unavailable
    @Published private(set) var liveActivities: [LiveActivity] = []
    @Published private(set) var liveActivitiesUpdatedAt: Date?
    @Published var selectedCompactActivityID: String?
    @Published private(set) var jiraState = JiraProviderState()
    var calendarRefreshedAt: Date? { calendar.calendarRefreshedAt }
    @Published private(set) var jiraRefreshedAt: Date?
    @Published private(set) var isShowingSettings = false

    private let quotas: QuotaFeatureModel
    let modules: AppModuleStore
    private let moduleRuntime: AppModuleRuntime
    var quotaAlerts: QuotaAlertController? { quotas.alerts }
    var providers: [any QuotaProvider] { quotas.providers }
    private let preferences: any AppPreferencesStoring
    private let calendar: CalendarFeatureModel
    private let nowPlayingProvider: any NowPlayingProviding
    private let liveActivityCenter: LiveActivityCenter
    private let jiraProvider: any JiraProviding
    private let aiSessionStore: AISessionStore
    private let codeReviews: CodeReviewStore
    let aiUsage = AIUsageStore()
    private var isStopped = false
    private var collapseTask: Task<Void, Never>?
    private var linkedJiraGeneration: UInt = 0
    private var aiResponseGeneration: UInt = 0
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
        liveActivityCenter: LiveActivityCenter = LiveActivityCenter(),
        jiraProvider: (any JiraProviding)? = nil,
        aiSessionStore: AISessionStore = AISessionStore(sources: []),
        codeReviewProvider: any CodeReviewProviding = LocalCodeReviewProvider(),
        preferences: any AppPreferencesStoring = UserDefaultsAppPreferences(),
        now: @escaping @MainActor () -> Date = Date.init,
        widgetPublisher: QuotaWidgetPublisher? = nil,
        quotaAlerts: QuotaAlertController? = nil,
        modules: AppModuleStore? = nil,
        recentCaptures: RecentCapturesStore? = nil,
        musicLyrics: MusicLyricsStore? = nil,
        musicQueue: YandexMusicQueueStore? = nil
    ) {
        let moduleStore = modules ?? AppModuleStore(defaults: nil)
        self.modules = moduleStore
        self.recentCaptures = recentCaptures ?? RecentCapturesStore()
        self.musicLyrics = musicLyrics ?? MusicLyricsStore()
        self.musicQueue = musicQueue ?? YandexMusicQueueStore()
        self.moduleRuntime = AppModuleRuntime(store: moduleStore)
        self.quotas = QuotaFeatureModel(providers: providers, preferences: preferences, now: now,
                                      widgetPublisher: widgetPublisher, alerts: quotaAlerts,
                                      startsActive: false,
                                      clearWidgetWhenInactive: !moduleStore.isEnabled(.quotas))
        self.calendar = CalendarFeatureModel(provider: calendarProvider)
        self.nowPlayingProvider = nowPlayingProvider
        self.liveActivityCenter = liveActivityCenter
        self.preferences = preferences
        self.aiSessionStore = aiSessionStore
        self.codeReviews = CodeReviewStore(provider: codeReviewProvider)
        self.aiSourceNames = aiSessionStore.sourceNames
        self.jiraProvider = jiraProvider ?? JiraProvider(
            client: JiraClient(),
            credentialStore: KeychainJiraCredentialStore(),
            preferences: preferences
        )
        self.compactAgentSignalController = CompactAgentSignalController()
        let panelOrder = preferences.panelOrder
        let hiddenPanelIDs = preferences.hiddenPanelIDs
        let visiblePanels = panelOrder.filter {
            hiddenPanelIDs.contains($0) == false && Self.isPanelAvailable($0, in: moduleStore)
        }
        let preferredPanel = preferences.startupPanel ?? preferences.lastSelectedPanel
        self.panelOrder = panelOrder
        self.hiddenPanelIDs = hiddenPanelIDs
        self.startupPanel = preferences.startupPanel
        self.opensOverviewOnExpansion = preferences.opensOverviewOnExpansion
        self.selectedAISection = preferences.selectedAISection
        self.hasCompletedPanelSwipe = preferences.hasCompletedPanelSwipe
        self.selectedPanel = visiblePanels.contains(preferredPanel)
            ? preferredPanel
            : visiblePanels.first ?? .ai
        self.hoverExpansionDelay = preferences.hoverExpansionDelay
        compactAgentSignalController.onChange = { [weak self] signal in
            self?.compactAgentSignal = signal
            self?.refreshCompactMascot()
        }

        nowPlayingProvider.onChange = { [weak self] snapshot in
            guard let self, self.modules.isEnabled(.music) else { return }
            self.nowPlayingSnapshot = snapshot
            self.musicLyrics.updateTrack(snapshot)
            self.musicQueue.updateTrack(snapshot)
        }
        nowPlayingProvider.onAccessStateChange = { [weak self] requiresAccess in
            guard let self, self.modules.isEnabled(.music) else { return }
            self.nowPlayingRequiresAccessibilityAccess = requiresAccess
        }
        nowPlayingProvider.onDiagnosticsChange = { [weak self] diagnostics in
            guard let self, self.modules.isEnabled(.music) else { return }
            self.nowPlayingDiagnostics = diagnostics
        }
        liveActivityCenter.$activities
            .sink { [weak self] activities in
                guard let self, self.modules.isEnabled(.liveActivities) else { return }
                self.liveActivities = activities
                self.refreshCompactMascot()
            }
            .store(in: &cancellables)
        liveActivityCenter.$updatedAt
            .sink { [weak self] date in
                guard let self, self.modules.isEnabled(.liveActivities) else { return }
                self.liveActivitiesUpdatedAt = date
            }
            .store(in: &cancellables)
        self.jiraProvider.onChange = { [weak self] state in
            guard let self, self.modules.isEnabled(.jira) else { return }
            let previousList = self.jiraState.list
            let wasConfigured = self.isJiraConnectionConfigured(self.jiraState.connection)
            self.jiraState = state
            if wasConfigured, self.isJiraConnectionConfigured(state.connection) == false {
                self.invalidateLinkedJiraIssues()
            }
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
                guard let self, self.modules.isEnabled(.agentInbox) else { return }
                self.aiSessions = sessions
                self.updateAISessionJiraLinks(for: sessions)
                self.codeReviews.updateSessions(sessions)
                self.compactAgentSignalController.consume(
                    sessions,
                    hasReceivedSnapshot: self.aiSessionStore.lastUpdatedAt != nil
                )
            }
            .store(in: &cancellables)
        aiSessionStore.$sourceHealth
            .sink { [weak self] health in
                guard let self, self.modules.isEnabled(.agentInbox) else { return }
                self.aiSourceHealth = health
            }
            .store(in: &cancellables)
        aiSessionStore.$lastUpdatedAt
            .sink { [weak self] date in
                guard let self, self.modules.isEnabled(.agentInbox) else { return }
                self.aiSessionsUpdatedAt = date
            }
            .store(in: &cancellables)
        codeReviews.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        quotas.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        calendar.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        moduleRuntime.register(.quotas, start: { [weak self] in self?.quotas.resume() },
                               stop: { [weak self] in self?.quotas.suspend() })
        moduleRuntime.register(.calendar, start: { [weak self] in
            guard let self else { return }
            self.calendar.start(enabled: self.visiblePanels.contains(.calendar) || self.dockCalendarEnabled)
        }, stop: { [weak self] in self?.calendar.stop() })
        moduleRuntime.register(.music, start: { [weak self] in self?.nowPlayingProvider.start() },
                               stop: { [weak self] in
            guard let self else { return }
            self.nowPlayingProvider.stop()
            self.nowPlayingSnapshot = nil
            self.musicLyrics.updateTrack(nil)
            self.musicQueue.setActive(false)
            self.musicQueue.updateTrack(nil)
            self.nowPlayingRequiresAccessibilityAccess = false
            self.nowPlayingDiagnostics = .unavailable
        })
        moduleRuntime.register(.jira, start: { [weak self] in
            guard let self else { return }
            self.jiraProvider.start()
            self.updateAISessionJiraLinks(for: self.aiSessions)
        },
                               stop: { [weak self] in
            guard let self else { return }
            self.jiraProvider.setVisible(false)
            self.jiraProvider.stop()
            self.jiraState = JiraProviderState()
            self.invalidateLinkedJiraIssues()
        })
        moduleRuntime.register(.agentInbox, start: { [weak self] in
            guard let self else { return }
            self.aiSessionStore.start()
            self.codeReviews.updateSessions(self.aiSessionStore.sessions)
        }, stop: { [weak self] in
            guard let self else { return }
            self.aiSessionStore.stop()
            self.aiUsage.clear()
            self.aiResponseGeneration &+= 1
            self.respondingAISessionIDs.removeAll()
            self.aiResponseErrors.removeAll()
            self.codeReviews.stop()
            self.codeReviews.updateSessions([])
            self.aiSessions = []
            self.aiSourceHealth = [:]
            self.aiSessionsUpdatedAt = nil
            self.aiJiraIssueKeys = [:]
            self.invalidateLinkedJiraIssues()
            self.compactAgentSignalController.reset()
        })
        moduleRuntime.register(.liveActivities, start: { [weak self] in self?.liveActivityCenter.start() },
                               stop: { [weak self] in
            guard let self else { return }
            self.liveActivityCenter.stop()
            self.liveActivities = []
            self.liveActivitiesUpdatedAt = nil
        })
        moduleRuntime.register(.fileShelf, start: { [weak self] in self?.fileShelfStore.setActive(true) },
                               stop: { [weak self] in self?.fileShelfStore.setActive(false) })
        fileShelfStore.setActive(moduleStore.isEnabled(.fileShelf))
        moduleStore.changes.sink { [weak self] _ in
            guard let self else { return }
            if !self.visiblePanels.contains(self.selectedPanel) {
                self.selectedPanel = self.visiblePanels.first ?? .ai
            }
            if !self.modules.isEnabled(.fileShelf), self.activeUtility == .files { self.activeUtility = nil }
            if !self.modules.isEnabled(.scratchpad) {
                self.scratchpad.setActive(false)
                if self.activeUtility == .scratchpad { self.activeUtility = nil }
            }
            if !self.modules.isEnabled(.recentCaptures) {
                self.recentCaptures.setActive(false)
                if self.activeUtility == .recentCaptures { self.activeUtility = nil }
            }
            if !self.modules.isEnabled(.jira), self.activeTransientSurfaces.contains(where: { $0.utilityModule == nil }) {
                self.activeTransientSurfaces = self.activeTransientSurfaces.filter { $0.utilityModule != nil }
                self.transientSurfaceDismissalRequest &+= 1
            }
            self.refreshCompactMascot()
            self.updateProviderActivity()
            self.objectWillChange.send()
        }.store(in: &cancellables)
        moduleRuntime.start()
        updateProviderActivity()
        fileShelfStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func waitForQuotaWidgetPersistence() async { await quotas.waitForWidgetPersistence() }

    /// Terminal shutdown: feature owners cancel their work before provider teardown.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        scratchpad.setActive(false)
        recentCaptures.setActive(false)
        aiUsage.clear()
        cancelScheduledCollapse()
        compactMascotExpiryTask?.cancel()
        compactMascotExpiryTask = nil
        linkedJiraGeneration &+= 1
        moduleRuntime.stop()
        cancellables.removeAll()
        quotas.stop()
        calendar.stop()
        codeReviews.stop()
        aiSessionStore.stop()
        jiraProvider.onChange = nil
        jiraProvider.stop()
        nowPlayingProvider.onChange = nil
        nowPlayingProvider.onAccessStateChange = nil
        nowPlayingProvider.onDiagnosticsChange = nil
        nowPlayingProvider.stop()
        musicLyrics.deactivate()
        musicQueue.setActive(false)
        liveActivityCenter.stop()
    }

    var compactMeetingReminder: MeetingReminder? {
        guard modules.isEnabled(.calendar), visiblePanels.contains(.calendar),
              aiSessions.contains(where: { $0.status.needsAttention }) == false else { return nil }
        return upcomingMeetingReminder
    }

    var usesWideCompactLayout: Bool {
        (modules.isEnabled(.music) && nowPlayingSnapshot?.playbackState.isPlaying == true)
            || compactMeetingReminder != nil || compactTimer != nil || hasCompactLiveActivity
    }

    var timerSource: NoolTimerSource { liveActivityCenter.timerSource }

    var dockCalendarEvents: [CalendarEvent] { modules.isEnabled(.calendar) ? calendar.reminderEvents : [] }

    func setDockWidgets(musicVisible: Bool, calendarEnabled: Bool) {
        if dockMusicVisible != musicVisible {
            dockMusicVisible = musicVisible
            updateProviderActivity()
        }
        if dockCalendarEnabled != calendarEnabled {
            dockCalendarEnabled = calendarEnabled
            refreshMeetingReminderCalendar()
        }
    }

    var compactTimer: NoolTimerSnapshot? {
        guard modules.isEnabled(.liveActivities), visiblePanels.contains(.live),
              aiSessions.contains(where: { $0.status.needsAttention }) == false,
              let timer = timerSource.snapshot,
              timer.state == .active || timer.state == .paused else { return nil }
        return timer
    }

    var compactActivityPages: [CompactActivityPage] {
        CompactActivitySelection.pages(
            hasMeeting: compactMeetingReminder != nil,
            hasTimer: compactTimer != nil,
            activities: modules.isEnabled(.liveActivities) && visiblePanels.contains(.live) ? liveActivities : [],
            hasMusic: modules.isEnabled(.music)
                && visiblePanels.contains(.music)
                && nowPlayingSnapshot?.playbackState.isPlaying == true
                && NotchCustomizationSettings.shared.showsMusicIndicator,
            nativeTimerSourceID: timerSource.id
        )
    }

    var selectedCompactActivity: CompactActivityPage? {
        let selectedID = CompactActivitySelection.selectedID(selectedCompactActivityID, from: compactActivityPages)
        return compactActivityPages.first { $0.id == selectedID }
    }

    var hasCompactLiveActivity: Bool {
        compactActivityPages.contains { page in
            if case .live = page { return true }
            return false
        }
    }

    func selectCompactActivity(_ page: CompactActivityPage) {
        guard compactActivityPages.contains(page), selectedCompactActivityID != page.id else { return }
        selectedCompactActivityID = page.id
        NotchHaptics.wheelSelectionChanged()
    }

    func cycleCompactActivity(forward: Bool) {
        let pages = compactActivityPages
        guard pages.count > 1 else { return }
        let nextID = CompactActivitySelection.cycledID(
            from: selectedCompactActivityID,
            pages: pages,
            forward: forward
        )
        guard let nextID, nextID != selectedCompactActivityID,
              let nextPage = pages.first(where: { $0.id == nextID }) else { return }
        selectCompactActivity(nextPage)
    }

    func openTimer() {
        guard modules.isEnabled(.liveActivities) else { return }
        openPanel(.live)
    }

    func openPanel(_ panel: PanelID) {
        guard isPanelAvailable(panel) else { return }
        if hiddenPanelIDs.contains(panel) {
            setPanelVisible(panel, isVisible: true)
        }
        selectPanel(panel)
        isExpanded = true
    }

    private func refreshMeetingReminderCalendar() {
        guard modules.isEnabled(.calendar) else { return }
        calendar.setEnabled(visiblePanels.contains(.calendar) || dockCalendarEnabled)
    }

    func openReminderCalendar() {
        guard modules.isEnabled(.calendar) else { return }
        if hiddenPanelIDs.contains(.calendar) {
            setPanelVisible(.calendar, isVisible: true)
        }
        selectPanel(.calendar)
        isExpanded = true
    }

    func snapshot(for providerID: String) -> QuotaSnapshot? {
        guard modules.isEnabled(.quotas) else { return nil }
        return quotas.snapshot(for: providerID)
    }

    var orderedQuotaProviders: [any QuotaProvider]{ modules.isEnabled(.quotas) ? quotas.orderedQuotaProviders : [] }

    var visibleQuotaProviders: [any QuotaProvider]{ modules.isEnabled(.quotas) ? quotas.visibleQuotaProviders : [] }

    var compactQuotaProviderName: String { quotas.compactQuotaProviderName }

    var compactWeeklyRemainingRatio: Double? { modules.isEnabled(.quotas) ? quotas.compactWeeklyRemainingRatio : nil }

    var shouldEnableQuotaEdgePanel: Bool { modules.isEnabled(.quotas) && quotas.shouldEnableQuotaEdgePanel }

    var shouldEnableQuotaCornerStack: Bool { modules.isEnabled(.quotas) && quotas.shouldEnableQuotaCornerStack }

    func canHideQuotaProvider(_ providerID: String) -> Bool { quotas.canHideQuotaProvider(providerID) }

    func setQuotaProviderVisible(_ providerID: String, isVisible: Bool) { quotas.setQuotaProviderVisible(providerID, isVisible: isVisible) }

    func moveQuotaProvider(_ providerID: String, by offset: Int) { quotas.moveQuotaProvider(providerID, by: offset) }

    func setCompactQuotaProvider(_ providerID: String) { quotas.setCompactQuotaProvider(providerID) }

    func setCompactQuotaDisplayMode(_ mode: CompactQuotaDisplayMode) { quotas.setCompactQuotaDisplayMode(mode) }

    func setQuotaPanelEdge(_ edge: QuotaPanelEdge) { quotas.setQuotaPanelEdge(edge) }

    func setQuotaStackCorner(_ corner: QuotaStackCorner) { quotas.setQuotaStackCorner(corner) }

    func openQuotaLimits() {
        guard modules.isEnabled(.quotas) else { return }
        if hiddenPanelIDs.contains(.ai) {
            setPanelVisible(.ai, isVisible: true)
        }
        selectPanel(.ai)
        selectAISection(.limits)
        isExpanded = true
    }

    func canBeginAuthentication(for providerID: String) -> Bool {
        modules.isEnabled(.quotas) && quotas.canBeginAuthentication(for: providerID)
    }

    func refreshAllQuotaProviders() {
        refresh()
    }

    func refreshQuotaProvidersIfStale() {
        refreshQuotaProviders(ifOlderThan: 10)
    }

    func selectPanel(_ panel: PanelID) {
        guard visiblePanels.contains(panel) else { return }
        activeUtility = nil
        selectedPanel = panel
        preferences.lastSelectedPanel = panel
        updateProviderActivity()
    }

    func selectAISection(_ section: AISection) {
        guard availableAISections.contains(section) else { return }
        selectedAISection = section
        preferences.selectedAISection = section
        updateProviderActivity()
        if section == .sessions && modules.isEnabled(.agentInbox) {
            refreshCodeReviews()
        }
    }

    var codeReviewSessions: [AISession] {
        modules.isEnabled(.agentInbox) ? codeReviews.codeReviewSessions : []
    }

    func codeReviewState(for session: AISession) -> CodeReviewLoadState { codeReviews.codeReviewState(for: session) }

    func newReviewActivityCount(for session: AISession) -> Int { codeReviews.newReviewActivityCount(for: session) }

    func refreshCodeReviews() {
        guard modules.isEnabled(.agentInbox) else { return }
        codeReviews.refreshCodeReviews()
    }

    func openCodeReview(_ request: CodeReviewRequest, for session: AISession) {
        guard modules.isEnabled(.agentInbox) else { return }
        codeReviews.acknowledgeReviewActivity(for: session)
        NSWorkspace.shared.open(request.url)
    }

    var aiAttentionCount: Int {
        guard modules.isEnabled(.agentInbox) else { return 0 }
        return aiSessions.filter { $0.status.needsAttention }.count
    }

    func openAISession(_ session: AISession) {
        guard modules.isEnabled(.agentInbox) else { return }
        let generation = aiResponseGeneration
        Task { @MainActor [weak self] in
            guard let self, await self.aiSessionStore.open(session) else { return }
            guard generation == self.aiResponseGeneration,
                  self.modules.isEnabled(.agentInbox) else { return }
            self.isExpanded = false
        }
    }

    func respondToAISession(_ session: AISession, response: AISessionResponse) {
        guard modules.isEnabled(.agentInbox), let request = session.attentionRequest,
              respondingAISessionIDs.contains(session.id) == false else { return }
        respondingAISessionIDs.insert(session.id)
        aiResponseErrors.removeValue(forKey: session.id)
        let generation = aiResponseGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await self.aiSessionStore.respond(
                to: session,
                requestID: request.id,
                response: response
            )
            guard generation == self.aiResponseGeneration,
                  self.modules.isEnabled(.agentInbox) else { return }
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
        guard modules.isEnabled(.jira), modules.isEnabled(.agentInbox) else { return nil }
        return aiJiraIssueKeys[session.id]
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
        guard modules.isEnabled(.jira), modules.isEnabled(.agentInbox) else { return }
        guard let key = jiraIssueKey(for: session) else { return }
        Task { await loadLinkedJiraIssue(key: key, force: true) }
    }

    func openJiraIssue(_ issue: JiraIssue) {
        guard modules.isEnabled(.jira), let baseURL = configuredJiraBaseURLString,
              let url = issue.browserURL(baseURL: baseURL) else { return }
        NSWorkspace.shared.open(url)
    }

    var visiblePanels: [PanelID] {
        panelOrder.filter { hiddenPanelIDs.contains($0) == false && isPanelAvailable($0) }
    }

    private static func isPanelAvailable(_ panel: PanelID, in modules: AppModuleStore) -> Bool {
        switch panel {
        case .ai: modules.isEnabled(.quotas) || modules.isEnabled(.agentInbox)
        case .live: modules.isEnabled(.liveActivities)
        case .calendar: modules.isEnabled(.calendar)
        case .music: modules.isEnabled(.music)
        case .jira: modules.isEnabled(.jira)
        }
    }

    func isPanelAvailable(_ panel: PanelID) -> Bool { Self.isPanelAvailable(panel, in: modules) }

    var availableAISections: [AISection] {
        AISection.allCases.filter {
            switch $0 {
            case .limits: modules.isEnabled(.quotas)
            case .sessions: modules.isEnabled(.agentInbox)
            }
        }
    }

    var effectiveAISection: AISection { availableAISections.contains(selectedAISection) ? selectedAISection : availableAISections.first ?? .limits }

    var visibleCompactAgentSignal: CompactAgentSignal? {
        modules.isEnabled(.agentInbox) && visiblePanels.contains(.ai) ? compactAgentSignal : nil
    }

    var primaryLiveActivity: LiveActivity? {
        guard modules.isEnabled(.liveActivities), visiblePanels.contains(.live) else { return nil }
        return LiveActivityFeed.primaryCompactActivity(in: liveActivities)
    }

    var compactMascotNotice: CompactMascotNotice? {
        compactMascotPresentation?.notice
    }

    private func refreshCompactMascot() {
        let now = Date()
        var candidates: [CompactMascotNotice] = []
        if modules.isEnabled(.liveActivities), visiblePanels.contains(.live) {
            candidates += liveActivities.filter { $0.showsNotificationMascot(at: now) }
                .map(CompactMascotNotice.live)
        }
        if let signal = visibleCompactAgentSignal {
            candidates.append(.agent(signal))
        }
        let previousID = compactMascotPresentation?.id
        compactMascotBatch.update(candidates, at: now)
        compactMascotPresentation = compactMascotBatch.presentation
        guard previousID != compactMascotPresentation?.id else { return }
        compactMascotExpiryTask?.cancel()
        compactMascotExpiryTask = nil
        if let presentation = compactMascotPresentation {
            compactMascotExpiryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(max(0, presentation.expiresAt.timeIntervalSinceNow)))
                } catch { return }
                guard Task.isCancelled == false else { return }
                self?.refreshCompactMascot()
            }
        }
    }

    func prepareToOpenPrimaryLiveActivity() {
        guard primaryLiveActivity != nil else { return }
        cancelScheduledCollapse()
        selectPanel(.live)
    }

    func openCompactAgentSessions() {
        guard let signal = visibleCompactAgentSignal else { return }
        compactAgentSignalController.acknowledge(signal)
        cancelScheduledCollapse()
        selectPanel(.ai)
        selectAISection(.sessions)
        isExpanded = true
    }

    func openCompactMascotNotice(_ notice: CompactMascotNotice) {
        switch notice {
        case .agent:
            openCompactAgentSessions()
        case .live:
            guard modules.isEnabled(.liveActivities) else { return }
            cancelScheduledCollapse()
            selectPanel(.live)
            isExpanded = true
        }
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
        if panel == .calendar { refreshMeetingReminderCalendar() }
        refreshCompactMascot()
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
        opensOverviewOnExpansion = false
        preferences.opensOverviewOnExpansion = false
        startupPanel = panel
        preferences.startupPanel = panel
    }

    func setOverviewAsStartup() {
        opensOverviewOnExpansion = true
        preferences.opensOverviewOnExpansion = true
        startupPanel = nil
        preferences.startupPanel = nil
    }

    /// Used only for generic click/hover expansion; activity shortcuts keep their destination.
    func prepareDefaultExpansion() {
        guard !isExpanded else { return }
        if opensOverviewOnExpansion {
            activeUtility = .overview
        } else if let startupPanel, visiblePanels.contains(startupPanel) {
            selectPanel(startupPanel)
        }
    }

    func acknowledgePanelSwipe() {
        guard hasCompletedPanelSwipe == false else { return }
        hasCompletedPanelSwipe = true
        preferences.hasCompletedPanelSwipe = true
    }

    func lastUpdatedAt(for panel: PanelID) -> Date? {
        guard isPanelAvailable(panel) else { return nil }
        switch panel {
        case .ai:
            let quotaDates = visibleQuotaProviders.compactMap { snapshots[$0.id] }
                .filter { $0.connection != .unavailable }
                .map(\.updatedAt)
            let sessionDates = modules.isEnabled(.agentInbox)
                ? [aiSessionsUpdatedAt, codeReviewsUpdatedAt].compactMap { $0 } : []
            return (quotaDates + sessionDates).max()
        case .live:
            return liveActivitiesUpdatedAt
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
        guard isPanelAvailable(panel) else { return nil }
        switch panel {
        case .ai:
            if modules.isEnabled(.agentInbox) {
                if aiAttentionCount > 0 { return aiAttentionCount }
                let newReviewActivity = newReviewActivityCounts.values.reduce(0, +)
                if newReviewActivity > 0 { return newReviewActivity }
            }
            return visibleQuotaProviders.compactMap { snapshots[$0.id] }
                .flatMap(\.windows)
                .filter { ($0.remainingRatio ?? 1) < 0.2 }
                .count
        case .live:
            return liveActivities.filter { $0.state != .completed }.count
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

    func toggleExpansionPin() {
        guard isExpanded else { return }
        cancelScheduledCollapse()
        hasRequestedCollapse = false
        isExpansionPinned.toggle()
    }

    func requestCollapse() {
        cancelScheduledCollapse()
        isExpansionPinned = false
        hasRequestedCollapse = true
        if activeUtility?.requiresKeyboardFocus == true,
           !activeTransientSurfaces.contains(where: { $0.utilityModule != nil }) { closeUtility() }
        if isTransientSurfaceVisible { transientSurfaceDismissalRequest += 1 }
        completeRequestedCollapse()
    }

    @discardableResult
    func completeRequestedCollapse() -> Bool {
        guard hasRequestedCollapse, !isTransientSurfaceVisible else { return false }
        isExpanded = false
        return true
    }

    var isTransientSurfaceVisible: Bool {
        isContextMenuVisible || activeTransientSurfaces.isEmpty == false
            || activeUtility?.requiresKeyboardFocus == true || isFileDropTargeted
            || (modules.isEnabled(.fileShelf) && fileShelfStore.isImporting) || isChoosingShelfFiles
    }

    func openUtility(_ utility: NotchUtilityPanel) {
        if utility == .files, !modules.isEnabled(.fileShelf) { return }
        if utility == .scratchpad {
            guard modules.isEnabled(.scratchpad) else { return }
            scratchpad.setActive(true)
        }
        if utility == .recentCaptures {
            guard modules.isEnabled(.recentCaptures) else { return }
            recentCaptures.setActive(true)
        }
        cancelScheduledCollapse()
        activeUtility = utility
        isExpanded = true
    }

    func closeUtility() { activeUtility = nil }

    func addRecentCaptureToShelf(_ url: URL) {
        guard modules.isEnabled(.recentCaptures), modules.isEnabled(.fileShelf),
              activeUtility == .recentCaptures else { return }
        // The shelf owns its own directory access after the gallery releases its lease.
        fileShelfStore.add(urls: [url], accessScope: recentCaptures.folderURL)
        openUtility(.files)
    }

    func acceptShelfDrop(_ providers: [NSItemProvider]) -> Bool {
        guard modules.isEnabled(.fileShelf) else { return false }
        let accepted = fileShelfStore.acceptDrop(providers: providers)
        if accepted { openUtility(.files) }
        return accepted
    }

    func chooseShelfFiles() {
        guard modules.isEnabled(.fileShelf) else { return }
        cancelScheduledCollapse()
        isChoosingShelfFiles = true
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "На полку"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                if response == .OK, self.modules.isEnabled(.fileShelf) {
                    self.fileShelfStore.add(urls: panel.urls)
                }
                self.isChoosingShelfFiles = false
            }
        }
    }

    func searchResults(query: String) -> [UnifiedSearchResult] {
        var issues: [JiraIssue]
        switch modules.isEnabled(.jira) ? jiraState.list : .idle {
        case .loaded(let loaded, _): issues = loaded
        case .loading(let previous), .failed(_, let previous): issues = previous ?? []
        case .idle: issues = []
        }
        if modules.isEnabled(.jira) {
            issues += jiraState.pinned.sourceStates.values.flatMap(\.issues)
            issues += Array(aiLinkedJiraIssues.values)
        }
        var events = calendarEventsByMonth.values.flatMap { $0 }
        if case .loaded(let snapshot) = calendarState { events += snapshot.upcomingEvents }
        return UnifiedSearch.results(query: query, issues: issues,
                                     sessions: modules.isEnabled(.agentInbox) ? aiSessions : [], events: events)
    }

    func openMeetingURL(_ url: URL) {
        guard modules.isEnabled(.calendar), url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func transientSurfaceDidPresent(_ surface: NotchTransientSurface) {
        guard modules.isEnabled(surface.utilityModule ?? .jira) else { return }
        activeTransientSurfaces.insert(surface)
        cancelScheduledCollapse()
    }

    func transientSurfaceDidDisappear(_ surface: NotchTransientSurface) {
        activeTransientSurfaces.remove(surface)
        if surface.utilityModule != nil, hasRequestedCollapse { closeUtility() }
        completeRequestedCollapse()
    }

    func scheduleCollapse(
        after delay: TimeInterval = NotchHoverPolicy.collapseGracePeriod,
        onlyIf shouldCollapse: @escaping @MainActor () -> Bool = { true }
    ) {
        cancelScheduledCollapse()
        guard !isExpansionPinned else { return }
        collapseTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard self?.isExpansionPinned == false else { return }
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
        if !completeRequestedCollapse() { scheduleCollapse() }
    }

    func refresh() {
        guard modules.isEnabled(.quotas) else { return }
        quotas.refresh()
    }

    func loadCalendarIfNeeded() {
        guard modules.isEnabled(.calendar) else { return }
        calendar.loadCalendarIfNeeded()
    }

    func refreshCalendar() {
        guard modules.isEnabled(.calendar) else { return }
        calendar.refreshCalendar()
    }

    func refreshNowPlaying() {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.refresh()
    }

    func nowPlayingTogglePlayPause() {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.togglePlayPause()
    }

    func nowPlayingPreviousTrack() {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.previousTrack()
    }

    func nowPlayingNextTrack() {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.nextTrack()
    }

    func nowPlayingSeek(to time: TimeInterval) {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.seek(to: time)
    }

    func openNowPlayingApplication() {
        guard modules.isEnabled(.music) else { return }
        nowPlayingProvider.openPlayer()
    }

    var configuredJiraBaseURLString: String? {
        preferences.jiraBaseURLString
    }

    func checkJiraConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        return await jiraProvider.checkConnection(baseURLText: baseURLText, token: token)
    }

    func connectJira(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        let result = await jiraProvider.connect(baseURLText: baseURLText, token: token)
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        if case .success = result {
            // A reconnect can change the server/token without changing the displayed user.
            invalidateLinkedJiraIssues()
            loadMissingAISessionJiraIssues(retryingFailures: true)
        }
        return result
    }

    func disconnectJira() {
        guard modules.isEnabled(.jira) else { return }
        invalidateLinkedJiraIssues()
        jiraProvider.disconnect()
    }

    func refreshJira() {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.refresh()
    }

    func setJiraSelectedProjectKeys(_ keys: Set<String>) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.setSelectedProjectKeys(keys)
    }

    func setJiraIssueScope(_ scope: JiraIssueScope) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.setIssueScope(scope)
    }

    func loadMoreJiraIssues() {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.loadMoreIssues()
    }

    func refreshJiraPinnedCatalog() {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.refreshPinnedCatalog()
    }

    func toggleJiraPinnedContainer(_ container: JiraPinnedContainer) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.togglePinnedContainer(container)
    }

    func moveJiraPinnedContainer(_ container: JiraPinnedContainer, by offset: Int) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.movePinnedContainer(container, by: offset)
    }

    func pinJiraIssue(key: String) async {
        guard modules.isEnabled(.jira) else { return }
        await jiraProvider.pinIssue(key: key)
    }

    func removeJiraPinnedIssue(_ issue: JiraPinnedIssue) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.removePinnedIssue(issue)
    }

    func moveJiraPinnedIssue(_ issue: JiraPinnedIssue, by offset: Int) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.movePinnedIssue(issue, by: offset)
    }

    func selectJiraPinnedSource(_ source: JiraPinnedSourceID) {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.selectPinnedSource(source)
    }

    func refreshJiraPinnedSource() {
        guard modules.isEnabled(.jira) else { return }
        jiraProvider.refreshPinnedSource()
    }

    func loadJiraTransitions(for issueKey: String) async {
        guard modules.isEnabled(.jira) else { return }
        await jiraProvider.loadTransitions(for: issueKey)
    }

    func submitJiraTransition(issueKey: String, transition: JiraTransition) async {
        guard modules.isEnabled(.jira) else { return }
        await jiraProvider.performTransition(issueKey: issueKey, transition: transition)
        guard modules.isEnabled(.jira) else { return }
        await loadLinkedJiraIssue(key: issueKey, force: true)
    }

    func searchJiraAssignees(
        issueKey: String,
        projectKey: String,
        query: String
    ) async {
        guard modules.isEnabled(.jira) else { return }
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
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        let result = await jiraProvider.assign(issueKey: issueKey, selection: selection)
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        if case .success = result {
            await loadLinkedJiraIssue(key: issueKey, force: true)
        }
        return result
    }

    func submitJiraWorklog(
        issueKey: String,
        draft: JiraWorklogDraft
    ) async -> Result<Void, JiraAPIError> {
        guard modules.isEnabled(.jira) else { return .failure(.notConfigured) }
        return await jiraProvider.addWorklog(issueKey: issueKey, draft: draft)
    }

    func calendarEvents(for month: Date) -> [CalendarEvent]{
        modules.isEnabled(.calendar) ? calendar.calendarEvents(for: month) : []
    }

    func loadCalendarMonthIfNeeded(for month: Date) {
        guard modules.isEnabled(.calendar) else { return }
        calendar.loadCalendarMonthIfNeeded(for: month)
    }

    func beginAuthentication(for providerID: String) {
        guard modules.isEnabled(.quotas) else { return }
        quotas.beginAuthentication(for: providerID)
    }

    private func refreshQuotaProviders(ifOlderThan maximumAge: TimeInterval) {
        guard modules.isEnabled(.quotas) else { return }
        quotas.refreshQuotaProviders(ifOlderThan: maximumAge)
    }

    private func updateAISessionJiraLinks(for sessions: [AISession]) {
        guard modules.isEnabled(.agentInbox), modules.isEnabled(.jira) else {
            invalidateLinkedJiraIssues()
            aiJiraIssueKeys = [:]
            return
        }
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
        guard modules.isEnabled(.agentInbox), modules.isEnabled(.jira) else { return }
        let generation = linkedJiraGeneration
        for key in Set(aiJiraIssueKeys.values) {
            guard aiLinkedJiraIssues[key] == nil,
                  aiLinkedJiraLoadingKeys.contains(key) == false,
                  retryingFailures || aiLinkedJiraErrors[key] == nil else { continue }
            Task {
                guard generation == linkedJiraGeneration else { return }
                await loadLinkedJiraIssue(key: key, force: retryingFailures)
            }
        }
    }

    private func invalidateLinkedJiraIssues() {
        linkedJiraGeneration &+= 1
        aiLinkedJiraIssues.removeAll()
        aiLinkedJiraErrors.removeAll()
        aiLinkedJiraLoadingKeys.removeAll()
    }

    private func loadLinkedJiraIssue(key: String, force: Bool) async {
        guard modules.isEnabled(.agentInbox), modules.isEnabled(.jira) else { return }
        guard force || aiLinkedJiraIssues[key] == nil,
              aiLinkedJiraLoadingKeys.contains(key) == false else { return }
        aiLinkedJiraLoadingKeys.insert(key)
        aiLinkedJiraErrors.removeValue(forKey: key)
        let generation = linkedJiraGeneration
        let result = await jiraProvider.issue(key: key)
        guard generation == linkedJiraGeneration,
              modules.isEnabled(.agentInbox), modules.isEnabled(.jira) else { return }
        aiLinkedJiraLoadingKeys.remove(key)
        guard aiJiraIssueKeys.values.contains(key) else { return }
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

    private func updateProviderActivity() {
        guard !isStopped else { return }
        if !isExpanded || selectedPanel != .music || activeUtility != nil || isShowingSettings {
            musicLyrics.deactivate()
            musicQueue.setActive(false)
        }
        if modules.isEnabled(.music) {
            let musicPanelVisible = isExpanded
            && selectedPanel == .music
            && isShowingSettings == false
            let mode: NowPlayingPollingMode = (musicPanelVisible || dockMusicVisible)
                ? .visibleMusic
                : .background
            nowPlayingProvider.setPollingMode(mode)
        }

        if modules.isEnabled(.jira) {
            jiraProvider.setVisible(isExpanded
                && visiblePanels.contains(.jira)
                && isShowingSettings == false)
        }

        let showsCodeReviews = isExpanded
            && selectedPanel == .ai
            && visiblePanels.contains(.ai)
            && isShowingSettings == false
        codeReviews.setVisible(modules.isEnabled(.agentInbox) && showsCodeReviews)
    }

    private func refreshPanelBadges() {
        refreshQuotaProviders(ifOlderThan: 10)
        if visiblePanels.contains(.calendar) {
            refreshCalendar()
        }
        if visiblePanels.contains(.music) {
            refreshNowPlaying()
        }
    }
}
