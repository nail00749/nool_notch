import Foundation
import NotchCore
import WidgetKit

/// Serializes display snapshots outside the main actor; the widget never runs providers itself.
@MainActor
final class QuotaWidgetPublisher {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nailuyltyev.NotchApp.quota-widget", qos: .utility)
    private var monitorTask: Task<Void, Never>?
    private var stopped = false
    private var lastProviders: [QuotaWidgetProvider]?
    private let reload: @Sendable () -> Void

    static var isBundled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NoolWidgetAppGroup") is String
            && Bundle.main.builtInPlugInsURL.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("NoolQuotaWidget.appex").path)
            } == true
    }

    static func makeIfAvailable() -> QuotaWidgetPublisher? {
        guard isBundled, let url = QuotaWidgetStore.containerFileURL() else { return nil }
        return QuotaWidgetPublisher(fileURL: url)
    }

    init(fileURL: URL, reload: @escaping @Sendable () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: QuotaWidgetStore.kind)
    }) {
        self.fileURL = fileURL
        self.reload = reload
    }

    private nonisolated static func hasInstalledWidget() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let installed = (try? result.get())?.contains { $0.kind == QuotaWidgetStore.kind } == true
                continuation.resume(returning: installed)
            }
        }
    }

    func start(refresh: @escaping @MainActor () -> Void) {
        guard monitorTask == nil, !stopped else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let installed = await Self.hasInstalledWidget()
                guard !Task.isCancelled, self?.stopped == false else { return }
                if installed {
                    refresh()
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func publish(_ providers: [QuotaWidgetProvider]) {
        guard !stopped, lastProviders != providers else { return }
        lastProviders = providers
        let snapshot = QuotaWidgetData(providers: providers)
        let url = fileURL
        let reload = reload
        queue.async {
            do {
                try QuotaWidgetStore.write(snapshot, to: url)
                reload()
            } catch {
                // Keep the last atomic snapshot. Its timestamp will make failure visible as stale.
            }
        }
    }

    func stop() {
        stopped = true
        monitorTask?.cancel()
        monitorTask = nil
    }

    func waitForPersistence() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    deinit { monitorTask?.cancel() }
}
