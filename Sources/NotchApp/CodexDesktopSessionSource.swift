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
    private let pollingInterval: Duration
    private var continuation: AsyncStream<AISessionSourceSnapshot>.Continuation?
    private var observers: [NSObjectProtocol] = []
    private var pollingTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var isStarted = false
    private var sessions: [AISession] = []
    private var health: AISessionSourceHealth = .unavailable(message: "Codex ещё не обнаружен")

    init(
        reader: CodexStateReader = CodexStateReader(),
        pollingInterval: Duration = .seconds(5),
        urlOpener: @escaping URLOpener = { NSWorkspace.shared.open($0) },
        applicationActivator: @escaping ApplicationActivator = { bundleID in
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }) {
                if app.isHidden { app.unhide() }
                return app.activate()
            }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return false
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
            return true
        }
    ) {
        self.reader = reader
        self.pollingInterval = pollingInterval
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

    nonisolated private static let bundleIdentifier = "com.openai.codex"
    private static let localDataMessage = "Локальные данные; отвечайте в Codex Desktop"
    private static let staleDataMessage = "Локальные данные устарели; отвечайте в Codex Desktop"

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
                Task { @MainActor in self?.refresh() }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleIdentifier else { return }
                Task { @MainActor in self?.refresh() }
            }
        ]

        refresh()
        let interval = pollingInterval
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: interval)
                guard Task.isCancelled == false else { return }
                self?.refresh()
            }
        }
    }

    private func stop() {
        guard isStarted else { return }
        isStarted = false
        scanGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        continuation = nil
    }

    private func refresh() {
        guard isStarted else { return }
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
            guard let self, self.isStarted, generation == self.scanGeneration else { return }

            switch result {
            case .success(let loadedSessions):
                self.sessions = loadedSessions.map { self.markAsLocal($0) }
                self.health = self.sessions.isEmpty
                    ? .unavailable(message: "Сессии Codex пока недоступны")
                    : .stale(message: Self.localDataMessage)
            case .failure:
                self.health = self.sessions.isEmpty
                    ? .unavailable(message: "Сессии Codex пока недоступны")
                    : .stale(message: Self.staleDataMessage)
            }
            self.publish()
        }
    }

    private func markAsLocal(_ session: AISession) -> AISession {
        AISession(
            id: session.id,
            agentName: session.agentName,
            title: session.title,
            workspacePath: session.workspacePath,
            modelName: session.modelName,
            status: session.status,
            startedAt: session.startedAt,
            accumulatedActiveDuration: session.accumulatedActiveDuration,
            activeSince: session.activeSince,
            lastActivity: session.lastActivity,
            isStale: true,
            attentionRequest: nil
        )
    }

    private func publish() {
        continuation?.yield(AISessionSourceSnapshot(
            sourceID: id,
            sessions: sessions,
            health: health,
            updatedAt: .now
        ))
    }
}
