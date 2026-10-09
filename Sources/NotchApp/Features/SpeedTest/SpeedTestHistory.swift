import Foundation

enum SpeedTestHistoryPeriod: String, CaseIterable, Identifiable {
    case week
    case month
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .week: "7 дней"
        case .month: "30 дней"
        case .all: "Всё время"
        }
    }

    func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
        guard date <= now else { return false }
        switch self {
        case .week, .month:
            let days = self == .week ? 6 : 29
            guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
                return false
            }
            return date >= start
        case .all:
            return true
        }
    }
}

struct SpeedTestDailyAverage: Identifiable, Equatable {
    let serverID: String
    let day: Date
    let sampleCount: Int
    let downloadMbps: Double
    let uploadMbps: Double
    let latencyMilliseconds: Double

    var id: String { "\(serverID):\(day.timeIntervalSince1970)" }
}

enum SpeedTestHistory {
    static let maxEntries = 200

    static func isValid(_ result: SpeedTestMeasurement, knownServerIDs: Set<String>) -> Bool {
        knownServerIDs.contains(result.serverID) && result.transferredBytes >= 0
            && [result.latencyMilliseconds, result.jitterMilliseconds, result.downloadMbps, result.uploadMbps]
                .allSatisfy { $0.isFinite && $0 >= 0 }
            && result.measuredAt.timeIntervalSince1970.isFinite
    }

    static func canonicalize(_ results: [SpeedTestMeasurement], knownServerIDs: Set<String>) -> [SpeedTestMeasurement] {
        var seen = Set<MeasurementIdentity>()
        return results
            .filter { isValid($0, knownServerIDs: knownServerIDs) }
            .sorted {
                if $0.measuredAt != $1.measuredAt { return $0.measuredAt > $1.measuredAt }
                if $0.serverID != $1.serverID { return $0.serverID < $1.serverID }
                let left = [$0.downloadMbps, $0.uploadMbps, $0.latencyMilliseconds, $0.jitterMilliseconds]
                let right = [$1.downloadMbps, $1.uploadMbps, $1.latencyMilliseconds, $1.jitterMilliseconds]
                if left != right { return left.lexicographicallyPrecedes(right) }
                return $0.transferredBytes < $1.transferredBytes
            }
            .filter { seen.insert(MeasurementIdentity(serverID: $0.serverID, measuredAt: $0.measuredAt)).inserted }
            .prefix(maxEntries)
            .map { $0 }
    }

    static func filter(_ results: [SpeedTestMeasurement], period: SpeedTestHistoryPeriod,
                       now: Date = Date(), calendar: Calendar = .current) -> [SpeedTestMeasurement] {
        results.filter { period.contains($0.measuredAt, now: now, calendar: calendar) }
    }

    static func dailyAverages(_ results: [SpeedTestMeasurement], calendar: Calendar = .current) -> [SpeedTestDailyAverage] {
        struct Key: Hashable {
            let serverID: String
            let day: Date
        }
        let groups = Dictionary(grouping: results) {
            Key(serverID: $0.serverID, day: calendar.startOfDay(for: $0.measuredAt))
        }
        return groups.map { key, samples in
            return SpeedTestDailyAverage(
                serverID: key.serverID,
                day: key.day,
                sampleCount: samples.count,
                downloadMbps: average(samples, \.downloadMbps),
                uploadMbps: average(samples, \.uploadMbps),
                latencyMilliseconds: average(samples, \.latencyMilliseconds)
            )
        }
        .sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.serverID < $1.serverID
        }
    }

    private static func average(_ samples: [SpeedTestMeasurement], _ keyPath: KeyPath<SpeedTestMeasurement, Double>) -> Double {
        samples.enumerated().reduce(0) { mean, pair in
            mean + (pair.element[keyPath: keyPath] - mean) / Double(pair.offset + 1)
        }
    }

    private struct MeasurementIdentity: Hashable {
        let serverID: String
        let measuredAt: Date
    }
}
