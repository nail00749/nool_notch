import Combine
import Foundation

enum SpeedTestStatus: Equatable {
    case idle, queued, running, cancelling, cancelled, completed
    case failed(String)
}

struct SpeedTestServerState {
    var status: SpeedTestStatus = .idle
    var progress: SpeedTestProgress?
    var result: SpeedTestMeasurement?
}

@MainActor
final class SpeedTestStore: ObservableObject {
    let servers: [SpeedTestServer]
    @Published private(set) var states: [String: SpeedTestServerState] = [:]
    @Published private(set) var history: [SpeedTestMeasurement] = []
    @Published private(set) var historyStorageWarning: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    private let runner: any SpeedTestRunning
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private static let resultsKey = "nool.speedTest.results.v1"
    private static let historyKey = "nool.speedTest.history.v1"

    init(servers: [SpeedTestServer] = SpeedTestServer.defaults,
         runner: any SpeedTestRunning = SpeedTestClient(), defaults: UserDefaults = .standard) {
        self.servers = servers
        self.runner = runner
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.resultsKey).flatMap {
            try? JSONDecoder().decode([String: SpeedTestMeasurement].self, from: $0)
        } ?? [:]
        let knownIDs = Set(servers.map(\.id))
        let validSaved = saved.filter { key, value in
            value.serverID == key && SpeedTestHistory.isValid(value, knownServerIDs: knownIDs)
        }
        let storedHistory = defaults.object(forKey: Self.historyKey)
        if let storedHistory {
            if let data = storedHistory as? Data,
               let decoded = try? JSONDecoder().decode([SpeedTestMeasurement].self, from: data) {
                history = SpeedTestHistory.canonicalize(decoded, knownServerIDs: knownIDs)
                if history != decoded { persistHistory() }
            } else {
                defaults.set(storedHistory, forKey: "\(Self.historyKey).backup.\(UUID().uuidString)")
                historyStorageWarning = "Старая история повреждена. Её исходные данные сохранены на этом Mac."
                history = SpeedTestHistory.canonicalize(Array(validSaved.values), knownServerIDs: knownIDs)
                persistHistory()
            }
        } else {
            history = SpeedTestHistory.canonicalize(Array(validSaved.values), knownServerIDs: knownIDs)
            persistHistory()
        }
        for server in servers {
            let newestHistory = history.first { $0.serverID == server.id }
            let result = [validSaved[server.id], newestHistory].compactMap { $0 }
                .max { $0.measuredAt < $1.measuredAt }
            states[server.id] = SpeedTestServerState(result: result)
        }
    }

    func start(serverID: String? = nil) {
        guard task == nil else { return }
        let selected = servers.filter { serverID == nil || $0.id == serverID }
        guard !selected.isEmpty else { return }
        let token = UUID()
        generation = token
        isRunning = true
        isCancelling = false
        for server in selected {
            states[server.id]?.status = .queued
            states[server.id]?.progress = nil
        }
        let runner = self.runner
        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.isCancelling = false
                self?.task = nil
            }
            for server in selected {
                guard !Task.isCancelled, let self else { break }
                self.states[server.id]?.status = .running
                do {
                    let result = try await runner.run(server: server) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, !self.isCancelling,
                                  self.states[server.id]?.status == .running else { return }
                            self.states[server.id]?.progress = progress
                        }
                    }
                    try Task.checkCancellation()
                    guard SpeedTestHistory.isValid(result, knownServerIDs: Set(self.servers.map(\.id))),
                          result.serverID == server.id else { throw SpeedTestStoreError.invalidResult }
                    self.states[server.id]?.result = result
                    self.states[server.id]?.status = .completed
                    self.history = SpeedTestHistory.canonicalize([result] + self.history,
                                                                 knownServerIDs: Set(self.servers.map(\.id)))
                    self.persistHistory()
                    self.persistLastResults()
                } catch {
                    if Task.isCancelled {
                        self.states[server.id]?.status = .cancelled
                        break
                    }
                    self.states[server.id]?.status = .failed(error.localizedDescription)
                }
            }
            for server in selected where self?.states[server.id]?.status == .queued
                || self?.states[server.id]?.status == .cancelling {
                self?.states[server.id]?.status = .cancelled
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        generation = UUID()
        isCancelling = true
        for server in servers where states[server.id]?.status == .running {
            states[server.id]?.status = .cancelling
        }
        task?.cancel()
    }

    func waitForCompletion() async { await task?.value }

    private func persistLastResults() {
        let results = states.compactMapValues(\.result)
        if let data = try? JSONEncoder().encode(results) { defaults.set(data, forKey: Self.resultsKey) }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }

    deinit { task?.cancel() }
}

private enum SpeedTestStoreError: LocalizedError {
    case invalidResult
    var errorDescription: String? { "Сервер вернул некорректный результат измерения." }
}
