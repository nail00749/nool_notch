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
    @Published var category: LauncherCategory = .all {
        didSet {
            if !availableCategories.contains(category) { category = .all }
            queryChanged()
        }
    }
    @Published private(set) var results: [LauncherResult] = []
    @Published var selectedID: String?
    @Published private(set) var previewKeyboardSelectionID: String?
    @Published var message: String?
    @Published var selectedNoolEvent: CalendarEvent?
    @Published private(set) var actionResult: LauncherResult?
    @Published private(set) var selectedActionIndex = 0
    @Published var jiraActionDestination: LauncherJiraDestination?
    @Published private(set) var isSearching = false
    @Published private(set) var sourceError: String?
    @Published private(set) var showsQuickAI = false
    @Published private(set) var isPreparingQuickAI = false
    @Published private(set) var quickAIQuestion = ""
    @Published private(set) var quickAIError: String?
    @Published private(set) var quickAIConversationID: UUID?
    let applications: LauncherApplicationProvider
    let files: LauncherFileProvider
    let clipboard: LauncherClipboardStore
    let snippets: LauncherSnippetStore
    let settings: LauncherSettings
    let modules: AppModuleStore
    let icons = LauncherIcons()
    let aiChat: AIChatStore
    let windowLayouts: WindowLayoutManager
    let workspaces: WorkspaceStore
    let textSelection = LauncherTextSelection()
    private weak var noolSource: NotchViewModel?
    private var noolSubscription: AnyCancellable?
    private var noolResults: [String: UnifiedSearchResult] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    private var rankingTask: Task<Void, Never>?
    private var rankingGeneration = 0
    private var isVisible = false
    private var quickAITask: Task<Void, Never>?
    private var quickAIGeneration = 0
    private var previouslyEnabledModules: Set<AppModuleID>

    init(settings: LauncherSettings, applications: LauncherApplicationProvider = LauncherApplicationProvider(),
         files: LauncherFileProvider = LauncherFileProvider(), clipboard: LauncherClipboardStore = LauncherClipboardStore(),
         aiChat: AIChatStore? = nil, windowLayouts: WindowLayoutManager? = nil,
         snippets: LauncherSnippetStore? = nil, workspaces: WorkspaceStore? = nil,
         modules: AppModuleStore? = nil) {
        let selectedModules = modules ?? AppModuleStore(defaults: nil)
        self.settings = settings
        self.modules = selectedModules
        previouslyEnabledModules = selectedModules.enabledModules
        self.applications = applications
        self.files = files
        self.clipboard = clipboard
        self.snippets = snippets ?? LauncherSnippetStore()
        self.aiChat = aiChat ?? AIChatStore(loadHistoryImmediately: selectedModules.isEnabled(.aiChat))
        self.windowLayouts = windowLayouts ?? WindowLayoutManager()
        self.workspaces = workspaces ?? WorkspaceStore()
        if !selectedModules.isEnabled(.aiChat) { self.aiChat.suspend() }
        self.windowLayouts.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isVisible else { return }
                self.rebuild()
            }.store(in: &subscriptions)
        self.workspaces.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isVisible else { return }
                self.rebuild()
            }.store(in: &subscriptions)
        Publishers.Merge3(applications.objectWillChange, files.objectWillChange, clipboard.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &subscriptions)
        self.snippets.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                if let error = self.snippets.errorMessage { self.message = error }
                self.rebuild()
            }.store(in: &subscriptions)
        self.modules.changes.sink { [weak self] _ in self?.moduleAvailabilityChanged() }
            .store(in: &subscriptions)
    }

    var availableCategories: [LauncherCategory] {
        LauncherCategory.allCases.filter { category in
            switch category {
            case .ai: modules.isEnabled(.aiChat)
            case .clipboard: modules.isEnabled(.clipboard)
            case .all, .applications, .files: true
            }
        }
    }

    var selectedResult: LauncherResult? { results.first { $0.id == selectedID && isResultAvailable($0) } }

    func isResultAvailable(_ result: LauncherResult) -> Bool {
        switch result.payload {
        case .clipboard, .snippet: modules.isEnabled(.clipboard)
        case .nool(_, let kind):
            switch kind {
            case .jira: modules.isEnabled(.jira)
            case .session: modules.isEnabled(.agentInbox)
            case .event: modules.isEnabled(.calendar)
            }
        case .windowAction, .windowLayout, .windowLayoutManager, .workspace, .workspaceManager:
            modules.isEnabled(.windowManagement)
        case .speedTest, .networkDiagnostics: modules.isEnabled(.networkTools)
        case .screenTextCapture: modules.isEnabled(.textRecognition)
        case .application, .file, .calculation: true
        }
    }

    var canPreviewWithSpace: Bool {
        LauncherPreviewKeyboardPolicy.canUseSpace(
            selected: selectedResult, navigatedID: previewKeyboardSelectionID, category: category,
            hasDetail: actionResult != nil || jiraActionDestination != nil || selectedNoolEvent != nil || showsQuickAI
        )
    }

    func clearPreviewKeyboardSelection() { previewKeyboardSelectionID = nil }

    func selectResult(_ id: String) {
        clearPreviewKeyboardSelection()
        selectedID = id
    }

    var actionSource: NotchViewModel? { noolSource }

    func resultActions(for result: LauncherResult) -> [LauncherResultAction] {
        guard isResultAvailable(result) else { return [] }
        let item: LauncherClipboardItem?
        if case .clipboard(let id) = result.payload { item = clipboard.items.first { $0.id == id } }
        else { item = nil }
        return LauncherResultAction.available(for: result, clipboardItem: item).filter { action in
            switch action {
            case .processFile, .renameFile: modules.isEnabled(.fileShelf)
            case .recognizeText: modules.isEnabled(.textRecognition)
            case .attachToAI, .prepareAI, .translate, .explain: modules.isEnabled(.aiChat)
            case .saveSnippet, .removeSnippet: modules.isEnabled(.clipboard)
            case .jiraStatus, .jiraWorklog: modules.isEnabled(.jira)
            default: true
            }
        }
    }

    func toggleActions() {
        if actionResult != nil { closeActions(); return }
        guard category != .ai, !showsQuickAI, selectedNoolEvent == nil,
              jiraActionDestination == nil, let selectedResult,
              !resultActions(for: selectedResult).isEmpty else { return }
        actionResult = selectedResult
        selectedActionIndex = 0
    }

    func closeActions() { actionResult = nil; selectedActionIndex = 0 }

    func moveAction(_ offset: Int) {
        guard let actionResult else { return }
        selectedActionIndex = min(max(0, selectedActionIndex + offset), max(0, resultActions(for: actionResult).count - 1))
    }

    func actionText(for result: LauncherResult) -> String? {
        guard isResultAvailable(result) else { return nil }
        switch result.payload {
        case .clipboard(let id): return clipboard.items.first { $0.id == id }?.text
        case .snippet(let id): return snippets.items.first { $0.id == id }?.text
        case .calculation(let text): return text
        case .nool(let id, _):
            guard let item = noolResults[id] else { return nil }
            if case .issue(let issue) = item { return issue.key }
            return item.title + "\n" + item.subtitle
        default: return nil
        }
    }

    func showJiraAction(_ action: LauncherResultAction, result: LauncherResult) {
        guard modules.isEnabled(.jira) else { return }
        guard case .nool(let id, .jira) = result.payload,
              case .issue(let issue) = noolResults[id], noolSource != nil else { return }
        jiraActionDestination = LauncherJiraDestination(issue: issue, action: action)
    }

    /// Starts a separate draft while preserving the previous conversation. Never sends.
    @discardableResult
    func prepareAIText(_ text: String, prompt: String = "") -> Bool {
        guard modules.isEnabled(.aiChat) else { return false }
        guard !aiChat.isStreaming, !aiChat.isImportingAttachments else {
            message = "Дождитесь ответа AI или загрузки вложений."; return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 12_000 else {
            message = "Для AI выберите непустой текст до 12 000 символов."; return false
        }
        aiChat.newChat()
        aiChat.addAttachments([AIChatAttachment(name: "Выбранный текст", kind: .text, text: text)])
        aiChat.draft = prompt
        category = .ai
        return true
    }

    func prepareAIFile(_ url: URL) {
        guard modules.isEnabled(.aiChat) else { return }
        guard !aiChat.isStreaming, !aiChat.isImportingAttachments else {
            message = "Дождитесь ответа AI или загрузки вложений."; return
        }
        aiChat.newChat()
        aiChat.importAttachments([url])
        category = .ai
    }

    var canAskAI: Bool {
        modules.isEnabled(.aiChat) && category == .all && selectedNoolEvent == nil && actionResult == nil && jiraActionDestination == nil && !isPreparingQuickAI
            && !aiChat.isStreaming && !aiChat.isImportingAttachments
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && query.count <= 8_000
    }

    func askAI() {
        guard canAskAI else { return }
        quickAIGeneration += 1
        let generation = quickAIGeneration
        let question = query
        quickAIQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        quickAIError = nil
        quickAIConversationID = nil
        showsQuickAI = true
        isPreparingQuickAI = true
        quickAITask = Task { [weak self] in
            guard let self else { return }
            let result = await self.aiChat.sendQuickQuestion(question)
            guard !Task.isCancelled, self.quickAIGeneration == generation else { return }
            self.isPreparingQuickAI = false
            self.quickAITask = nil
            switch result {
            case .sent: self.quickAIConversationID = self.aiChat.activeConversationID
            case .unavailable(let message): self.quickAIError = message
            case .cancelled: self.quickAIError = "Отправка отменена. Можно повторить вопрос."
            }
        }
    }

    func stopQuickAI() {
        quickAITask?.cancel()
        quickAITask = nil
        quickAIGeneration += 1
        if isPreparingQuickAI { quickAIError = "Отправка отменена." }
        isPreparingQuickAI = false
        if let id = quickAIConversationID, aiChat.activeConversationID == id { aiChat.stop() }
    }

    func closeQuickAI() {
        // Submitted answers may finish in the history; only pending sends are cancelled.
        quickAITask?.cancel()
        quickAITask = nil
        quickAIGeneration += 1
        isPreparingQuickAI = false
        showsQuickAI = false
        quickAIConversationID = nil
        quickAIError = nil
    }

    func connectNoolSearch(to source: NotchViewModel) {
        noolSource = source
        noolSubscription = source.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self, self.isVisible, self.category == .all else { return }
            self.rebuild()
        }
    }

    /// Returns true when opening an external destination should dismiss Launcher.
    func openNoolResult(_ id: String) -> Bool {
        guard let result = noolResults[id], let source = noolSource,
              isResultAvailable(LauncherResult(nool: result)) else { return false }
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
        if modules.isEnabled(.clipboard) { clipboard.captureIfChanged() }
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
        if modules.isEnabled(.clipboard) {
            clipboard.configure(enabled: settings.clipboardEnabled, limit: settings.clipboardLimit, retentionDays: settings.retentionDays)
        } else {
            clipboard.stop()
        }
        queryChanged()
    }

    private func moduleAvailabilityChanged() {
        let changed = previouslyEnabledModules.symmetricDifference(modules.enabledModules)
        previouslyEnabledModules = modules.enabledModules
        guard !changed.isEmpty else { return }
        if changed.contains(.clipboard) {
            if modules.isEnabled(.clipboard) {
                clipboard.configure(enabled: settings.clipboardEnabled, limit: settings.clipboardLimit, retentionDays: settings.retentionDays)
            } else {
                clipboard.stop()
            }
        }
        if changed.contains(.aiChat), !modules.isEnabled(.aiChat) {
            closeQuickAI()
            aiChat.suspend()
            textSelection.clear()
        } else if changed.contains(.aiChat) {
            aiChat.resume()
        }
        let launcherModules: Set<AppModuleID> = [
            .aiChat, .clipboard, .fileShelf, .textRecognition, .networkTools,
            .windowManagement, .agentInbox, .jira, .calendar
        ]
        guard !changed.isDisjoint(with: launcherModules) else { return }
        if !availableCategories.contains(category) { category = .all; return }
        if !modules.isEnabled(.jira) { jiraActionDestination = nil }
        if !modules.isEnabled(.calendar) { selectedNoolEvent = nil }
        clearPreviewKeyboardSelection()
        closeActions()
        results = []
        selectedID = nil
        rebuild()
    }

    func move(_ offset: Int) {
        if actionResult != nil { moveAction(offset); return }
        guard jiraActionDestination == nil else { return }
        guard !showsQuickAI else { return }
        selectedID = LauncherSelection.moved(current: selectedID, offset: offset, ids: results.map(\.id))
        if let selectedResult, case .file = selectedResult.payload {
            previewKeyboardSelectionID = selectedResult.id
        } else {
            clearPreviewKeyboardSelection()
        }
    }

    func cycleCategory(backwards: Bool = false) {
        let categories = availableCategories
        guard let index = categories.firstIndex(of: category) else { return }
        category = categories[(index + (backwards ? categories.count - 1 : 1)) % categories.count]
    }

    private func queryChanged() {
        clearPreviewKeyboardSelection()
        closeActions()
        jiraActionDestination = nil
        closeQuickAI()
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
        if modules.isEnabled(.windowManagement) {
            matches += LauncherResult.windowCommands(layouts: windowLayouts.layouts, query: query, category: category)
            matches += LauncherResult.workspaceCommands(workspaces: workspaces.workspaces, query: query, category: category)
        }
        if modules.isEnabled(.networkTools) { matches += LauncherResult.speedTestCommands(query: query, category: category) }
        if modules.isEnabled(.textRecognition) { matches += LauncherResult.screenTextCommands(query: query, category: category) }
        if category == .all || category == .applications { matches += applications.results }
        if category == .all || category == .files { matches += files.results }
        if modules.isEnabled(.clipboard) && (category == .all || category == .clipboard) {
            matches += snippets.items.map {
                LauncherResult(id: "snippet:\($0.id)", title: $0.title,
                               subtitle: "Шаблон · " + $0.text, payload: .snippet($0.id))
            }
        }
        let clipboardItems = modules.isEnabled(.clipboard) && settings.clipboardEnabled && (category == .clipboard || (category == .all && !query.isEmpty))
            ? clipboard.items : []
        rankingTask?.cancel()
        rankingGeneration += 1
        let generation = rankingGeneration
        let input = query
        let scope = category
        let matchesInNool = category == .all && query.count <= 512
            ? (noolSource?.searchResults(query: query) ?? []).filter { isResultAvailable(LauncherResult(nool: $0)) } : []
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
            if self.previewKeyboardSelectionID != self.selectedID { self.clearPreviewKeyboardSelection() }
            if let target = self.actionResult, !found.contains(target) { self.closeActions() }
        }
        isSearching = ((category == .all || category == .files) && files.isSearching)
            || ((category == .all || category == .applications) && applications.isLoading)
        var errors: [String] = []
        if category == .all || category == .files, let error = files.errorMessage { errors.append(error) }
        if category == .all || category == .applications, let error = applications.errorMessage { errors.append(error) }
        if modules.isEnabled(.clipboard), category == .clipboard, let error = clipboard.errorMessage { errors.append(error) }
        if modules.isEnabled(.clipboard), category == .all || category == .clipboard, let error = snippets.errorMessage { errors.append(error) }
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
