import XCTest
@testable import NotchApp

@MainActor
final class NetworkDiagnosticsTests: XCTestCase {
    func testStoreWaitsForCancelledRunnerAndIgnoresLateResult() async {
        let runner = SuspendedDiagnosticsRunner()
        let store = NetworkDiagnosticsStore(runner: runner)
        store.start()
        await waitForCalls(1, runner: runner)
        XCTAssertTrue(store.isRunning)
        store.cancel()
        XCTAssertTrue(store.isRunning)
        XCTAssertTrue(store.isCancelling)
        store.start()
        let callsWhileCancelling = await runner.callCount()
        XCTAssertEqual(callsWhileCancelling, 1)

        await runner.finishNext(report: sampleReport())
        await store.waitForCompletion()
        XCTAssertFalse(store.isRunning)
        XCTAssertFalse(store.isCancelling)
        XCTAssertNil(store.report)

        store.start()
        await waitForCalls(2, runner: runner)
        await runner.finishNext(report: sampleReport())
        await store.waitForCompletion()
        XCTAssertEqual(store.report?.probes.count, 4)
    }

    func testGatewayPingAndDNSParsing() {
        let route = "route to: default\ngateway: 192.168.1.1\ninterface: en0\n"
        XCTAssertEqual(NetworkDiagnosticsParsing.gatewayAddress(in: route), "192.168.1.1")
        XCTAssertNil(NetworkDiagnosticsParsing.gatewayAddress(in: "gateway: 192.168.1.1;whoami"))
        XCTAssertFalse(NetworkDiagnosticsParsing.isValidIPv4("01.2.3.4"))
        XCTAssertFalse(NetworkDiagnosticsParsing.isValidIPv4("256.2.3.4"))

        let ping = "--- 1.1.1.1 ping statistics ---\n5 packets transmitted, 3 packets received, 40.0% packet loss\nround-trip min/avg/max/stddev = 4.0/5.5/7.0/1.0 ms\n"
        XCTAssertEqual(NetworkDiagnosticsParsing.pingStatistics(in: ping),
                       DiagnosticPingStatistics(sent: 5, received: 3, averageMilliseconds: 5.5))
        XCTAssertNil(NetworkDiagnosticsParsing.pingStatistics(in: "no ping statistics"))

        let dns = "name: example.com\nip_address: 93.184.215.14\nipv6_address: 2606:2800:220:1:248:1893:25c8:1946\nip_address: 93.184.215.14\n"
        XCTAssertEqual(NetworkDiagnosticsParsing.resolvedAddresses(in: dns),
                       ["93.184.215.14", "2606:2800:220:1:248:1893:25c8:1946"])
    }

    func testSummaryKeepsICMPSeparateFromHTTPSAvailability() {
        let report = NetworkDiagnosticsReport(measuredAt: .now, probes: [
            .init(kind: .gatewayICMP, target: "gateway", outcome: .skipped, detail: "missing"),
            .init(kind: .externalICMP, target: "1.1.1.1", outcome: .warning, detail: "0/5"),
            .init(kind: .dns, target: "example.com", outcome: .success, detail: "resolved"),
            .init(kind: .https, target: "https://example.com", outcome: .success, detail: "HTTP 200")
        ])
        XCTAssertTrue(report.summary.contains("HTTPS доступен"))
        XCTAssertTrue(report.summary.contains("ICMP"))
        XCTAssertFalse(report.summary.contains("интернет недоступен"))
    }

    func testRunnerReportsPartialICMPAsWarningWithoutHidingOtherResults() async throws {
        let runner = SystemNetworkDiagnosticsRunner(commands: StubDiagnosticCommands(hasGateway: true),
                                                    https: StubHTTPSChecker())
        let report = try await runner.run()
        XCTAssertEqual(report.probes.count, 4)
        XCTAssertEqual(report.probe(.gatewayICMP)?.outcome, .warning)
        XCTAssertTrue(report.probe(.gatewayICMP)?.detail.contains("40%") == true)
        XCTAssertEqual(report.probe(.externalICMP)?.outcome, .warning)
        XCTAssertEqual(report.probe(.dns)?.outcome, .success)
        XCTAssertEqual(report.probe(.https)?.outcome, .success)

        let noGateway = try await SystemNetworkDiagnosticsRunner(
            commands: StubDiagnosticCommands(hasGateway: false), https: StubHTTPSChecker()
        ).run()
        XCTAssertEqual(noGateway.probe(.gatewayICMP)?.outcome, .skipped)
        XCTAssertEqual(noGateway.probe(.https)?.outcome, .success)
    }

    func testCommandCaptureBoundsOutputTimeAndCancellation() async {
        let commands = SystemDiagnosticCommandRunner()
        let overflowing = await commands.run(executable: "/usr/bin/yes", arguments: [], timeoutSeconds: 2)
        XCTAssertEqual(overflowing.stopReason, .outputLimited)
        XCTAssertLessThanOrEqual(overflowing.output.utf8.count, 64 * 1_024)

        let timeoutStart = Date()
        let timedOut = await commands.run(executable: "/bin/sleep", arguments: ["5"], timeoutSeconds: 0.1)
        XCTAssertEqual(timedOut.stopReason, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 2)

        let task = Task { await commands.run(executable: "/bin/sleep", arguments: ["5"], timeoutSeconds: 8) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.stopReason, .cancelled)
    }

    func testLiveNetworkDiagnosticsWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_NETWORK_DIAGNOSTICS_LIVE"] == "1" else {
            throw XCTSkip("Enable with NOOL_NETWORK_DIAGNOSTICS_LIVE=1")
        }
        let started = Date()
        let report = try await SystemNetworkDiagnosticsRunner().run()
        XCTAssertEqual(Set(report.probes.map(\.kind)), Set(NetworkProbeKind.allCases))
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    private func sampleReport() -> NetworkDiagnosticsReport {
        NetworkDiagnosticsReport(measuredAt: .now, probes: NetworkProbeKind.allCases.map {
            NetworkProbeResult(kind: $0, target: "test", outcome: .success, detail: "ok")
        })
    }

    private func waitForCalls(_ count: Int, runner: SuspendedDiagnosticsRunner) async {
        for _ in 0..<100 {
            if await runner.callCount() == count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Runner was not called in time")
    }
}

private actor SuspendedDiagnosticsRunner: NetworkDiagnosticsRunning {
    private var calls = 0
    private var continuations: [CheckedContinuation<NetworkDiagnosticsReport, Error>] = []

    func callCount() -> Int { calls }

    func run() async throws -> NetworkDiagnosticsReport {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func finishNext(report: NetworkDiagnosticsReport) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: report)
    }
}

private struct StubDiagnosticCommands: DiagnosticCommandRunning {
    let hasGateway: Bool

    func run(executable: String, arguments: [String], timeoutSeconds: Double) async -> DiagnosticCommandResult {
        let output: String
        switch executable {
        case "/sbin/route":
            output = hasGateway ? "route to: default\ngateway: 192.168.1.1\n" : "route to: default\ninterface: utun0\n"
        case "/sbin/ping":
            output = "5 packets transmitted, 3 packets received, 40.0% packet loss\nround-trip min/avg/max/stddev = 4.0/5.5/7.0/1.0 ms\n"
        case "/usr/bin/dscacheutil":
            output = "name: example.com\nip_address: 93.184.215.14\n"
        default:
            return DiagnosticCommandResult(exitCode: nil, output: "", stopReason: .launchFailed)
        }
        return DiagnosticCommandResult(exitCode: 0, output: output, stopReason: nil)
    }
}

private struct StubHTTPSChecker: NetworkHTTPSChecking {
    func check() async -> NetworkProbeResult {
        NetworkProbeResult(kind: .https, target: "https://example.com", outcome: .success, detail: "HTTP 200")
    }
}
