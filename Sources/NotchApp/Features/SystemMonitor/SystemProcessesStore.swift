import Combine
import Foundation

@MainActor
final class SystemProcessesStore: ObservableObject {
    @Published var sort: SystemProcessSort = .cpu
    @Published private(set) var snapshot: SystemProcessSnapshot?
    @Published private(set) var isRunning = false
    @Published private(set) var sampleCount = 0
    private let sampler: any SystemProcessSampling
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(sampler: any SystemProcessSampling = SystemProcessSampler()) {
        self.sampler = sampler
    }

    var topProcesses: [MonitoredSystemProcess] {
        (snapshot?.topProcesses(sortedBy: sort) ?? [])
            .filter { sort != .cpu || $0.cpuPercent != nil }
    }

    var isWarmingUp: Bool {
        isRunning && (snapshot == nil || (sort == .cpu && sampleCount < 2))
    }

    func start(sort: SystemProcessSort) {
        self.sort = sort
        guard task == nil else { return }
        generation = UUID()
        let token = generation
        snapshot = nil
        sampleCount = 0
        isRunning = true
        let sampler = sampler
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await sampler.reset()
            while !Task.isCancelled {
                let reading = await sampler.sample()
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.snapshot = reading
                self.sampleCount += 1
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
        snapshot = nil
        sampleCount = 0
    }
}
