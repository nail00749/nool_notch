import Combine
import Foundation

@MainActor
final class IperfTestStore: ObservableObject {
    @Published var configuration: IperfTestConfiguration { didSet { persistConfiguration() } }
    var config: IperfTestConfiguration {
        get { configuration }
        set { configuration = newValue }
    }
    @Published private(set) var result: IperfTestResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastError: IperfTestError?
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var phaseTitle = "Готов к тесту iperf3"
    private let runner: any IperfTestRunning
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private static let configurationKey = "nool.iperf.configuration.v1"

    init(runner: any IperfTestRunning = IperfTestRunner(), defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.configurationKey)
            .flatMap { try? JSONDecoder().decode(IperfTestConfiguration.self, from: $0) } ?? .init()
    }

    func start() {
        guard task == nil else { return }
        errorMessage = nil
        lastError = nil
        if let error = configuration.validationError {
            fail(.invalidConfiguration(error))
            return
        }
        let configuration = configuration
        let token = UUID()
        generation = token
        isRunning = true
        isCancelling = false
        phaseTitle = "Подключение к серверу iperf3…"
        let runner = runner
        task = Task { @MainActor [weak self] in
            defer {
                self?.isRunning = false
                self?.isCancelling = false
                self?.task = nil
            }
            do {
                let result = try await runner.run(configuration: configuration) { [weak self] phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.isRunning, !self.isCancelling else { return }
                        self.phaseTitle = phase
                    }
                }
                try Task.checkCancellation()
                guard Self.isValid(result, configuration: configuration) else { throw IperfTestError.invalidResponse }
                self?.result = result
                self?.phaseTitle = "Тест iperf3 завершён"
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? IperfTestError) == .cancelled {
                    self?.phaseTitle = "Тест iperf3 отменён"
                } else { self?.fail((error as? IperfTestError) ?? .invalidResponse) }
            }
        }
    }

    func cancel() {
        guard task != nil else { return }
        generation = UUID()
        isCancelling = true
        phaseTitle = "Остановка iperf3…"
        task?.cancel()
    }

    func waitForCompletion() async { await task?.value }

    private func fail(_ error: IperfTestError) {
        lastError = error
        errorMessage = error.localizedDescription
        phaseTitle = "Тест iperf3 не выполнен"
    }

    private func persistConfiguration() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.configurationKey) }
    }

    private static func isValid(_ result: IperfTestResult, configuration: IperfTestConfiguration) -> Bool {
        result.host == configuration.validatedHost && result.transport == configuration.transport
            && result.downloadMbps.isFinite && result.downloadMbps >= 0
            && result.uploadMbps.isFinite && result.uploadMbps >= 0
            && result.measuredAt.timeIntervalSince1970.isFinite
            && (result.jitterMilliseconds.map { $0.isFinite && $0 >= 0 } ?? (result.transport == .tcp))
            && (result.lossPercent.map { $0.isFinite && (0...100).contains($0) } ?? (result.transport == .tcp))
    }

    deinit { task?.cancel() }
}
