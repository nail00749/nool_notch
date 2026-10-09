import Combine
import Foundation
import NotchCore

@MainActor
final class QuotaAlertController: ObservableObject {
    @Published private(set) var options: [String: QuotaAlertOptions]
    @Published private(set) var authorization: QuotaAlertAuthorization = .notRequested
    @Published private(set) var message: String?
    @Published private(set) var isRequesting = false
    private var policy: QuotaAlertPolicy
    private let defaults: UserDefaults
    private let delivery: any QuotaAlertDelivering
    private var monitor: Task<Void, Never>?
    private var deliveries: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var suspended = false
    private var lifecycleGeneration: UInt = 0
    private static let optionsKey = "nool.quotaAlerts.options.v1"
    private static let policyKey = "nool.quotaAlerts.state.v1"

    init(defaults: UserDefaults = .standard, delivery: any QuotaAlertDelivering) {
        self.defaults = defaults
        self.delivery = delivery
        options = defaults.data(forKey: Self.optionsKey).flatMap {
            try? JSONDecoder().decode([String: QuotaAlertOptions].self, from: $0)
        } ?? [:]
        policy = defaults.data(forKey: Self.policyKey).flatMap {
            try? JSONDecoder().decode(QuotaAlertPolicy.self, from: $0)
        } ?? QuotaAlertPolicy()
    }

    func configuration(for id: String) -> QuotaAlertOptions { options[id] ?? QuotaAlertOptions() }

    func start(refresh: @escaping @MainActor ([String]) -> Void) {
        guard monitor == nil, !stopped else { return }
        suspended = false
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshAuthorization()
                guard !Task.isCancelled, self?.stopped == false, self?.suspended == false else { return }
                if self?.authorization == .allowed {
                    refresh(self?.options.filter { $0.value.enabled }.map(\.key) ?? [])
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func refreshAuthorization() async {
        guard !stopped, !suspended else { return }
        let generation = lifecycleGeneration
        let status = await delivery.authorization()
        guard !stopped, !suspended, generation == lifecycleGeneration else { return }
        authorization = status
    }

    func setOptions(_ value: QuotaAlertOptions, for id: String) {
        guard !stopped, !suspended else { return }
        options[id] = value
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.optionsKey) }
    }

    func enable(_ enabled: Bool, for id: String) async {
        guard !isRequesting, !stopped, !suspended else { return }
        let generation = lifecycleGeneration
        if enabled {
            isRequesting = true
            defer { isRequesting = false }
            await refreshAuthorization()
            guard !stopped, !suspended, generation == lifecycleGeneration else { return }
            if authorization == .notRequested {
                do { _ = try await delivery.requestAuthorization() }
                catch {
                    guard !stopped, !suspended, generation == lifecycleGeneration else { return }
                    message = "Не удалось запросить разрешение на уведомления."
                    return
                }
                await refreshAuthorization()
                guard !stopped, !suspended, generation == lifecycleGeneration else { return }
            }
            guard !stopped, !suspended, generation == lifecycleGeneration else { return }
            guard authorization == .allowed else {
                message = "Разрешите уведомления для NooL App в Системных настройках → Уведомления."
                return
            }
        }
        var value = configuration(for: id)
        guard !stopped, !suspended, generation == lifecycleGeneration else { return }
        value.enabled = enabled
        setOptions(value, for: id)
        message = nil
    }

    func consume(_ snapshot: QuotaSnapshot, now: Date) {
        guard !stopped, !suspended, authorization == .allowed else { return }
        let events = policy.consume(snapshot, options: configuration(for: snapshot.providerID), now: now)
        if let data = try? JSONEncoder().encode(policy) { defaults.set(data, forKey: Self.policyKey) }
        for event in events {
            let id = UUID()
            deliveries[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.deliveries[id] = nil }
                guard !Task.isCancelled, !self.stopped, !self.suspended,
                      self.configuration(for: event.providerID).enabled else { return }
                do { try await self.delivery.deliver(event) }
                catch {
                    guard !Task.isCancelled, !self.stopped, !self.suspended else { return }
                    self.message = "Не удалось доставить уведомление о лимите. Проверьте настройки уведомлений macOS."
                }
            }
        }
    }

    func stop() {
        stopped = true
        suspend()
    }

    func suspend() {
        lifecycleGeneration &+= 1
        suspended = true
        monitor?.cancel()
        monitor = nil
        deliveries.values.forEach { $0.cancel() }
        deliveries.removeAll()
    }

    deinit {
        monitor?.cancel()
        deliveries.values.forEach { $0.cancel() }
    }
}
