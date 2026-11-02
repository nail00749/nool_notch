import XCTest
@testable import NotchApp

@MainActor
final class SpeedTestSessionTests: XCTestCase {
    func testOnlyOneEngineRunsAndCancellationDrainsBeforeRestart() async throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = makeSession(defaults)
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.startHTTP())
        let firstID = try XCTUnwrap(session.activeRunID)
        XCTAssertFalse(session.startIperf())
        XCTAssertFalse(session.startDiagnostics())
        session.cancel()
        XCTAssertTrue(session.isCancelling)
        XCTAssertFalse(session.startHTTP())
        await session.waitForCompletion()
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.isCancelling)
        XCTAssertTrue(session.startIperf())
        XCTAssertNotEqual(session.activeRunID, firstID, "Each run has a distinct session identity")
        XCTAssertFalse(session.startHTTP())
        XCTAssertFalse(session.startDiagnostics())
        session.cancel()
        await session.waitForCompletion()
        XCTAssertTrue(session.startDiagnostics())
        XCTAssertFalse(session.startHTTP())
        XCTAssertFalse(session.startIperf())
        session.cancel()
        await session.waitForCompletion()
    }

    func testDisablingNetworkModuleCancelsRunAndRejectsAllStarts() async throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let modules = AppModuleStore(defaults: nil)
        let session = makeSession(defaults, modules: modules)
        XCTAssertTrue(session.startIperf())
        modules.setEnabled(.networkTools, enabled: false)
        XCTAssertTrue(session.isCancelling)
        await session.waitForCompletion()
        XCTAssertFalse(session.startHTTP())
        XCTAssertFalse(session.startIperf())
        XCTAssertFalse(session.startDiagnostics())
        modules.setEnabled(.networkTools, enabled: true)
        XCTAssertTrue(session.startHTTP())
        session.cancel()
        await session.waitForCompletion()
    }

    func testSpeedtestIntegrationCanBeAddedWithAllSupportedWidths() throws {
        let (suite, defaults) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        let integration = try XCTUnwrap(DockIntegrationRegistry.integration("speedtest"))
        XCTAssertEqual(integration.supportedSpans, [1, 2, 3])
        XCTAssertTrue(prefs.addIntegration("speedtest"))
        let item = try XCTUnwrap(prefs.items.first { $0.integrationID == "speedtest" })
        XCTAssertEqual(item.span, 2)
        XCTAssertFalse(prefs.addIntegration("speedtest"))
        prefs.setSpan(3, for: item.id)
        XCTAssertEqual(DockPreferences(defaults: defaults).items.first { $0.id == item.id }?.span, 3)
    }

    private func makeSession(_ defaults: UserDefaults, modules: AppModuleStore = AppModuleStore(defaults: nil)) -> SpeedTestSession {
        let iperf = IperfTestStore(runner: SessionBlockingIperf(), defaults: defaults)
        iperf.configuration.host = "test.example"
        return SpeedTestSession(http: SpeedTestStore(runner: SessionBlockingHTTP(), defaults: defaults),
            iperf: iperf, diagnostics: NetworkDiagnosticsStore(runner: SessionBlockingDiagnostics()), modules: modules)
    }

    private func defaults() throws -> (String, UserDefaults) {
        let suite = "speedtest-session-\(UUID().uuidString)"
        return (suite, try XCTUnwrap(UserDefaults(suiteName: suite)))
    }
}

private struct SessionBlockingHTTP: SpeedTestRunning {
    func run(server: SpeedTestServer, onProgress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestMeasurement {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
private struct SessionBlockingIperf: IperfTestRunning {
    func run(configuration: IperfTestConfiguration, onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
private struct SessionBlockingDiagnostics: NetworkDiagnosticsRunning {
    func run() async throws -> NetworkDiagnosticsReport {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
