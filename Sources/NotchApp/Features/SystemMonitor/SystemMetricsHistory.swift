import Foundation

/// Short, in-memory history; never bridges sleep or a restarted sampler.
struct SystemMetricsHistory {
    private(set) var samples: [SystemMetricsSnapshot] = []
    let duration: TimeInterval = 120
    let limit = 120

    mutating func append(_ sample: SystemMetricsSnapshot) {
        guard sample.sampledAt.timeIntervalSince1970.isFinite else { return }
        if let last = samples.last, sample.sampledAt < last.sampledAt { samples.removeAll() }
        if samples.last?.sampledAt == sample.sampledAt { samples.removeLast() }
        samples.append(sample)
        let cutoff = sample.sampledAt.addingTimeInterval(-duration)
        samples.removeAll { $0.sampledAt < cutoff }
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }
}
