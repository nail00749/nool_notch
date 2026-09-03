import AppKit
import Foundation

@MainActor
final class LocalAgentSessionSource: AISessionSource {
    typealias URLOpener = @MainActor @Sendable (URL) -> Bool

    let id = "local-agents"
    let displayName = "Local agents"

    private let reader: CodexStateReader
    private let urlOpener: URLOpener
    private let hookServer = CodexCLIHookServer()
    private var continuation: AsyncStream<AISessionSourceSnapshot>.Continuation?
    private var pollingTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var isStarted = false
    private var databaseSessions: [AISession] = []
    private var hookSessions: [String: AISession] = [:]
    private var pendingResponders: [String: CodexCLIHookResponder] = [:]
    private var integrationError: String?

    init(
        databaseURL: URL = CodexStateReader.defaultDatabaseURL(),
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) }
    ) {
        reader = CodexStateReader(
            databaseURL: databaseURL,
            sessionSourceID: id,
            acceptedThreadSources: ["cli"],
            agentName: "Codex CLI",
            sessionIDPrefix: "codex-cli:"
        )
        self.urlOpener = urlOpener
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
        guard sessionID.hasPrefix("codex-cli:") else { return false }
        let rawSessionID = String(sessionID.dropFirst("codex-cli:".count))
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = rawSessionID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "codex://threads/\(encoded)") else { return false }
        return urlOpener(url)
    }

    func respond(
        sessionID: String,
        requestID: String,
        response: AISessionResponse
    ) async -> Bool {
        guard let responder = pendingResponders.removeValue(forKey: requestID) else {
            return false
        }

        let allowed: Bool
        switch response {
        case .approveOnce:
            allowed = true
        case .deny:
            allowed = false
        case .approveForSession, .answers:
            pendingResponders[requestID] = responder
            return false
        }

        responder.resolve(allowed: allowed)
        if let previous = hookSessions[sessionID] {
            hookSessions[sessionID] = AISession(
                id: previous.id,
                agentName: previous.agentName,
                title: previous.title,
                workspacePath: previous.workspacePath,
                modelName: previous.modelName,
                status: .running,
                startedAt: previous.startedAt,
                lastActivity: .now,
                isStale: false
            )
        }
        publishCurrentSessions()
        return true
    }

    private func start() {
        guard isStarted == false else { return }
        isStarted = true
        hookServer.onEvent = { [weak self] event, responder in
            self?.handleHookEvent(event, responder: responder)
        }
        do {
            if UserDefaults.standard.bool(
                forKey: UserDefaultsAppPreferences.cliHooksEnabledKey
            ) {
                try hookServer.start()
                try CodexCLIHookInstaller.install()
            } else {
                try CodexCLIHookInstaller.uninstall()
                try hookServer.start()
            }
        } catch CodexCLIHookInstallError.bridgeUnavailable {
            integrationError = "CLI bridge появится после запуска app bundle"
        } catch {
            integrationError = "Не удалось подключить Codex CLI hooks"
        }
        refresh()
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(5))
                guard Task.isCancelled == false else { return }
                self?.refresh()
            }
        }
    }

    private func stop() {
        isStarted = false
        pollingTask?.cancel()
        pollingTask = nil
        for responder in pendingResponders.values {
            responder.resolve(allowed: false)
        }
        pendingResponders.removeAll()
        hookServer.stop()
        hookServer.onEvent = nil
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
                self.databaseSessions = sessions
                publishCurrentSessions()
            case .failure:
                publish(health: combinedSessions.isEmpty
                    ? .unavailable(message: "История CLI недоступна")
                    : .stale(message: "Показываю последние данные"))
            }
        }
    }

    private func handleHookEvent(
        _ event: CodexCLIHookEvent,
        responder: CodexCLIHookResponder?
    ) {
        let compositeSessionID = "\(event.sourceID):\(event.sessionID)"
        let previous = hookSessions[compositeSessionID]
            ?? databaseSessions.first(where: { $0.id.sessionID == compositeSessionID })
        if let previousRequestID = previous?.attentionRequest?.id,
           let previousResponder = pendingResponders.removeValue(forKey: previousRequestID) {
            previousResponder.resolve(allowed: false)
        }
        let requestID = "hook:\(compositeSessionID):\(UUID().uuidString)"
        let status: AISessionStatus
        let request: AISessionAttentionRequest?

        if event.isPermissionRequest, let responder {
            status = .waitingForApproval
            request = AISessionAttentionRequest(
                id: requestID,
                kind: .approval,
                title: event.toolName.map { "Разрешить \($0)?" } ?? "Разрешить действие?",
                detail: event.detail,
                context: event.workspacePath,
                supportsSessionApproval: false,
                questions: []
            )
            pendingResponders[requestID] = responder
        } else {
            request = nil
            switch event.eventName.lowercased() {
            case "stop", "sessionend":
                status = .completed
            default:
                status = .running
            }
        }

        let workspaceName = event.workspacePath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        let agentName = event.sourceID == "claude-code" ? "Claude Code" : "Codex CLI"
        hookSessions[compositeSessionID] = AISession(
            id: AISessionID(sourceID: id, sessionID: compositeSessionID),
            agentName: agentName,
            title: previous?.title ?? workspaceName ?? agentName,
            workspacePath: event.workspacePath ?? previous?.workspacePath,
            modelName: previous?.modelName,
            status: status,
            startedAt: previous?.startedAt ?? .now,
            lastActivity: .now,
            isStale: false,
            attentionRequest: request
        )
        publishCurrentSessions()
    }

    private var combinedSessions: [AISession] {
        var sessionsByID = Dictionary(uniqueKeysWithValues: databaseSessions.map {
            ($0.id.sessionID, $0)
        })
        for (sessionID, hookSession) in hookSessions {
            if let databaseSession = sessionsByID[sessionID] {
                sessionsByID[sessionID] = AISession(
                    id: hookSession.id,
                    agentName: hookSession.agentName,
                    title: databaseSession.title,
                    workspacePath: hookSession.workspacePath ?? databaseSession.workspacePath,
                    modelName: databaseSession.modelName,
                    status: hookSession.status,
                    startedAt: databaseSession.startedAt ?? hookSession.startedAt,
                    lastActivity: max(hookSession.lastActivity, databaseSession.lastActivity),
                    isStale: false,
                    attentionRequest: hookSession.attentionRequest
                )
            } else {
                sessionsByID[sessionID] = hookSession
            }
        }
        return Array(sessionsByID.values)
    }

    private func publishCurrentSessions() {
        let health: AISessionSourceHealth = integrationError.map {
            .stale(message: $0)
        } ?? .live
        publish(health: health)
    }

    private func publish(health: AISessionSourceHealth) {
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: combinedSessions,
            health: health,
            updatedAt: .now
        ))
    }
}
