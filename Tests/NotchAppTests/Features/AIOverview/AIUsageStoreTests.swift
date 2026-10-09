import Foundation
import XCTest
@testable import NotchApp

final class AIUsageSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testPeriodsZeroFillDaysAndUseEventDatesNotSessionLastActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            event("a", date: now, session: "same", project: "/one/app", input: 100, cached: 70),
            event("b", date: now.addingTimeInterval(-86_400), session: "same", project: "/one/app", input: 200),
            event("c", date: now.addingTimeInterval(-9 * 86_400), input: 300),
            event("future", date: now.addingTimeInterval(100), input: 999)
        ]
        let week = AIUsageSummary(events: events, dayCount: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.filter { $0.totals.total == 0 }.count, 5)
        XCTAssertEqual(week.totals.input, 300)
        XCTAssertEqual(week.totals.output, 20)
        XCTAssertEqual(week.totals.total, 320)
        XCTAssertEqual(week.totals.sessions.count, 1)
        XCTAssertEqual(week.totals.cacheRatio, 70.0 / 300.0, accuracy: 0.0001)
        let month = AIUsageSummary(events: events, dayCount: 30, now: now, calendar: calendar)
        XCTAssertEqual(month.totals.input, 600)
        XCTAssertEqual(month.days.count, 30)
    }

    func testProjectIdentityPreservesDistinctPathsAndModelsSortByUsage() {
        let now = Date()
        let summary = AIUsageSummary(events: [
            event("a", date: now, model: "model-a", project: "/one/app", input: 100),
            event("b", date: now, model: "model-b", project: "/two/app", input: 200),
            event("c", date: now, model: "unknown", project: "", input: 1)
        ], dayCount: 7, now: now, calendar: calendar)
        XCTAssertEqual(summary.projects.count, 3)
        XCTAssertEqual(Set(summary.projects.map(\.id)).count, 3)
        XCTAssertEqual(summary.models.first?.title, "model-b")
        XCTAssertEqual(summary.models.last?.title, "Модель не указана")
        XCTAssertEqual(summary.projects.last?.title, "Без проекта")
    }

    private func event(_ id: String, date: Date, session: String = "session", model: String = "model",
                       project: String = "/project", input: Int64, cached: Int64 = 0) -> AIUsageEvent {
        AIUsageEvent(id: id, date: date, sessionID: session, model: model, project: project,
                     inputTokens: input, cachedInputTokens: cached, outputTokens: 10)
    }
}

@MainActor
final class AIUsageStoreTests: XCTestCase {
    func testRefreshCachesAndFailureKeepsLastSuccessfulSnapshot() async {
        let loader = UsageTestLoader()
        let store = AIUsageStore(loader: { try loader.load() })
        await store.refresh()
        XCTAssertNotNil(store.snapshot)
        XCTAssertNotNil(store.summaries[7])
        XCTAssertEqual(loader.count, 1)
        await store.refresh()
        XCTAssertEqual(loader.count, 1)
        await store.refresh(force: true)
        XCTAssertEqual(loader.count, 2)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNotNil(store.snapshot)
        XCTAssertFalse(store.isLoading)
        store.clear()
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testCancelledLoadCannotRepopulateClearedModule() async {
        let gate = UsageTestGate()
        let store = AIUsageStore(loader: {
            _ = gate.release.wait(timeout: .now() + 2)
            return AIUsageSnapshot(events: [], loadedAt: .now, isPartial: false,
                                   scannedSessionCount: 0, skippedSessionCount: 0)
        })
        let refresh = Task { await store.refresh() }
        while !store.isLoading { await Task.yield() }
        store.clear()
        gate.release.signal()
        await refresh.value
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertFalse(store.isLoading)
    }
}

private final class UsageTestGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
}

private final class UsageTestLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func load() throws -> AIUsageSnapshot {
        let current = lock.withLock { calls += 1; return calls }
        if current > 1 { throw AIUsageReaderError.databaseUnavailable }
        return AIUsageSnapshot(events: [], loadedAt: .now, isPartial: false,
                               scannedSessionCount: 0, skippedSessionCount: 0)
    }
}
