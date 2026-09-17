import Combine
import Foundation

@MainActor
final class AIChatStore: ObservableObject {
    @Published var draft = "" { didSet { draftChanged() } }
    @Published private(set) var draftAttachments: [AIChatAttachment] = [] { didSet { draftChanged() } }
    @Published private(set) var isImportingAttachments = false
    @Published private(set) var messages: [AIChatMessage] = []
    @Published private(set) var statuses: [AIChatProviderID: AIChatProviderStatus] = [:]
    @Published private(set) var checking: Set<AIChatProviderID> = []
    @Published private(set) var selectedProvider: AIChatProviderID = .apple
    @Published private(set) var selectedModelID = "apple-system"
    @Published private(set) var isStreaming = false
    @Published var errorMessage: String?
    @Published var codexEnabled: Bool { didSet { connectionChanged(.codex) } }
    @Published var claudeEnabled: Bool { didSet { connectionChanged(.claude) } }
    @Published private(set) var history: [AIChatHistoryConversation] = []
    @Published private(set) var historyError: String?
    @Published private(set) var activeConversationID: UUID?

    private let defaults: UserDefaults
    private let providers: [AIChatProviderID: any LauncherAIChatProviding]
    private let historyURL: URL?
    private let historyQueue = DispatchQueue(label: "app.nool.notch.ai-chat-history")
    private var responseTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var discoveryTasks: [AIChatProviderID: Task<Void, Never>] = [:]
    private var discoveryGenerations: [AIChatProviderID: Int] = [:]
    private var responseGeneration = 0
    private var historyGeneration = 0
    private var persistenceGeneration = 0
    private var historyLoadFailed = false
    private var historyLoadFinished = true
    private var historyNeedsSavingAfterLoad = false
    private var draftSaveTask: Task<Void, Never>?
    private var pendingPersistenceOperations = 0
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private let timeout: Duration
    private var changingDraft = false
    private var attachmentGeneration = 0
    private var attachmentTask: Task<Void, Never>?

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            providers: [
                LauncherAppleChatProvider(),
                LauncherCodexChatProvider(),
                LauncherClaudeChatProvider(),
                LauncherOllamaChatProvider()
            ],
            defaults: defaults,
            historyURL: Self.defaultHistoryURL()
        )
    }

    init(
        providers: [any LauncherAIChatProviding],
        defaults: UserDefaults,
        timeout: Duration = .seconds(180),
        historyURL: URL? = nil
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.defaults = defaults
        self.timeout = timeout
        self.historyURL = historyURL
        codexEnabled = defaults.bool(forKey: "nool.launcher.ai.codexEnabled")
        claudeEnabled = defaults.bool(forKey: "nool.launcher.ai.claudeEnabled")
        if let raw = defaults.string(forKey: "nool.launcher.ai.provider"), let saved = AIChatProviderID(rawValue: raw) {
            selectedProvider = saved
            selectedModelID = defaults.string(forKey: "nool.launcher.ai.model") ?? ""
        }
        historyLoadFinished = historyURL == nil
        loadHistoryIfNeeded()
    }

    var selectedStatus: AIChatProviderStatus? { statuses[selectedProvider] }
    var selectedModels: [AIChatModelOption] { selectedStatus?.models ?? [] }
    var supportsImages: Bool { selectedModels.first { $0.id == selectedModelID }?.supportsImages == true }
    var attachmentIssue: String? {
        if (draftAttachments.contains(where: { $0.kind == .image }) || messages.contains(where: { $0.attachments.contains(where: { $0.kind == .image }) })), !supportsImages {
            return "Эта модель не поддерживает изображения. Выберите модель с пометкой «Фото» или удалите изображение."
        }
        let prompt = AIChatMessage(role: .user, text: draft, attachments: draftAttachments)
        let limit = selectedProvider == .apple ? 6_000 : 24_000
        if !draftAttachments.isEmpty, prompt.modelText.count > limit {
            return "Текст вложений слишком велик для этой модели. Сократите сообщение или прикрепите меньший документ."
        }
        return nil
    }
    var canSend: Bool {
        !isStreaming && !isImportingAttachments && attachmentIssue == nil && selectedStatus?.isAvailable == true
            && selectedModels.contains(where: { $0.id == selectedModelID })
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftAttachments.isEmpty) && draft.count <= 8_000
    }

    func importAttachments(_ urls: [URL]) {
        guard !isStreaming, !isImportingAttachments else { return }
        guard !urls.isEmpty, urls.count + draftAttachments.count <= 4 else {
            errorMessage = "Можно прикрепить до четырёх файлов."; return
        }
        errorMessage = nil
        isImportingAttachments = true
        attachmentGeneration += 1
        let generation = attachmentGeneration
        attachmentTask = Task { [weak self] in
            var loaded: [AIChatAttachment] = []
            do {
                for url in urls {
                    try Task.checkCancellation()
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        try AIChatAttachmentLoader.load(url: url)
                    }.value
                    loaded.append(attachment)
                }
                guard !Task.isCancelled, let self, self.attachmentGeneration == generation else { return }
                self.addAttachments(loaded)
            } catch {
                guard !Task.isCancelled, let self, self.attachmentGeneration == generation else { return }
                self.errorMessage = "\(error.localizedDescription) Файлы из этой подборки не добавлены."
            }
            guard let self, self.attachmentGeneration == generation else { return }
            self.isImportingAttachments = false
            self.attachmentTask = nil
        }
    }

    func addAttachments(_ attachments: [AIChatAttachment]) {
        guard !isStreaming else { return }
        let combined = draftAttachments + attachments
        guard combined.count <= 4,
              combined.allSatisfy({ $0.text.count <= 12_000 && ($0.imageData?.count ?? 0) <= 2 * 1024 * 1024 }),
              combined.reduce(0, { $0 + ($1.imageData?.count ?? 0) }) <= 4 * 1024 * 1024 else {
            errorMessage = "Лимит: четыре вложения и 4 МБ изображений после обработки."; return
        }
        draftAttachments = combined
    }

    func removeAttachment(_ id: UUID) { draftAttachments.removeAll { $0.id == id } }

    private func cancelAttachmentImport() {
        attachmentGeneration += 1
        attachmentTask?.cancel()
        attachmentTask = nil
        isImportingAttachments = false
    }

    func isEnabled(_ id: AIChatProviderID) -> Bool {
        switch id {
        case .apple, .ollama: true
        case .codex: codexEnabled
        case .claude: claudeEnabled
        }
    }

    func refreshAvailability() {
        for id in AIChatProviderID.allCases { refresh(id) }
    }

    func selectProvider(_ id: AIChatProviderID) {
        guard id != selectedProvider else { return }
        let pending = draftAttachments
        let pendingText = draft
        newChat()
        selectedProvider = id
        selectedModelID = statuses[id]?.models.first?.id ?? ""
        if !pending.isEmpty { draftAttachments = pending; draft = pendingText }
        saveSelection()
        refresh(id)
    }

    func selectModel(_ id: String) {
        guard id != selectedModelID, selectedModels.contains(where: { $0.id == id }) else { return }
        let pending = draftAttachments
        let pendingText = draft
        newChat()
        selectedModelID = id
        if !pending.isEmpty { draftAttachments = pending; draft = pendingText }
        saveSelection()
    }

    func send() {
        guard canSend, let provider = providers[selectedProvider] else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = input.isEmpty ? "Проанализируй прикреплённые материалы." : input
        let userMessage = AIChatMessage(role: .user, text: prompt, attachments: draftAttachments)
        let attachmentBytes = (messages + [userMessage]).reduce(0) { $0 + $1.attachments.reduce(0) { $0 + $1.storageBytes } }
        guard attachmentBytes <= 12 * 1024 * 1024 else {
            errorMessage = "Диалог достиг лимита вложений. Начните новый чат."; return
        }
        guard messages.count < 98, messages.reduce(0, { $0 + $1.modelText.count }) + userMessage.modelText.count <= 200_000 else {
            errorMessage = "Диалог достиг лимита. Начните новый чат."
            return
        }
        ensureActiveConversation()
        errorMessage = nil
        messages.append(userMessage)
        changingDraft = true
        draftAttachments = []
        draft = ""
        changingDraft = false
        let context = messages.filter { $0.state == .complete }
        let reply = AIChatMessage(role: .assistant, text: "", state: .streaming)
        messages.append(reply)
        saveCurrentConversation(debounced: true)
        responseGeneration += 1
        let generation = responseGeneration
        isStreaming = true
        let stream = provider.stream(messages: context, model: selectedModelID)
        responseTask = Task { [weak self] in
            do {
                for try await delta in stream {
                    guard !Task.isCancelled, let self, self.responseGeneration == generation,
                          let index = self.messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    guard self.messages[index].text.count + delta.count <= 64_000,
                          self.messages.reduce(0, { $0 + $1.modelText.count }) + delta.count <= 200_000 else {
                        self.stop()
                        self.errorMessage = "Ответ достиг лимита длины и был остановлен."
                        return
                    }
                    self.messages[index].text += delta
                    self.saveCurrentConversation(debounced: true)
                }
                guard let self, self.responseGeneration == generation else { return }
                self.finish(replyID: reply.id, error: nil)
            } catch {
                guard let self, self.responseGeneration == generation else { return }
                let message = (error as? AIChatError)?.localizedDescription
                    ?? (error is CancellationError ? "Ответ остановлен." : "Не удалось получить ответ. Проверьте подключение и вход в CLI.")
                self.finish(replyID: reply.id, error: message)
            }
        }
        deadlineTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.responseGeneration == generation, self.isStreaming else { return }
            self.stop()
            self.errorMessage = AIChatError.timeout.localizedDescription
        }
    }

    func stop() {
        responseGeneration += 1
        responseTask?.cancel()
        responseTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        if isStreaming { providers[selectedProvider]?.cancel() }
        for index in messages.indices where messages[index].state == .streaming { messages[index].state = .interrupted }
        isStreaming = false
        saveCurrentConversation(debounced: false)
    }

    func newChat() {
        stop()
        cancelAttachmentImport()
        changingDraft = true
        messages = []
        activeConversationID = nil
        draft = ""
        draftAttachments = []
        changingDraft = false
        errorMessage = nil
    }

    func openConversation(_ id: UUID) {
        guard history.contains(where: { $0.id == id }) else { return }
        stop()
        cancelAttachmentImport()
        // `stop()` changes a live reply to interrupted and persists its final
        // visible text, so reload after it rather than restoring a stale copy.
        guard let conversation = history.first(where: { $0.id == id }) else { return }
        activeConversationID = conversation.id
        selectedProvider = conversation.provider
        selectedModelID = conversation.modelID
        messages = conversation.messages.map { message in
            var message = message
            if message.state == .streaming { message.state = .interrupted }
            return message
        }
        changingDraft = true
        draft = conversation.draft
        draftAttachments = conversation.draftAttachments
        changingDraft = false
        errorMessage = nil
        saveSelection()
        refresh(selectedProvider)
    }

    func deleteConversation(_ id: UUID) {
        guard history.contains(where: { $0.id == id }) else { return }
        if activeConversationID == id {
            cancelAttachmentImport()
            changingDraft = true
            responseGeneration += 1
            responseTask?.cancel()
            responseTask = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            if isStreaming { providers[selectedProvider]?.cancel() }
            isStreaming = false
            messages = []
            activeConversationID = nil
            draft = ""
            draftAttachments = []
            changingDraft = false
        }
        history.removeAll { $0.id == id }
        enqueueHistorySave()
    }

    func togglePinConversation(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].isPinned.toggle()
        history[index].updatedAt = .now
        orderHistory()
        enqueueHistorySave()
    }

    func flushHistory() async {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        saveCurrentConversation(debounced: false)
        await waitForPersistence()
    }

    func waitForPersistence() async {
        guard pendingPersistenceOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            persistenceWaiters.append(continuation)
        }
    }

    func shutdown() {
        cancelAttachmentImport()
        stop()
        draftSaveTask?.cancel()
        draftSaveTask = nil
        saveCurrentConversation(debounced: false)
        for task in discoveryTasks.values { task.cancel() }
        discoveryTasks = [:]
        for id in AIChatProviderID.allCases { discoveryGenerations[id, default: 0] += 1 }
        checking = []
        for provider in providers.values { provider.cancel() }
    }

    private func finish(replyID: UUID, error: String?) {
        deadlineTask?.cancel()
        deadlineTask = nil
        responseTask = nil
        isStreaming = false
        guard let index = messages.firstIndex(where: { $0.id == replyID }) else { return }
        if let error {
            messages[index].state = .failed
            errorMessage = error
        } else if messages[index].text.isEmpty {
            messages[index].state = .failed
            errorMessage = "Модель завершила запрос без текстового ответа."
        } else {
            messages[index].state = .complete
        }
        saveCurrentConversation(debounced: false)
    }

    private func connectionChanged(_ id: AIChatProviderID) {
        defaults.set(isEnabled(id), forKey: "nool.launcher.ai.\(id.rawValue)Enabled")
        if !isEnabled(id) {
            if selectedProvider == id { stop() }
            providers[id]?.cancel()
        }
        refresh(id)
    }

    private func refresh(_ id: AIChatProviderID) {
        discoveryTasks[id]?.cancel()
        discoveryGenerations[id, default: 0] += 1
        let generation = discoveryGenerations[id, default: 0]
        guard isEnabled(id) else {
            statuses[id] = AIChatProviderStatus(isAvailable: false, message: "Включите подключение \(id.title) в настройках AI.", models: [])
            checking.remove(id)
            return
        }
        guard let provider = providers[id] else { return }
        checking.insert(id)
        discoveryTasks[id] = Task { [weak self] in
            let status = await provider.availability()
            guard !Task.isCancelled, let self, self.discoveryGenerations[id] == generation else { return }
            self.statuses[id] = status
            self.checking.remove(id)
            self.discoveryTasks[id] = nil
            if self.selectedProvider == id, self.messages.isEmpty,
               !status.models.contains(where: { $0.id == self.selectedModelID }) {
                self.selectedModelID = status.models.first?.id ?? ""
                self.saveSelection()
            }
        }
    }

    private func draftChanged() {
        guard !changingDraft else { return }
        if draft.isEmpty, draftAttachments.isEmpty, messages.isEmpty, let activeConversationID {
            history.removeAll { $0.id == activeConversationID }
            self.activeConversationID = nil
            enqueueHistorySave()
            return
        }
        guard !draft.isEmpty || !draftAttachments.isEmpty || activeConversationID != nil else { return }
        saveCurrentConversation(debounced: true)
    }

    private func ensureActiveConversation() {
        guard activeConversationID == nil else { return }
        activeConversationID = UUID()
    }

    private func saveCurrentConversation(debounced: Bool) {
        guard historyURL != nil, (!messages.isEmpty || !draft.isEmpty || !draftAttachments.isEmpty) else { return }
        ensureActiveConversation()
        guard let activeConversationID else { return }
        let now = Date()
        let existing = history.first(where: { $0.id == activeConversationID })
        let conversation = AIChatHistoryConversation(
            id: activeConversationID,
            title: title(messages: messages, draft: draft),
            provider: selectedProvider,
            modelID: selectedModelID,
            messages: messages,
            draft: draft,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            isPinned: existing?.isPinned ?? false,
            draftAttachments: draftAttachments
        )
        if let index = history.firstIndex(where: { $0.id == activeConversationID }) {
            history[index] = conversation
        } else {
            history.append(conversation)
        }
        orderHistory()
        enforceHistoryBounds()
        if debounced {
            scheduleDraftSave()
        } else {
            enqueueHistorySave()
        }
    }

    private func title(messages: [AIChatMessage], draft: String) -> String {
        let raw = messages.first(where: { $0.role == .user })?.text ?? (draft.isEmpty ? draftAttachments.first?.name ?? "" : draft)
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 72 else { return normalized.isEmpty ? "Новый чат" : normalized }
        return String(normalized.prefix(71)) + "…"
    }

    private func orderHistory() {
        history.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func enforceHistoryBounds() {
        var removed = false
        while history.count > AIChatHistoryDisk.maximumConversationCount ||
                AIChatHistoryDisk.rawByteCount(history) > AIChatHistoryDisk.maximumRawBytes {
            guard let index = history.lastIndex(where: { $0.isPinned == false && $0.id != activeConversationID }) else {
                historyError = "История переполнена. Удалите или открепите старые чаты, чтобы сохранить новые."
                return
            }
            history.remove(at: index)
            removed = true
        }
        if removed {
            historyError = "Удалены старые незакреплённые чаты: достигнут лимит истории."
        }
    }

    private func scheduleDraftSave() {
        guard historyLoadFailed == false else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.enqueueHistorySave()
        }
    }

    private func enqueueHistorySave() {
        guard historyLoadFinished else {
            historyNeedsSavingAfterLoad = true
            return
        }
        guard let historyURL, historyLoadFailed == false else { return }
        let snapshot = history
        persistenceGeneration += 1
        let generation = persistenceGeneration
        beginPersistenceOperation()
        historyQueue.async { [weak self, historyURL, snapshot] in
            let result = AIChatHistoryDisk.write(snapshot, url: historyURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.persistenceGeneration == generation else { return }
                switch result {
                case .success: break
                case .tooLarge:
                    self.historyError = "История слишком велика для локального хранения. Удалите или открепите старые чаты."
                case .failure:
                    self.historyError = "Не удалось сохранить локальную историю чатов."
                }
            }
        }
    }

    private func loadHistoryIfNeeded() {
        guard let historyURL else { return }
        let generation = historyGeneration
        beginPersistenceOperation()
        historyQueue.async { [weak self, historyURL] in
            let result = AIChatHistoryDisk.load(url: historyURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.historyGeneration == generation else { return }
                switch result {
                case let .success(loaded):
                    self.historyLoadFinished = true
                    self.mergeLoadedHistory(loaded)
                    if self.historyNeedsSavingAfterLoad {
                        self.historyNeedsSavingAfterLoad = false
                        self.enqueueHistorySave()
                    }
                case .corrupt:
                    self.historyLoadFailed = true
                    self.historyLoadFinished = true
                    self.historyNeedsSavingAfterLoad = false
                    self.historyError = "Не удалось прочитать локальную историю чатов. Исходный файл сохранён без изменений."
                }
            }
        }
    }

    private func mergeLoadedHistory(_ loaded: [AIChatHistoryConversation]) {
        var merged = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        for conversation in history { merged[conversation.id] = conversation }
        history = AIChatHistoryDisk.normalize(Array(merged.values))
        orderHistory()
        enforceHistoryBounds()
    }

    private func beginPersistenceOperation() {
        pendingPersistenceOperations += 1
    }

    private func finishPersistenceOperation() {
        pendingPersistenceOperations -= 1
        guard pendingPersistenceOperations == 0 else { return }
        let waiters = persistenceWaiters
        persistenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func saveSelection() {
        defaults.set(selectedProvider.rawValue, forKey: "nool.launcher.ai.provider")
        defaults.set(selectedModelID, forKey: "nool.launcher.ai.model")
    }

    nonisolated private static func defaultHistoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nool Notch", isDirectory: true)
            .appendingPathComponent("ai-chat-history.json", isDirectory: false)
    }
}
