import Combine
import Foundation

/// One network test at a time, shared by the Dock and the standalone window.
@MainActor
final class SpeedTestSession: ObservableObject {
    static let shared = SpeedTestSession(modules: .shared)
    let http: SpeedTestStore
    let iperf: IperfTestStore
    let diagnostics: NetworkDiagnosticsStore
    @Published private(set) var activeRunID: UUID?
    private let modules: AppModuleStore
    private var subscriptions: Set<AnyCancellable> = []

    init(http: SpeedTestStore = SpeedTestStore(), iperf: IperfTestStore = IperfTestStore(),
         diagnostics: NetworkDiagnosticsStore = NetworkDiagnosticsStore(),
         modules: AppModuleStore = AppModuleStore(defaults: nil)) {
        self.http = http
        self.iperf = iperf
        self.diagnostics = diagnostics
        self.modules = modules
        Publishers.Merge3(http.objectWillChange, iperf.objectWillChange, diagnostics.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.isRunning && !self.isCancelling { self.activeRunID = nil }
                self.objectWillChange.send()
            }
            .store(in: &subscriptions)
        modules.changes.sink { [weak self] _ in
            guard let self else { return }
            if !self.modules.isEnabled(.networkTools) { self.cancel() }
            self.objectWillChange.send()
        }.store(in: &subscriptions)
    }

    var isRunning: Bool { http.isRunning || iperf.isRunning || diagnostics.isRunning }
    var isCancelling: Bool { http.isCancelling || iperf.isCancelling || diagnostics.isCancelling }
    private var canStart: Bool { modules.isEnabled(.networkTools) && !isRunning && !isCancelling }

    @discardableResult
    func startHTTP(serverID: String? = nil) -> Bool {
        guard canStart else { return false }
        http.start(serverID: serverID)
        if http.isRunning { activeRunID = UUID() }
        return http.isRunning
    }

    @discardableResult
    func startIperf() -> Bool {
        guard canStart else { return false }
        iperf.start()
        if iperf.isRunning { activeRunID = UUID() }
        return iperf.isRunning
    }

    @discardableResult
    func startDiagnostics() -> Bool {
        guard canStart else { return false }
        diagnostics.start()
        if diagnostics.isRunning { activeRunID = UUID() }
        return diagnostics.isRunning
    }

    func cancel() { http.cancel(); iperf.cancel(); diagnostics.cancel() }

    func waitForCompletion() async {
        await http.waitForCompletion()
        await iperf.waitForCompletion()
        await diagnostics.waitForCompletion()
    }
}
