import XCTest
@testable import NotchApp

@MainActor
final class SpeedTestStoreTests: XCTestCase {
    func testSequentialServersAndPersistence() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = RecordingSpeedTestRunner()
        let store = SpeedTestStore(runner: runner, defaults: defaults)
        XCTAssertFalse(store.isRunning)
        let initialCalls = await runner.calls()
        XCTAssertTrue(initialCalls.isEmpty)
        store.start()
        store.start()
        await store.waitForCompletion()
        let calls = await runner.calls()
        XCTAssertEqual(calls, SpeedTestServer.defaults.map(\.id))
        XCTAssertFalse(store.isRunning)
        for server in store.servers {
            XCTAssertEqual(store.states[server.id]?.status, .completed)
        }
        XCTAssertEqual(store.history.count, store.servers.count)
        let reloaded = SpeedTestStore(runner: runner, defaults: defaults)
        XCTAssertEqual(reloaded.history, store.history)
        for server in store.servers {
            XCTAssertEqual(reloaded.states[server.id]?.result, store.states[server.id]?.result)
        }
    }

    func testFailureDoesNotSkipOtherServerAndRetainsPreviousSuccess() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults)
        good.start()
        await good.waitForCompletion()
        let first = good.servers[0].id
        let runner = RecordingSpeedTestRunner(failingID: first)
        let store = SpeedTestStore(runner: runner, defaults: defaults)
        let previous = store.states[first]?.result
        let previousHistory = store.history
        store.start()
        await store.waitForCompletion()
        if case .failed = store.states[first]?.status {} else { XCTFail("Expected failure") }
        XCTAssertEqual(store.states[first]?.result, previous)
        XCTAssertEqual(store.history.count, previousHistory.count + 1)
        XCTAssertEqual(store.history.filter { $0.serverID == first }, previousHistory.filter { $0.serverID == first })
        XCTAssertEqual(store.states[store.servers[1].id]?.status, .completed)
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2)
    }

    func testCancelWaitsForRunnerAndDoesNotStartSecondServer() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = RecordingSpeedTestRunner(blocking: true)
        let store = SpeedTestStore(runner: runner, defaults: defaults)
        store.start()
        for _ in 0..<1000 {
            if !(await runner.calls()).isEmpty { break }
            await Task.yield()
        }
        store.cancel()
        store.start()
        await store.waitForCompletion()
        XCTAssertFalse(store.isRunning)
        XCTAssertFalse(store.isCancelling)
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 1)
        for server in store.servers {
            XCTAssertEqual(store.states[server.id]?.status, .cancelled)
            XCTAssertNil(store.states[server.id]?.result)
        }
        XCTAssertTrue(store.history.isEmpty)
    }

    func testSingleServerAndInvalidSelection() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = RecordingSpeedTestRunner()
        let store = SpeedTestStore(runner: runner, defaults: defaults)
        store.start(serverID: "unknown")
        XCTAssertFalse(store.isRunning)
        let second = store.servers[1].id
        store.start(serverID: second)
        await store.waitForCompletion()
        let calls = await runner.calls()
        XCTAssertEqual(calls, [second])
        XCTAssertNil(store.states[store.servers[0].id]?.result)
    }

    func testLauncherCommandAvailableOnlyInAllWithQuery() {
        XCTAssertTrue(LauncherResult.speedTestCommands(query: "", category: .all).isEmpty)
        XCTAssertTrue(LauncherResult.speedTestCommands(query: "speed", category: .files).isEmpty)
        XCTAssertEqual(LauncherResult.speedTestCommands(query: "speed", category: .all).first?.payload, .speedTest)
        let diagnostics = LauncherResult.speedTestCommands(query: "диагностика", category: .all)
            .first { $0.payload == .networkDiagnostics }
        XCTAssertEqual(diagnostics?.title, "Диагностика интернета")
    }

    func testLegacyResultsMigrateOnlyOnceAndKeepLatestCards() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SpeedTestServer.defaults[0].id
        let second = SpeedTestServer.defaults[1].id
        let older = measurement(first, at: Date(timeIntervalSince1970: 1_000), download: 80)
        let newer = measurement(second, at: Date(timeIntervalSince1970: 2_000), download: 120)
        defaults.set(try JSONEncoder().encode([first: older, second: newer]), forKey: "nool.speedTest.results.v1")

        let firstLoad = SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults)
        XCTAssertEqual(firstLoad.history, [newer, older])
        XCTAssertEqual(firstLoad.states[first]?.result, older)
        let secondLoad = SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults)
        XCTAssertEqual(secondLoad.history, firstLoad.history)
        XCTAssertEqual(secondLoad.states[second]?.result, newer)
    }

    func testHistoryRepairsInvalidEntriesAndTrimsToLatestTwoHundred() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SpeedTestServer.defaults[0].id
        let entries = (0..<205).map { measurement(server, at: Date(timeIntervalSince1970: Double($0)), download: Double($0)) }
        let unknown = measurement("unknown", at: Date(timeIntervalSince1970: 999), download: 1)
        let negative = measurement(server, at: Date(timeIntervalSince1970: 998), download: -1)
        defaults.set(try JSONEncoder().encode(entries + [entries[204], unknown, negative]), forKey: "nool.speedTest.history.v1")

        let store = SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults)
        XCTAssertEqual(store.history.count, 200)
        XCTAssertEqual(store.history.first?.measuredAt, Date(timeIntervalSince1970: 204))
        XCTAssertEqual(store.history.last?.measuredAt, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults).history, store.history)
    }

    func testDamagedHistoryIsBackedUpBeforeMigration() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = SpeedTestServer.defaults[0].id
        let legacy = measurement(server, at: Date(timeIntervalSince1970: 1_000), download: 80)
        defaults.set(try JSONEncoder().encode([server: legacy]), forKey: "nool.speedTest.results.v1")
        let damaged = Data("not JSON".utf8)
        defaults.set(damaged, forKey: "nool.speedTest.history.v1")

        let store = SpeedTestStore(runner: RecordingSpeedTestRunner(), defaults: defaults)
        XCTAssertEqual(store.history, [legacy])
        XCTAssertNotNil(store.historyStorageWarning)
        let backupKey = defaults.dictionaryRepresentation().keys.first { $0.hasPrefix("nool.speedTest.history.v1.backup.") }
        XCTAssertEqual(backupKey.flatMap { defaults.data(forKey: $0) }, damaged)
    }

    func testPeriodAndDailyAveragesCompareServersByLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-09-21T12:00:00Z")!
        let first = SpeedTestServer.defaults[0].id
        let second = SpeedTestServer.defaults[1].id
        let samples = [
            measurement(first, at: ISO8601DateFormatter().date(from: "2026-09-21T08:00:00Z")!, download: 40),
            measurement(first, at: ISO8601DateFormatter().date(from: "2026-09-21T09:00:00Z")!, download: 80),
            measurement(second, at: ISO8601DateFormatter().date(from: "2026-09-21T09:30:00Z")!, download: 120),
            measurement(first, at: ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z")!, download: 20)
        ]
        let week = SpeedTestHistory.filter(samples, period: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.count, 3)
        XCTAssertEqual(SpeedTestHistory.filter(samples, period: .month, now: now, calendar: calendar).count, 4)
        let averages = SpeedTestHistory.dailyAverages(week, calendar: calendar)
        XCTAssertEqual(averages.count, 2)
        XCTAssertEqual(averages[0].serverID, second)
        XCTAssertEqual(averages[0].sampleCount, 1)
        XCTAssertEqual(averages[1].serverID, first)
        XCTAssertEqual(averages[1].sampleCount, 2)
        XCTAssertEqual(averages[1].downloadMbps, 60)
    }

    private func measurement(_ serverID: String, at date: Date, download: Double) -> SpeedTestMeasurement {
        SpeedTestMeasurement(serverID: serverID, measuredAt: date, latencyMilliseconds: 22,
                             jitterMilliseconds: 2, downloadMbps: download, uploadMbps: 40, transferredBytes: 1024)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "test.speedtest.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor RecordingSpeedTestRunner: SpeedTestRunning {
    private var recorded: [String] = []
    let failingID: String?
    let blocking: Bool

    init(failingID: String? = nil, blocking: Bool = false) {
        self.failingID = failingID
        self.blocking = blocking
    }

    func calls() -> [String] { recorded }

    func run(server: SpeedTestServer, onProgress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestMeasurement {
        recorded.append(server.id)
        onProgress(SpeedTestProgress(phase: .latency, fraction: 0, megabitsPerSecond: nil))
        if blocking { try await Task.sleep(for: .seconds(100)) }
        if server.id == failingID { throw URLError(.cannotConnectToHost) }
        return SpeedTestMeasurement(serverID: server.id, measuredAt: Date(), latencyMilliseconds: 22,
                                    jitterMilliseconds: 2, downloadMbps: 100, uploadMbps: 40, transferredBytes: 1024)
    }
}
