import AppKit
import Foundation

@MainActor
final class CodexDesktopSessionSource: AISessionSource {
    typealias URLOpener = @MainActor @Sendable (URL) -> Bool
    typealias ApplicationActivator = @MainActor @Sendable (String) -> Bool

    let id = CodexStateReader.sourceID
    let displayName = "Codex Desktop"

    private let reader: CodexStateReader
    private let urlOpener: URLOpener
    private let applicationActivator: ApplicationActivator
    private let fileManager: FileManager
    private var continuation: AsyncStream<AISessionSourceSnapshot>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var isStarted = false
    private var fallbackSessions: [String: AISession] = [:]
    private var liveStatuses: [String: AISessionStatus] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]
    private var client: CodexAppServerClient?
    private var health: AISessionSourceHealth = .unavailable(message: "Codex ещё не обнаружен")

    init(
        reader: CodexStateReader = CodexStateReader(),
        fileManager: FileManager = .default,
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        applicationActivator: @escaping ApplicationActivator = { bundleID in
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }) {
                if app.isHidden { app.unhide() }
                return app.activate()
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return false
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            return true
        }
    ) {
        self.reader = reader
        self.fileManager = fileManager
        self.urlOpener = urlOpener
        self.applicationActivator = applicationActivator
    }

    func snapshots() -> AsyncStream<AISessionSourceSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            start()
        }
    }

    func open(sessionID: String) async -> Bool {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        if let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: "codex://threads/\(encoded)"),
           urlOpener(url) {
            return true
        }
        return applicationActivator(Self.bundleIdentifier)
    }

    func respond(
        sessionID: String,
        requestID: String,
        response: AISessionResponse
    ) async -> Bool {
        guard let pending = pendingRequests[sessionID],
              pending.publicRequest.id == requestID,
              let client else { return false }

        let result: [String: CodexJSONValue]
        switch (pending.kind, response) {
        case (.approval, .approveOnce):
            result = ["decision": .string("accept")]
        case (.approval(let allowsSession), .approveForSession) where allowsSession:
            result = ["decision": .string("acceptForSession")]
        case (.approval, .deny):
            result = ["decision": .string("decline")]
        case (.input(let questionIDs), .answers(let answers)):
            let encoded = Dictionary(uniqueKeysWithValues: questionIDs.map { questionID in
                let answer = answers[questionID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (questionID, CodexJSONValue.object([
                    "answers": .array([.string(answer)])
                ]))
            })
            guard encoded.values.allSatisfy({ value in
                value.objectValue?["answers"]?.arrayValue?.first?.stringValue?.isEmpty == false
            }) else { return false }
            result = ["answers": .object(encoded)]
        default:
            return false
        }

        do {
            try client.sendResponse(id: pending.responseID, result: result)
            pendingRequests.removeValue(forKey: sessionID)
            liveStatuses[sessionID] = .running
            if let existing = fallbackSessions[sessionID] {
                fallbackSessions[sessionID] = replacing(existing, status: .running, lastActivity: .now)
            }
            publish()
            return true
        } catch {
            return false
        }
    }

    static func status(from value: CodexJSONValue?) -> AISessionStatus? {
        guard let object = value?.objectValue,
              let type = object["type"]?.stringValue else { return nil }
        switch type {
        case "active":
            let flags = object["activeFlags"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if flags.contains("waitingOnApproval") { return .waitingForApproval }
            if flags.contains("waitingOnUserInput") { return .waitingForInput }
            return .running
        case "idle":
            return .completed
        case "systemError":
            return .failed
        case "notLoaded":
            return .unknown
        default:
            return nil
        }
    }

    static func executableURL(
        runningBundleURLs: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        let fallbacks = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path
        ]
        let candidates = runningBundleURLs.map {
            $0.appendingPathComponent("Contents/Resources/codex")
        } + fallbacks.map { URL(fileURLWithPath: $0) }

        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    nonisolated private static let bundleIdentifier = "com.openai.codex"

    private func start() {
        guard isStarted == false else { return }
        isStarted = true

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleIdentifier else { return }
                Task { @MainActor in
                    self?.refresh()
                    self?.startLiveClientIfPossible()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleIdentifier else { return }
                Task { @MainActor in self?.codexDidTerminate() }
            }
        ]

        refresh()
        startLiveClientIfPossible()
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(5))
                guard Task.isCancelled == false else { return }
                self?.refresh()
            }
        }
    }

    private func stop() {
        guard isStarted else { return }
        isStarted = false
        pollingTask?.cancel()
        pollingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        client?.stop()
        client = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        continuation = nil
    }

    private func refresh() {
        scanGeneration += 1
        let generation = scanGeneration
        let reader = reader
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                () -> Result<[AISession], CodexStateReaderError> in
                do {
                    return .success(try reader.loadSessions())
                } catch let error as CodexStateReaderError {
                    return .failure(error)
                } catch {
                    return .failure(.queryFailed)
                }
            }.value
            guard let self, generation == self.scanGeneration else { return }
            switch result {
            case .success(let sessions):
                self.fallbackSessions = Dictionary(uniqueKeysWithValues: sessions.map {
                    ($0.id.sessionID, $0)
                })
                if self.client?.isRunning == true {
                    self.health = .live
                } else if self.codexIsRunning {
                    self.health = .stale(message: "Live-статус переподключается")
                } else {
                    self.health = .stale(message: "Codex не запущен")
                }
            case .failure:
                if self.fallbackSessions.isEmpty {
                    self.health = .unavailable(message: "Сессии Codex пока недоступны")
                } else {
                    self.health = .stale(message: "Показываю последние данные")
                }
            }
            self.publish()
        }
    }

    private var codexIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleIdentifier
        }
    }

    private func startLiveClientIfPossible() {
        guard client == nil, codexIsRunning else { return }
        let bundleURLs = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier == Self.bundleIdentifier ? app.bundleURL : nil
        }
        guard let executableURL = Self.executableURL(
            runningBundleURLs: bundleURLs,
            fileManager: fileManager
        ) else {
            health = .stale(message: "Live-источник Codex не найден")
            publish()
            scheduleReconnect()
            return
        }

        let liveClient = CodexAppServerClient(executableURL: executableURL)
        liveClient.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        liveClient.onExit = { [weak self, weak liveClient] _ in
            Task { @MainActor in
                guard let self, self.client === liveClient else { return }
                self.client = nil
                self.health = .stale(message: "Live-статус переподключается")
                self.publish()
                self.refresh()
                self.scheduleReconnect()
            }
        }

        do {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            try liveClient.start(clientVersion: version)
            client = liveClient
            reconnectTask?.cancel()
            reconnectTask = nil
            health = .live
            publish()
        } catch {
            liveClient.stop()
            health = .stale(message: "Live-статус переподключается")
            publish()
            scheduleReconnect()
        }
    }

    private func handle(_ message: CodexAppServerMessage) {
        switch message.method {
        case "thread/started":
            guard let thread = message.params["thread"]?.objectValue,
                  let threadID = thread["id"]?.stringValue else { return }
            let existing = fallbackSessions[threadID]
            let title = thread["name"]?.stringValue
                ?? thread["preview"]?.stringValue
                ?? existing?.title
                ?? "Codex task"
            let status = Self.status(from: thread["status"]) ?? .running
            liveStatuses[threadID] = status
            fallbackSessions[threadID] = AISession(
                id: AISessionID(sourceID: id, sessionID: threadID),
                agentName: "Codex",
                title: title,
                workspacePath: thread["cwd"]?.stringValue ?? existing?.workspacePath,
                modelName: existing?.modelName,
                status: status,
                startedAt: existing?.startedAt ?? .now,
                lastActivity: .now,
                isStale: false
            )
            publish()
        case "thread/status/changed":
            guard let threadID = message.params["threadId"]?.stringValue,
                  let status = Self.status(from: message.params["status"]) else { return }
            liveStatuses[threadID] = status
            if let existing = fallbackSessions[threadID] {
                fallbackSessions[threadID] = replacing(existing, status: status, lastActivity: .now)
            }
            publish()
        case "thread/closed":
            guard let threadID = message.params["threadId"]?.stringValue else { return }
            pendingRequests.removeValue(forKey: threadID)
            liveStatuses[threadID] = .completed
            if let existing = fallbackSessions[threadID] {
                fallbackSessions[threadID] = replacing(existing, status: .completed, lastActivity: .now)
            }
            publish()
        case "item/commandExecution/requestApproval":
            captureApprovalRequest(message, fileChange: false)
        case "item/fileChange/requestApproval":
            captureApprovalRequest(message, fileChange: true)
        case "item/tool/requestUserInput":
            captureInputRequest(message)
        case "serverRequest/resolved":
            guard let requestID = Self.requestID(from: message.params["requestId"]) else { return }
            let affectedThreadIDs = pendingRequests.compactMap { threadID, request in
                request.responseID == requestID ? threadID : nil
            }
            affectedThreadIDs.forEach { pendingRequests.removeValue(forKey: $0) }
            if affectedThreadIDs.isEmpty == false { publish() }
        default:
            break
        }
    }

    private func captureApprovalRequest(_ message: CodexAppServerMessage, fileChange: Bool) {
        guard let responseID = message.id,
              let threadID = message.params["threadId"]?.stringValue else { return }
        let command = message.params["command"]?.stringValue
        let reason = message.params["reason"]?.stringValue
        let grantRoot = message.params["grantRoot"]?.stringValue
        let cwd = message.params["cwd"]?.stringValue
        let availableDecisions = message.params["availableDecisions"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        let allowsSession = fileChange || availableDecisions.contains("acceptForSession")
        let title = fileChange ? "Изменение файлов" : "Подтверждение команды"
        let detail = command ?? reason ?? grantRoot ?? "Codex запрашивает разрешение"
        let request = AISessionAttentionRequest(
            id: responseID.stableString,
            kind: .approval,
            title: title,
            detail: detail,
            context: cwd,
            supportsSessionApproval: allowsSession,
            questions: []
        )
        pendingRequests[threadID] = PendingRequest(
            responseID: responseID,
            publicRequest: request,
            kind: .approval(allowsSession: allowsSession)
        )
        markSession(threadID, status: .waitingForApproval)
    }

    private func captureInputRequest(_ message: CodexAppServerMessage) {
        guard let responseID = message.id,
              let threadID = message.params["threadId"]?.stringValue else { return }
        let questions = message.params["questions"]?.arrayValue?.compactMap { value -> AISessionQuestion? in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let prompt = object["question"]?.stringValue else { return nil }
            let options = object["options"]?.arrayValue?.compactMap { option in
                option.objectValue?["label"]?.stringValue
            } ?? []
            return AISessionQuestion(
                id: id,
                title: object["header"]?.stringValue ?? "Ответ",
                prompt: prompt,
                options: options,
                allowsFreeform: object["isOther"]?.boolValue ?? true
            )
        } ?? []
        guard questions.isEmpty == false else { return }
        let request = AISessionAttentionRequest(
            id: responseID.stableString,
            kind: .input,
            title: questions.count == 1 ? questions[0].title : "Codex ждёт ответы",
            detail: questions.count == 1 ? questions[0].prompt : "Ответь на вопросы, чтобы продолжить задачу",
            context: nil,
            supportsSessionApproval: false,
            questions: questions
        )
        pendingRequests[threadID] = PendingRequest(
            responseID: responseID,
            publicRequest: request,
            kind: .input(questionIDs: questions.map(\.id))
        )
        markSession(threadID, status: .waitingForInput)
    }

    private func markSession(_ threadID: String, status: AISessionStatus) {
        liveStatuses[threadID] = status
        if let existing = fallbackSessions[threadID] {
            fallbackSessions[threadID] = replacing(existing, status: status, lastActivity: .now)
        }
        publish()
    }

    private static func requestID(from value: CodexJSONValue?) -> CodexRequestID? {
        switch value {
        case .number(let value): .number(Int64(value))
        case .string(let value): .string(value)
        default: nil
        }
    }

    private func replacing(
        _ session: AISession,
        status: AISessionStatus,
        lastActivity: Date
    ) -> AISession {
        AISession(
            id: session.id,
            agentName: session.agentName,
            title: session.title,
            workspacePath: session.workspacePath,
            modelName: session.modelName,
            status: status,
            startedAt: session.startedAt,
            lastActivity: lastActivity,
            isStale: false,
            attentionRequest: pendingRequests[session.id.sessionID]?.publicRequest
        )
    }

    private func publish() {
        let hasLiveClient = client?.isRunning == true
        let sessions = fallbackSessions.values.map { session -> AISession in
            let status = liveStatuses[session.id.sessionID] ?? session.status
            return AISession(
                id: session.id,
                agentName: session.agentName,
                title: session.title,
                workspacePath: session.workspacePath,
                modelName: session.modelName,
                status: status,
                startedAt: session.startedAt,
                lastActivity: session.lastActivity,
                isStale: hasLiveClient == false,
                attentionRequest: pendingRequests[session.id.sessionID]?.publicRequest
            )
        }
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: sessions,
            health: health,
            updatedAt: .now
        ))
    }

    private func codexDidTerminate() {
        reconnectTask?.cancel()
        reconnectTask = nil
        client?.stop()
        client = nil
        liveStatuses.removeAll()
        pendingRequests.removeAll()
        health = fallbackSessions.isEmpty
            ? .unavailable(message: "Codex не запущен")
            : .stale(message: "Codex не запущен")
        publish()
        refresh()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, codexIsRunning else { return }
        reconnectTask = Task { @MainActor [weak self] in
            var delay = Duration.milliseconds(500)
            while Task.isCancelled == false {
                try? await Task.sleep(for: delay)
                guard Task.isCancelled == false, let self else { return }
                guard self.codexIsRunning else {
                    self.reconnectTask = nil
                    return
                }
                self.startLiveClientIfPossible()
                if self.client != nil {
                    self.reconnectTask = nil
                    return
                }
                delay = min(delay * 2, .seconds(10))
            }
        }
    }

    private struct PendingRequest {
        enum Kind {
            case approval(allowsSession: Bool)
            case input(questionIDs: [String])
        }

        let responseID: CodexRequestID
        let publicRequest: AISessionAttentionRequest
        let kind: Kind
    }
}
