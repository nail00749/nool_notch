import AppKit
import Combine

enum SystemMonitorMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk, network
    var id: Self { self }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "ОЗУ"
        case .disk: "Диск"
        case .network: "Сеть"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        }
    }
}

enum SystemMonitorStyle: String, Codable, CaseIterable {
    case sidebar, stack
    var title: String { self == .sidebar ? "Боковая панель" : "Стек" }
}

enum SystemMonitorPosition: String, Codable, CaseIterable {
    case left, right, topLeft, topRight, bottomLeft, bottomRight
    var isLeft: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
    var isTop: Bool { [.topLeft, .topRight].contains(self) }
    var title: String {
        switch self {
        case .left: "Слева"
        case .right: "Справа"
        case .topLeft: "Слева сверху"
        case .topRight: "Справа сверху"
        case .bottomLeft: "Слева снизу"
        case .bottomRight: "Справа снизу"
        }
    }
}

struct SystemMonitorPreferences: Codable, Equatable {
    var enabled = false
    var style: SystemMonitorStyle = .sidebar
    var position: SystemMonitorPosition = .left
    var interval: Double = 2
    var metrics: [SystemMonitorMetric] = SystemMonitorMetric.allCases

    var sanitized: Self {
        var value = self
        value.interval = [1.0, 2, 5].contains(interval) ? interval : 2
        value.metrics = SystemMonitorMetric.allCases.filter { metrics.contains($0) }
        if value.metrics.isEmpty { value.metrics = [.cpu] }
        if style == .sidebar {
            value.position = position.isLeft ? .left : .right
        } else if position == .left || position == .right {
            value.position = position.isLeft ? .bottomLeft : .bottomRight
        }
        return value
    }
}

@MainActor
final class SystemMonitorStore: ObservableObject {
    static let preferencesKey = "nool.systemMonitor.preferences.v1"
    @Published private(set) var preferences: SystemMonitorPreferences
    @Published private(set) var snapshot: SystemMetricsSnapshot?
    private(set) var isRunning = false
    var onConfigurationChange: (() -> Void)?

    private let defaults: UserDefaults
    private let sampler: any SystemMetricsSampling
    private var pollingTask: Task<Void, Never>?
    private var generation = UUID()
    private var started = false
    private var suspensionReasons: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, sampler: any SystemMetricsSampling = SystemMetricsSampler()) {
        self.defaults = defaults
        self.sampler = sampler
        preferences = defaults.data(forKey: Self.preferencesKey).flatMap {
            try? JSONDecoder().decode(SystemMonitorPreferences.self, from: $0)
        }?.sanitized ?? SystemMonitorPreferences()
    }

    func setPreferences(_ value: SystemMonitorPreferences) {
        let value = value.sanitized
        guard value != preferences else { return }
        let restart = value.enabled != preferences.enabled || value.interval != preferences.interval
        preferences = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.preferencesKey) }
        if restart { reconcilePolling() }
        onConfigurationChange?()
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String, Bool)] = [
            (NSWorkspace.willSleepNotification, "sleep", true),
            (NSWorkspace.didWakeNotification, "sleep", false),
            (NSWorkspace.screensDidSleepNotification, "display", true),
            (NSWorkspace.screensDidWakeNotification, "display", false),
            (NSWorkspace.sessionDidResignActiveNotification, "session", true),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session", false)
        ]
        for (name, reason, suspended) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.setSuspended(suspended, reason: reason) }
            })
        }
        reconcilePolling()
        onConfigurationChange?()
    }

    func stop() {
        started = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        suspensionReasons.removeAll()
        reconcilePolling()
        onConfigurationChange?()
    }

    func setSuspended(_ suspended: Bool, reason: String) {
        guard started else { return }
        let previous = suspensionReasons
        if suspended { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        guard previous != suspensionReasons else { return }
        reconcilePolling()
        onConfigurationChange?()
    }

    private func reconcilePolling() {
        pollingTask?.cancel()
        pollingTask = nil
        generation = UUID()
        snapshot = nil
        isRunning = started && preferences.enabled && suspensionReasons.isEmpty
        guard isRunning else { return }
        let token = generation
        let interval = preferences.interval
        let sampler = sampler
        pollingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await sampler.reset()
            while !Task.isCancelled {
                let reading = await sampler.sample()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.snapshot = reading
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
    }
}
