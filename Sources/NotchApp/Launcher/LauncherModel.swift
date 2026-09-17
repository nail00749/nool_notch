import AppKit
import Combine

enum LauncherSelection {
    static func moved(current: String?, offset: Int, ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    static func preserved(current: String?, ids: [String]) -> String? {
        if let current, ids.contains(current) { return current }
        return ids.first
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { queryChanged() } }
    @Published var category: LauncherCategory = .all { didSet { queryChanged() } }
    @Published private(set) var results: [LauncherResult] = []
    @Published var selectedID: String?
    @Published var message: String?
    @Published var selectedNoolEvent: CalendarEvent?
    @Published private(set) var isSearching = false
    @Published private(set) var sourceError: String?
    let applications: LauncherApplicationProvider
    let files: LauncherFileProvider
    let clipboard: LauncherClipboardStore
    let settings: LauncherSettings
    let icons = LauncherIcons()
    let aiChat = AIChatStore()
    let textSelection = LauncherTextSelection()
    private weak var noolSource: NotchViewModel?
    private var noolSubscription: AnyCancellable?
    private var noolResults: [String: UnifiedSearchResult] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var rankingTask: Task<Void, Never>?
    private var rankingGeneration = 0
    private var isVisible = false

    init(settings: LauncherSettings, applications: LauncherApplicationProvider = LauncherApplicationProvider(),
         files: LauncherFileProvider = LauncherFileProvider(), clipboard: LauncherClipboardStore = LauncherClipboardStore()) {
        self.settings = settings
        self.applications = applications
        self.files = files
        self.clipboard = clipboard
        Publishers.Merge3(applications.objectWillChange, files.objectWillChange, clipboard.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &subscriptions)
    }

    var selectedResult: LauncherResult? { results.first { $0.id == selectedID } }

    func connectNoolSearch(to source: NotchViewModel) {
        noolSource = source
        noolSubscription = source.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.isVisible, self.category == .all else { return }
            self.rebuild()
        }
    }

    /// Returns true when opening an external destination should dismiss Launcher.
    func openNoolResult(_ id: String) -> Bool {
        guard let result = noolResults[id], let source = noolSource else { return false }
        switch result {
        case .issue(let issue): source.openJiraIssue(issue); return true
        case .session(let session): source.openAISession(session); return true
        case .event(let event): selectedNoolEvent = event; return false
        }
    }

    func joinSelectedMeeting() {
        if let url = selectedNoolEvent?.joinURL { noolSource?.openMeetingURL(url) }
    }

    func present() {
        isVisible = true
        message = nil
        if category != .ai { category = .all }
        query = ""
        clipboard.captureIfChanged()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.applications.refresh() }
        rebuild()
    }

    func dismiss() {
        isVisible = false
        files.stop()
        refreshTask?.cancel()
        refreshTask = nil
        query = ""
    }

    func settingsChanged() {
        clipboard.configure(enabled: settings.clipboardEnabled, limit: settings.clipboardLimit, retentionDays: settings.retentionDays)
        queryChanged()
    }

    func move(_ offset: Int) {
        selectedID = LauncherSelection.moved(current: selectedID, offset: offset, ids: results.map(\.id))
    }

    func cycleCategory(backwards: Bool = false) {
        let categories = LauncherCategory.allCases
        guard let index = categories.firstIndex(of: category) else { return }
        category = categories[(index + (backwards ? categories.count - 1 : 1)) % categories.count]
    }

    private func queryChanged() {
        message = nil
        selectedNoolEvent = nil
        // A new input invalidates activation immediately, before background ranking.
        // Otherwise a fast Return could launch the previous query's selection.
        results = []
        selectedID = nil
        if isVisible, category == .all || category == .files {
            files.search(query: query, folders: settings.folders)
        } else {
            files.stop()
        }
        rebuild()
    }

    private func rebuild() {
        var matches: [LauncherResult] = []
        if category == .all || category == .applications { matches += applications.results }
        if category == .all || category == .files { matches += files.results }
        let clipboardItems = settings.clipboardEnabled && (category == .clipboard || (category == .all && !query.isEmpty))
            ? clipboard.items : []
        rankingTask?.cancel()
        rankingGeneration += 1
        let generation = rankingGeneration
        let input = query
        let scope = category
        let matchesInNool = category == .all && query.count <= 512
            ? (noolSource?.searchResults(query: query) ?? []) : []
        noolResults = Dictionary(matchesInNool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let noolCandidates = matchesInNool.map { LauncherResult(nool: $0) }
        let candidates = matches
        rankingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Self.searchResults(candidates, clipboard: clipboardItems, query: input, category: scope, nool: noolCandidates)
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.rankingGeneration == generation else { return }
            self.results = found
            self.selectedID = LauncherSelection.preserved(current: self.selectedID, ids: found.map(\.id))
        }
        isSearching = ((category == .all || category == .files) && files.isSearching)
            || ((category == .all || category == .applications) && applications.isLoading)
        var errors: [String] = []
        if category == .all || category == .files, let error = files.errorMessage { errors.append(error) }
        if category == .all || category == .applications, let error = applications.errorMessage { errors.append(error) }
        if category == .clipboard, let error = clipboard.errorMessage { errors.append(error) }
        sourceError = errors.first
    }

    nonisolated static func searchResults(_ candidates: [LauncherResult], clipboard: [LauncherClipboardItem],
                                         query: String, category: LauncherCategory, nool: [LauncherResult] = []) -> [LauncherResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 512 else { return [] }
        var found: [LauncherResult] = []
        if category == .all, let value = LauncherCalculator.evaluate(trimmed) {
            found.append(LauncherResult(id: "calculator", title: value, subtitle: "Результат · Enter — скопировать",
                                        payload: .calculation(value)))
        }
        if category == .all && !trimmed.isEmpty { found += nool }
        found += LauncherSearch.ranked(candidates, query: trimmed)
        let clipboardResults: [LauncherResult] = clipboard.compactMap { item in
            guard !Task.isCancelled else { return nil }
            let result = LauncherResult(id: "clipboard:\(item.id.uuidString)", title: item.title,
                                        subtitle: item.subtitle, payload: .clipboard(item.id))
            // Search the complete body, not only the truncated first line shown in a row.
            if trimmed.isEmpty || item.text?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return result
            }
            return LauncherSearch.ranked([result], query: trimmed).first
        }
        found += clipboardResults
        return Array(found.prefix(120))
    }
}
