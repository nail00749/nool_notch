import Foundation

struct DownloadSnapshot: Equatable, Sendable {
    let id: String
    let title: String
    let byteCount: Int64
    let finalFileExists: Bool
}

struct DownloadActivityTracker: Sendable {
    private struct Record: Sendable {
        let snapshot: DownloadSnapshot
        let startedAt: Date
        let observedAt: Date
        var completedAt: Date?
    }

    private var hasSeeded = false
    private var records: [String: Record] = [:]

    mutating func consume(_ snapshots: [DownloadSnapshot], now: Date) -> [LiveActivity] {
        let incoming = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for (id, snapshot) in incoming {
            if snapshot.finalFileExists {
                if var record = records[id], record.completedAt == nil {
                    record.completedAt = now
                    records[id] = record
                }
            } else if records[id] == nil {
                records[id] = Record(
                    snapshot: snapshot,
                    startedAt: now,
                    observedAt: hasSeeded ? now : now.addingTimeInterval(-12),
                    completedAt: nil
                )
            } else if var record = records[id], record.completedAt == nil {
                record = Record(
                    snapshot: snapshot,
                    startedAt: record.startedAt,
                    observedAt: record.observedAt,
                    completedAt: nil
                )
                records[id] = record
            }
        }
        hasSeeded = true
        for (id, record) in records where incoming[id] == nil && record.completedAt == nil {
            records[id] = nil
        }
        records = records.filter { _, record in
            guard let completedAt = record.completedAt else { return true }
            return now.timeIntervalSince(completedAt) < 12
        }

        return records.values.map { record in
            if let completedAt = record.completedAt {
                return LiveActivity(
                    id: "download-\(record.snapshot.id)", sourceID: "system-downloads",
                    kind: .download, title: "Загрузка · \(record.snapshot.title)",
                    detail: "Готово · \(LiveActivityClock.elapsedText(from: record.startedAt, to: completedAt))",
                    state: .notification, progress: 1, startedAt: record.startedAt,
                    endsAt: completedAt, updatedAt: completedAt, isCompactEligible: true
                )
            }
            let elapsed = LiveActivityClock.elapsedText(from: record.startedAt, to: now)
            return LiveActivity(
                id: "download-\(record.snapshot.id)", sourceID: "system-downloads",
                kind: .download, title: "Загрузка · \(record.snapshot.title)",
                detail: "\(elapsed) · \(Self.byteText(record.snapshot.byteCount))",
                state: .active, progress: nil, startedAt: record.startedAt,
                endsAt: nil, updatedAt: record.observedAt, isCompactEligible: true
            )
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
            .replacingOccurrences(of: "MB", with: "МБ")
            .replacingOccurrences(of: "KB", with: "КБ")
            .replacingOccurrences(of: "GB", with: "ГБ")
    }
}

@MainActor
final class SystemDownloadActivitySource: LiveActivitySource {
    let id = "system-downloads"
    let displayName = "Загрузки"
    var onChange: (([LiveActivity]) -> Void)?

    private var tracker = DownloadActivityTracker()
    private var knownDownloads: [String: DownloadSnapshot] = [:]
    private var pollTask: Task<Void, Never>?
    private let downloadsURL: URL?

    init(downloadsURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) {
        self.downloadsURL = downloadsURL
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
        guard let downloadsURL else { return }
        let previous = Array(knownDownloads.values)
        let snapshots = await Task.detached(priority: .utility) {
            Self.scan(downloadsURL, previous: previous)
        }.value
        guard Task.isCancelled == false else { return }
        knownDownloads = Dictionary(
            uniqueKeysWithValues: snapshots.filter { $0.finalFileExists == false }.map { ($0.id, $0) }
        )
        onChange?(tracker.consume(snapshots, now: .now))
    }

    nonisolated private static func scan(
        _ directory: URL,
        previous: [DownloadSnapshot]
    ) -> [DownloadSnapshot] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return [] }
        let partialExtensions = ["crdownload", "part", "download"]
        let active: [DownloadSnapshot] = files.compactMap { url in
            guard partialExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true || values.isDirectory == true else { return nil }
            let finalURL = url.deletingPathExtension()
            let title = finalURL.lastPathComponent
            return DownloadSnapshot(
                id: url.path, title: title,
                byteCount: Int64(values.fileSize ?? 0),
                finalFileExists: FileManager.default.fileExists(atPath: finalURL.path)
            )
        }
        let activeIDs = Set(active.map(\.id))
        let completed = previous.compactMap { snapshot -> DownloadSnapshot? in
            guard activeIDs.contains(snapshot.id) == false else { return nil }
            let finalURL = URL(fileURLWithPath: snapshot.id).deletingPathExtension()
            guard FileManager.default.fileExists(atPath: finalURL.path) else { return nil }
            return DownloadSnapshot(
                id: snapshot.id,
                title: snapshot.title,
                byteCount: snapshot.byteCount,
                finalFileExists: true
            )
        }
        return active + completed
    }
}
