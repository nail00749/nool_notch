import Foundation

/// The extension receives only display data, never credentials, source URLs or account messages.
public enum QuotaWidgetPeriod: String, Codable, CaseIterable, Sendable {
    case fiveHours
    case week

    public var label: String { self == .fiveHours ? "5h" : "7d" }
}

public struct QuotaWidgetWindow: Codable, Equatable, Sendable {
    public let label: String
    public let remainingRatio: Double?
    public let resetAt: Date?

    public init(label: String, remainingRatio: Double?, resetAt: Date?) {
        self.label = String(label.prefix(120))
        self.remainingRatio = remainingRatio.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.resetAt = resetAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }
}

public struct QuotaWidgetProvider: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let windows: [QuotaWidgetWindow]
    public let connection: ProviderConnectionState
    public let updatedAt: Date

    public init(snapshot: QuotaSnapshot) {
        id = String(snapshot.providerID.prefix(120))
        name = String(snapshot.providerName.prefix(80))
        connection = snapshot.connection
        updatedAt = snapshot.updatedAt
        windows = snapshot.windows.filter { $0.unit == .percentage }.prefix(16).map {
            QuotaWidgetWindow(label: $0.label, remainingRatio: $0.remainingRatio, resetAt: $0.resetAt)
        }
    }

    public func window(for period: QuotaWidgetPeriod) -> QuotaWidgetWindow? {
        guard connection == .live || connection == .stale else { return nil }
        return windows.first { $0.label == period.label }
            ?? windows.first { $0.label.hasSuffix("· \(period.label)") }
    }

    public func percentage(for period: QuotaWidgetPeriod) -> Int? {
        guard let ratio = window(for: period)?.remainingRatio, ratio.isFinite else { return nil }
        return Int((min(max(ratio, 0), 1) * 100).rounded())
    }

    public func isStale(window: QuotaWidgetWindow?, at date: Date) -> Bool {
        connection == .stale
            || date.timeIntervalSince(updatedAt) >= 15 * 60
            || updatedAt.timeIntervalSince(date) > 60
            || (window?.resetAt.map { $0 <= date } ?? false)
    }
}

public struct QuotaWidgetData: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let providers: [QuotaWidgetProvider]

    public init(generatedAt: Date = Date(), providers: [QuotaWidgetProvider]) {
        schemaVersion = 1
        self.generatedAt = generatedAt
        self.providers = Array(providers.prefix(8))
    }

    public static let empty = QuotaWidgetData(generatedAt: .distantPast, providers: [])
}

public enum QuotaWidgetStore {
    public static let kind = "NoolQuotaWidget"
    public static let maximumBytes = 64 * 1024

    public static func containerFileURL(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "NoolWidgetAppGroup") as? String,
              !group.isEmpty, !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appendingPathComponent("quota-widget-v1.json", isDirectory: false)
    }

    /// Bounded read: a corrupt, missing, or newer payload is an empty state, never demo data.
    public static func read(from url: URL?) -> QuotaWidgetData {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(QuotaWidgetData.self, from: data),
              snapshot.schemaVersion == 1, snapshot.providers.count <= 8,
              snapshot.generatedAt.timeIntervalSince1970.isFinite,
              Set(snapshot.providers.map(\.id)).count == snapshot.providers.count,
              snapshot.providers.allSatisfy({ provider in
                  provider.id.count <= 120 && provider.name.count <= 80
                      && provider.updatedAt.timeIntervalSince1970.isFinite
                      && provider.windows.count <= 16
                      && provider.windows.allSatisfy { window in
                          window.label.count <= 120
                              && (window.remainingRatio.map { $0.isFinite && (0...1).contains($0) } ?? true)
                              && (window.resetAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
                      }
              }) else { return .empty }
        return snapshot
    }

    public static func write(_ snapshot: QuotaWidgetData, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
