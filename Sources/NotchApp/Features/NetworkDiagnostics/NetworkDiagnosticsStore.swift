import Combine
import Foundation

@MainActor
final class NetworkDiagnosticsStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var report: NetworkDiagnosticsReport?
    @Published private(set) var errorMessage: String?

    private let runner: any NetworkDiagnosticsRunning
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(runner: any NetworkDiagnosticsRunning = SystemNetworkDiagnosticsRunner()) {
        self.runner = runner
    }

    func start() {
        guard task == nil else { return }
        let token = UUID()
        generation = token
        isRunning = true
        isCancelling = false
        errorMessage = nil
        report = nil
        let runner = self.runner
        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.isCancelling = false
                self?.task = nil
            }
            do {
                let result = try await runner.run()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.report = result
            } catch is CancellationError {
                // Cancellation owns the visible state until the runner has unwound.
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.errorMessage = "Диагностика не завершилась. Повторите проверку."
            }
        }
    }

    func cancel() {
        guard task != nil, !isCancelling else { return }
        generation = UUID()
        isCancelling = true
        task?.cancel()
    }

    func waitForCompletion() async { await task?.value }

    deinit { task?.cancel() }
}
