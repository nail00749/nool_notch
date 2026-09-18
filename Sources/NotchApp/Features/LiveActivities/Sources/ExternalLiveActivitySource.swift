import Foundation

enum ExternalLiveActivityParser {
    static let maximumDataSize = 256 * 1_024
    private static let maximumActivityCount = 64
    private static let maximumIDLength = 128
    private static let maximumTitleLength = 80
    private static let maximumDetailLength = 160

    enum ParseError: Error {
        case oversized
    }

    private struct Envelope: Decodable {
        let version: Int
        let activities: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let kind: String
        let title: String
        let detail: String?
        let progress: Double?
        let startedAt: TimeInterval?
        let endsAt: TimeInterval?
        let updatedAt: TimeInterval
        let expiresAt: TimeInterval?
    }

    static func activities(from data: Data, now: Date) throws -> [LiveActivity] {
        guard data.count <= maximumDataSize else { throw ParseError.oversized }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { return [] }
        var byID: [String: LiveActivity] = [:]
        for entry in envelope.activities.prefix(maximumActivityCount) {
            let externalID = bounded(entry.id, limit: maximumIDLength)
            let title = bounded(entry.title, limit: maximumTitleLength)
            guard let kind = LiveActivityKind(rawValue: entry.kind),
                  externalID.isEmpty == false,
                  title.isEmpty == false,
                  entry.expiresAt.map({ Date(timeIntervalSince1970: $0) > now }) ?? true else {
                continue
            }
            let updatedAt = Date(timeIntervalSince1970: entry.updatedAt)
            let activity = LiveActivity(
                id: "external-\(externalID)",
                sourceID: "external-live-bridge",
                kind: kind,
                title: title,
                detail: entry.detail.map { bounded($0, limit: maximumDetailLength) },
                state: .active,
                progress: entry.progress.map { min(1, max(0, $0)) },
                startedAt: entry.startedAt.map(Date.init(timeIntervalSince1970:)),
                endsAt: entry.endsAt.map(Date.init(timeIntervalSince1970:)),
                updatedAt: updatedAt,
                isCompactEligible: true
            )
            if byID[activity.id].map({ $0.updatedAt <= activity.updatedAt }) ?? true {
                byID[activity.id] = activity
            }
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

@MainActor
final class ExternalLiveActivitySource: LiveActivitySource {
    let id = "external-live-bridge"
    let displayName = "Внешние активности"
    var onChange: (([LiveActivity]) -> Void)?

    private let fileURL: URL?
    private var pollTask: Task<Void, Never>?

    init(fileURL: URL? = ExternalLiveActivitySource.defaultFileURL) {
        self.fileURL = fileURL
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        guard let fileURL else { return }
        let activities = await Task.detached(priority: .utility) { () -> [LiveActivity] in
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
            defer { try? handle.close() }
            guard let data = try? handle.read(
                upToCount: ExternalLiveActivityParser.maximumDataSize + 1
            ) else { return [] }
            return (try? ExternalLiveActivityParser.activities(from: data, now: .now)) ?? []
        }.value
        guard Task.isCancelled == false else { return }
        onChange?(activities)
    }

    nonisolated static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nool", isDirectory: true)
            .appendingPathComponent("live-activities.json")
    }
}
