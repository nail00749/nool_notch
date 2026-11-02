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

enum SystemMemoryPressure: Sendable, Equatable {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: "Нормальное"
        case .warning: "Повышенное"
        case .critical: "Критическое"
        }
    }
}

struct SystemMemoryDetails: Sendable, Equatable {
    /// Physical pages occupied by the compressed pager, not their uncompressed size.
    let compressedBytes: UInt64?
    /// Mach external_page_count: file-backed (non-swap) pages. This is not an
    /// assertion that the value exactly matches Activity Monitor's cached-files total.
    let cachedBytes: UInt64?
    let wiredBytes: UInt64?
    let swapUsedBytes: UInt64?
    let swapTotalBytes: UInt64?
    let pressure: SystemMemoryPressure?

    init(compressedBytes: UInt64? = nil, cachedBytes: UInt64? = nil, wiredBytes: UInt64? = nil,
         swapUsedBytes: UInt64? = nil, swapTotalBytes: UInt64? = nil, pressure: SystemMemoryPressure? = nil) {
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.wiredBytes = wiredBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }
}

struct SystemMetricsSnapshot: Sendable, Equatable {
    let sampledAt: Date
    let cpuFraction: Double?
    let memory: SystemResourceUsage?
    let disk: SystemResourceUsage?
    let network: SystemNetworkRate?
    let memoryDetails: SystemMemoryDetails?

    init(sampledAt: Date, cpuFraction: Double?, memory: SystemResourceUsage?, disk: SystemResourceUsage?,
         network: SystemNetworkRate?, memoryDetails: SystemMemoryDetails? = nil) {
        self.sampledAt = sampledAt
        self.cpuFraction = cpuFraction
        self.memory = memory
        self.disk = disk
        self.network = network
        self.memoryDetails = memoryDetails
    }
}

protocol SystemMetricsSampling: Sendable {
    func sample() async -> SystemMetricsSnapshot
    func reset() async
}
