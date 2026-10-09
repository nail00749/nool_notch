import Foundation

struct SystemResourceUsage: Sendable, Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
    }
}

struct SystemNetworkRate: Sendable, Equatable {
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double
}

struct SystemMetricsSnapshot: Sendable, Equatable {
    let sampledAt: Date
    let cpuFraction: Double?
    let memory: SystemResourceUsage?
    let disk: SystemResourceUsage?
    let network: SystemNetworkRate?
}

protocol SystemMetricsSampling: Sendable {
    func sample() async -> SystemMetricsSnapshot
    func reset() async
}
