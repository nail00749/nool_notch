import XCTest
@testable import NotchApp

final class IperfTestTests: XCTestCase {
    func testConfigurationRejectsCLIOptionsURLsCredentialsAndMalformedHosts() {
        for host in ["-R", "example.test --udp", "https://example.test", "user@example.test", "example.test/path",
                     "example.test:5201", "a\nb", "999.999.999.999", "a..test", "-server.test", "[::1]:5201"] {
            XCTAssertFalse(IperfTestConfiguration(host: host).isValid, host)
        }
        for host in ["127.0.0.1", "::1", "[2001:db8::1]", "fe80::1%en0", "example.test", "localhost", "iperf.example.test."] {
            XCTAssertTrue(IperfTestConfiguration(host: host).isValid, host)
        }
        XCTAssertEqual(IperfTestConfiguration(host: "[::1]").validatedHost, "::1")
        XCTAssertFalse(IperfTestConfiguration(host: "localhost", port: 0).isValid)
        XCTAssertFalse(IperfTestConfiguration(host: "localhost", durationSeconds: 31).isValid)
        XCTAssertFalse(IperfTestConfiguration(host: "localhost", udpMegabitsPerSecond: 0).isValid)
    }

    func testTCPSelectsDeliveredReceiverRateInsteadOfSenderRate() throws {
        let json = Data(#"{"end":{"sum_sent":{"seconds":5,"bits_per_second":999000000},"sum_received":{"seconds":5,"bits_per_second":123000000}}}"#.utf8)
        for reverse in [false, true] {
            let value = try IperfTestJSON.decode(json, transport: .tcp, reverse: reverse)
            XCTAssertEqual(value.megabitsPerSecond, 123)
            XCTAssertNil(value.jitterMilliseconds)
            XCTAssertNil(value.lossPercent)
        }
    }

    func testUDPSelectsRemoteReceiverForUploadAndLocalReceiverForReverse() throws {
        let json = Data(#"{"end":{"sum_sent":{"seconds":5,"bits_per_second":50000000,"jitter_ms":0,"lost_percent":0},"sum_received":{"seconds":5,"bits_per_second":42000000,"jitter_ms":3,"lost_percent":4}},"server_output_json":{"end":{"sum_received":{"seconds":5,"bits_per_second":39000000,"jitter_ms":6,"lost_percent":7,"sender":false},"sum":{"seconds":5,"bits_per_second":0,"jitter_ms":6,"lost_percent":7,"sender":false}}}}"#.utf8)
        let upload = try IperfTestJSON.decode(json, transport: .udp, reverse: false)
        let download = try IperfTestJSON.decode(json, transport: .udp, reverse: true)
        XCTAssertEqual(upload, .init(megabitsPerSecond: 39, jitterMilliseconds: 6, lossPercent: 7))
        XCTAssertEqual(download, .init(megabitsPerSecond: 42, jitterMilliseconds: 3, lossPercent: 4))
    }

    func testLegacyUDPReceiverSummaryAndPacketLossCalculation() throws {
        let data = Data(#"{"end":{"sum":{"seconds":5,"bits_per_second":48000000,"jitter_ms":0.25,"lost_packets":2,"packets":100,"sender":true}}}"#.utf8)
        XCTAssertEqual(try IperfTestJSON.decode(data, transport: .udp, reverse: false),
                       .init(megabitsPerSecond: 48, jitterMilliseconds: 0.25, lossPercent: 2))
    }

    func testIncompleteErroredBooleanNegativeAndNonfiniteResultsCannotBecomeZeroSuccess() {
        for json in [#"{}"#, #"{"error":"server busy"}"#,
                     #"{"end":{"sum_sent":{"seconds":5,"bits_per_second":123}}}"#,
                     #"{"end":{"sum_received":{"seconds":5,"bits_per_second":true}}}"#,
                     #"{"end":{"sum_received":{"seconds":0,"bits_per_second":100}}}"#,
                     #"{"end":{"sum_received":{"seconds":5,"bits_per_second":-1}}}"#,
                     #"{"end":{"sum_received":{"seconds":5,"bits_per_second":1e999}}}"#] {
            XCTAssertThrowsError(try IperfTestJSON.decode(Data(json.utf8), transport: .tcp, reverse: false))
        }
        for jitter in [-1.0, 0.0] {
            let json = "{\"end\":{\"sum_received\":{\"seconds\":5,\"bits_per_second\":123,\"jitter_ms\":\(jitter),\"lost_percent\":101}}}"
            XCTAssertThrowsError(try IperfTestJSON.decode(Data(json.utf8), transport: .udp, reverse: false))
        }
    }

    func testRunnerUsesTwoSequentialBoundedCommandsAndUDPBitrate() async throws {
        let process = RecordingIperfProcessRunner(outputs: [udpOutput, udpOutput])
        let runner = IperfTestRunner(executable: "/test/iperf3", processRunner: process)
        let config = IperfTestConfiguration(host: "::1", durationSeconds: 5, udpMegabitsPerSecond: 50, transport: .udp)
        let result = try await runner.run(configuration: config, onPhase: { _ in })
        XCTAssertEqual(result.uploadMbps, 48)
        XCTAssertEqual(result.downloadMbps, 48)
        let calls = await process.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[0].arguments.contains("-R"))
        XCTAssertTrue(calls[1].arguments.contains("-R"))
        XCTAssertTrue(calls[0].arguments.contains("50M"))
        XCTAssertEqual(calls[0].arguments.prefix(2), ["-c", "::1"])
        XCTAssertEqual(calls.map(\.timeout), [15, 15])
    }

    func testFailureStopsBeforeDownloadAndNonzeroExitCannotPublishJSON() async {
        let process = RecordingIperfProcessRunner(outputs: [udpOutput], exitCode: 1)
        let runner = IperfTestRunner(executable: "/test/iperf3", processRunner: process)
        do { _ = try await runner.run(configuration: .init(host: "localhost", transport: .udp), onPhase: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? IperfTestError, .processFailed(1)) }
        let calls = await process.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testScopedProcessRunnerTimesOutCancelsAndLimitsOutput() async {
        let runner = SystemIperfTestProcessRunner()
        let timeout = await runner.run(executable: "/bin/sleep", arguments: ["30"], timeoutSeconds: 0.1)
        XCTAssertEqual(timeout.stopReason, .timedOut)
        let task = Task { await runner.run(executable: "/bin/sleep", arguments: ["30"], timeoutSeconds: 40) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.stopReason, .cancelled)
        let limited = await runner.run(executable: "/usr/bin/yes", arguments: [], timeoutSeconds: 3)
        XCTAssertEqual(limited.stopReason, .outputLimited)
        XCTAssertLessThanOrEqual(limited.standardOutput.count + limited.standardError.utf8.count, 1024 * 1024)
    }

    private var udpOutput: Data { Data(#"{"end":{"sum_received":{"seconds":5,"bits_per_second":48000000,"jitter_ms":0.2,"lost_percent":1}}}"#.utf8) }
}

private actor RecordingIperfProcessRunner: IperfTestProcessRunning {
    struct Call: Sendable { let arguments: [String]; let timeout: Double }
    let outputs: [Data]
    let exitCode: Int32
    var recorded: [Call] = []
    init(outputs: [Data], exitCode: Int32 = 0) { self.outputs = outputs; self.exitCode = exitCode }
    func calls() -> [Call] { recorded }
    func run(executable: String, arguments: [String], timeoutSeconds: Double) -> IperfTestProcessResult {
        let index = recorded.count
        recorded.append(.init(arguments: arguments, timeout: timeoutSeconds))
        return .init(exitCode: exitCode, standardOutput: outputs[min(index, outputs.count - 1)], standardError: "", stopReason: nil)
    }
}

@MainActor
final class IperfTestStoreTests: XCTestCase {
    func testConfigurationPersistsAndInvalidInputCannotStart() async throws {
        let suite = "iperf-store-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = StoreIperfRunner()
        let store = IperfTestStore(runner: runner, defaults: defaults)
        store.start()
        XCTAssertFalse(store.isRunning)
        XCTAssertNotNil(store.errorMessage)
        store.configuration = .init(host: "localhost", transport: .udp)
        XCTAssertEqual(IperfTestStore(runner: runner, defaults: defaults).configuration, store.configuration)
        store.start()
        store.start()
        await store.waitForCompletion()
        let calls = await runner.calls()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.result?.downloadMbps, 100)
        XCTAssertFalse(store.isRunning)
    }

    func testCancellationWaitsAndKeepsPreviousSuccess() async throws {
        let suite = "iperf-cancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = StoreIperfRunner()
        let store = IperfTestStore(runner: runner, defaults: defaults)
        store.config.host = "localhost"
        store.start()
        await store.waitForCompletion()
        let previous = store.result
        await runner.setBlocking()
        store.start()
        for _ in 0..<1000 {
            if await runner.calls() == 2 { break }
            await Task.yield()
        }
        store.cancel()
        XCTAssertTrue(store.isCancelling)
        store.start()
        await store.waitForCompletion()
        XCTAssertFalse(store.isRunning)
        XCTAssertFalse(store.isCancelling)
        XCTAssertEqual(store.result, previous)
        XCTAssertNil(store.errorMessage)
        let calls = await runner.calls()
        XCTAssertEqual(calls, 2)
    }
}

private actor StoreIperfRunner: IperfTestRunning {
    var count = 0
    var blocking = false
    func calls() -> Int { count }
    func setBlocking() { blocking = true }
    func run(configuration: IperfTestConfiguration, onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult {
        count += 1
        onPhase("running")
        if blocking { try await Task.sleep(for: .seconds(30)) }
        return .init(downloadMbps: 100, uploadMbps: 50, jitterMilliseconds: configuration.transport == .udp ? 1 : nil,
            lossPercent: configuration.transport == .udp ? 0 : nil, measuredAt: Date(), transport: configuration.transport,
            host: configuration.validatedHost!)
    }
}
