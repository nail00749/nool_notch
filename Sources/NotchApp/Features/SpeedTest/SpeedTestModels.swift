import Foundation

struct SpeedTestServer: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let provider: String
    let downloadURL: URL
    let probeURL: URL

    static let defaults: [SpeedTestServer] = [
        SpeedTestServer(
            id: "moscow-cloud4box",
            title: "Москва",
            provider: "Cloud4box",
            downloadURL: URL(string: "https://ru.lg.cloud4box.com/garbage")!,
            probeURL: URL(string: "https://ru.lg.cloud4box.com/empty")!
        ),
        SpeedTestServer(
            id: "frankfurt-clouvider",
            title: "Франкфурт",
            provider: "Clouvider",
            downloadURL: URL(string: "https://fra.speedtest.clouvider.net/backend/garbage.php")!,
            probeURL: URL(string: "https://fra.speedtest.clouvider.net/backend/empty.php")!
        )
    ]
}

enum SpeedTestPhase: String, Codable, Sendable {
    case latency
    case download
    case upload
}

struct SpeedTestProgress: Sendable {
    let phase: SpeedTestPhase
    let fraction: Double
    let megabitsPerSecond: Double?

    init(phase: SpeedTestPhase, fraction: Double, megabitsPerSecond: Double? = nil) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.megabitsPerSecond = megabitsPerSecond
    }
}

struct SpeedTestMeasurement: Codable, Equatable, Sendable {
    let serverID: String
    let measuredAt: Date
    let latencyMilliseconds: Double
    let jitterMilliseconds: Double
    let downloadMbps: Double
    let uploadMbps: Double
    let transferredBytes: Int64
}

protocol SpeedTestRunning: Sendable {
    func run(
        server: SpeedTestServer,
        onProgress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestMeasurement
}
