import Foundation
import Combine

@MainActor
final class AIUsageStore: ObservableObject {
    typealias Loader = @Sendable () throws -> AIUsageSnapshot
    @Published private(set) var snapshot: AIUsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var summaries: [Int: AIUsageSummary] = [:]
    private let loader: Loader
    private var generation = 0
    private var worker: Task<Report, Error>?
    private struct Report: Sendable {
        let snapshot: AIUsageSnapshot
        let summaries: [Int: AIUsageSummary]
    }

    init(loader: @escaping Loader = { try CodexUsageReader().load() }) {
        self.loader = loader
    }

    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.loadedAt) < 60 { return }
        generation += 1
        let request = generation
        let loader = loader
        let task = Task.detached(priority: .utility) {
            let snapshot = try loader()
            try Task.checkCancellation()
            let summaries = Dictionary(uniqueKeysWithValues: [7, 30].map { days in
                (days, AIUsageSummary(events: snapshot.events, dayCount: days, now: snapshot.loadedAt))
            })
            return Report(snapshot: snapshot, summaries: summaries)
        }
        worker = task
        isLoading = true
        errorMessage = nil
        defer {
            if request == generation {
                isLoading = false
                worker = nil
            }
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard request == generation, !Task.isCancelled else { return }
            snapshot = result.snapshot
            summaries = result.summaries
        } catch is CancellationError {
            // Closing the panel is not a data error.
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            // Never surface SQLite errors or local paths from a provider.
            errorMessage = "Не удалось прочитать локальную историю Codex."
        }
    }

    func cancel() {
        generation += 1
        worker?.cancel()
        worker = nil
        isLoading = false
    }

    func clear() {
        cancel()
        snapshot = nil
        summaries = [:]
        errorMessage = nil
    }
}

struct AIUsageTotals: Equatable, Sendable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var sessions: Set<String> = []
    var total: Int64 { input + output }
    var cacheRatio: Double { input > 0 ? Double(cached) / Double(input) : 0 }

    mutating func add(_ event: AIUsageEvent) {
        input += event.inputTokens
        cached += event.cachedInputTokens
        output += event.outputTokens
        sessions.insert(event.sessionID)
    }
}

struct AIUsageDay: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var totals = AIUsageTotals()
}

struct AIUsageGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let totals: AIUsageTotals
}

struct AIUsageSummary: Sendable {
    let totals: AIUsageTotals
    let days: [AIUsageDay]
    let models: [AIUsageGroup]
    let projects: [AIUsageGroup]

    init(events: [AIUsageEvent], dayCount: Int, now: Date = .now, calendar: Calendar = .current) {
        let count = max(1, min(30, dayCount))
        let today = calendar.startOfDay(for: now)
        let dates = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let start = dates.first ?? today
        var totals = AIUsageTotals()
        var byDate = Dictionary(uniqueKeysWithValues: dates.map { ($0, AIUsageDay(date: $0)) })
        var byModel: [String: AIUsageTotals] = [:]
        var byProject: [String: AIUsageTotals] = [:]
        for event in events where event.date >= start && event.date <= now {
            totals.add(event)
            let day = calendar.startOfDay(for: event.date)
            byDate[day]?.totals.add(event)
            byModel[event.model, default: AIUsageTotals()].add(event)
            byProject[event.project, default: AIUsageTotals()].add(event)
        }
        self.totals = totals
        days = dates.compactMap { byDate[$0] }
        models = Self.groups(byModel) { $0 == "unknown" || $0.isEmpty ? "Модель не указана" : $0 }
        projects = Self.groups(byProject) {
            $0.isEmpty ? "Без проекта" : URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    private static func groups(_ data: [String: AIUsageTotals], title: (String) -> String) -> [AIUsageGroup] {
        data.map { AIUsageGroup(id: $0.key, title: title($0.key), totals: $0.value) }
            .sorted { $0.totals.total == $1.totals.total ? $0.id < $1.id : $0.totals.total > $1.totals.total }
    }
}
