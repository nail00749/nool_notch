import XCTest
@testable import NotchApp

final class SpeedTestClientTests: XCTestCase {
    func testDefaultServersUseFixedHTTPSBenchmarkEndpoints() throws {
        let servers = SpeedTestServer.defaults

        XCTAssertEqual(servers.map(\.id), ["moscow-cloud4box", "frankfurt-clouvider"])
        XCTAssertEqual(servers.map(\.title), ["Москва", "Франкфурт"])
        XCTAssertTrue(servers.allSatisfy { $0.downloadURL.scheme == "https" })
        XCTAssertTrue(servers.allSatisfy { $0.probeURL.scheme == "https" })
    }

    func testAggregatesLatencyJitterBandwidthAndHonorsByteCaps() async throws {
        let transport = DeterministicSpeedTestTransport()
        let progress = ProgressRecorder()
        let client = SpeedTestClient(transport: transport, configuration: testConfiguration())

        let measurement = try await client.run(server: testServer) { value in
            progress.append(value)
        }

        XCTAssertEqual(measurement.latencyMilliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(measurement.jitterMilliseconds, 10, accuracy: 0.001)
        XCTAssertEqual(measurement.downloadMbps, 0.002133, accuracy: 0.00001)
        XCTAssertEqual(measurement.uploadMbps, 0.001, accuracy: 0.00001)
        XCTAssertEqual(measurement.transferredBytes, 650)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.method == "GET" && $0.isDownload }.count, 4)
        XCTAssertEqual(requests.filter { $0.method == "POST" }.count, 3)
        XCTAssertEqual(
            requests.filter { $0.method == "POST" }.compactMap(\.bodyBytes).sorted(),
            [50, 100, 100]
        )
        XCTAssertTrue(requests.allSatisfy { $0.hasCacheBuster })
        XCTAssertEqual(Set(progress.values.map(\.phase)), Set(SpeedTestPhase.allForTesting))
        XCTAssertTrue(progress.values.allSatisfy { (0...1).contains($0.fraction) })
    }

    func testHTTPFailureStopsRunWithoutReportingBandwidth() async {
        let transport = FailingSpeedTestTransport(statusCode: 503)
        let progress = ProgressRecorder()
        let client = SpeedTestClient(transport: transport, configuration: testConfiguration())

        await XCTAssertThrowsErrorAsync(try await client.run(server: testServer) { progress.append($0) }) { error in
            XCTAssertEqual(error as? SpeedTestError, .httpStatus(503))
        }
        XCTAssertFalse(progress.values.contains { $0.megabitsPerSecond != nil })
    }

    func testRedirectIsRejected() async {
        let transport = FailingSpeedTestTransport(statusCode: 302)
        let client = SpeedTestClient(transport: transport, configuration: testConfiguration())

        await XCTAssertThrowsErrorAsync(try await client.run(server: testServer) { _ in }) { error in
            XCTAssertEqual(error as? SpeedTestError, .redirected)
        }
    }

    func testPhaseDeadlineKeepsCompletedBatchAndIncludesWaitInSpeed() async throws {
        let transport = PartialTimeoutSpeedTestTransport()
        var configuration = testConfiguration()
        configuration.phaseDuration = .milliseconds(40)
        configuration.overallTimeout = .seconds(2)
        configuration.maximumDownloadBytes = 300
        configuration.maximumUploadBytes = 100
        let client = SpeedTestClient(transport: transport, configuration: configuration)

        let measurement = try await client.run(server: testServer) { _ in }

        XCTAssertEqual(measurement.transferredBytes, 200)
        XCTAssertGreaterThan(measurement.downloadMbps, 0)
        XCTAssertLessThanOrEqual(measurement.downloadMbps, 0.02)
    }

    func testDownloadRequestsGrowAfterTheInitialProbe() async throws {
        let transport = DeterministicSpeedTestTransport(downloadDuration: 0.1)
        var configuration = testConfiguration()
        configuration.downloadRequestBytes = 8 * 1_024 * 1_024
        configuration.uploadRequestBytes = 1
        configuration.maximumDownloadBytes = 9 * 1_024 * 1_024
        configuration.maximumUploadBytes = 1
        configuration.parallelism = 4
        let client = SpeedTestClient(transport: transport, configuration: configuration)

        _ = try await client.run(server: testServer) { _ in }

        let requests = await transport.requests.filter { $0.isDownload }
        XCTAssertEqual(requests.map(\.maximumResponseBytes), [1, 8].map { $0 * 1_024 * 1_024 })
    }

    func testCancellationCancelsActiveTransportPromptly() async {
        let transport = CancellingSpeedTestTransport()
        let client = SpeedTestClient(transport: transport, configuration: testConfiguration())
        let server = testServer
        let task = Task { try await client.run(server: server) { _ in } }
        await transport.waitUntilStarted()

        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? SpeedTestError, .cancelled)
        }
        let wasCancelled = await transport.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    func testURLSessionTransportCompletesWhenCancelledBeforeTaskInstallation() async {
        let transport = SpeedTestURLSessionTransport()
        let barrier = SpeedTestCancellationBarrier()
        let request = URLRequest(url: URL(string: "https://speed.example/empty")!)
        let operation = Task {
            await barrier.wait()
            return try await transport.execute(request, maximumResponseBytes: 1_024)
        }
        await barrier.waitUntilBlocked()

        operation.cancel()
        await barrier.release()

        let outcome = await cancelledTransportOutcome(operation, timeout: .seconds(1))
        XCTAssertEqual(outcome, .cancelled)
    }

    func testLiveServersWithTinyTrafficBudgetWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_SPEEDTEST_LIVE"] == "1" else {
            throw XCTSkip("Set NOOL_SPEEDTEST_LIVE=1 to run the opt-in network check.")
        }
        var configuration = SpeedTestClientConfiguration()
        configuration.phaseDuration = .seconds(15)
        configuration.overallTimeout = .seconds(45)
        configuration.parallelism = 4
        configuration.downloadRequestBytes = 1 * 1_024 * 1_024
        configuration.uploadRequestBytes = 256 * 1_024
        configuration.maximumDownloadBytes = 5 * 1_024 * 1_024
        configuration.maximumUploadBytes = 5 * 256 * 1_024
        let client = SpeedTestClient(
            transport: SpeedTestURLSessionTransport(),
            configuration: configuration
        )

        for server in SpeedTestServer.defaults {
            let measurement = try await client.run(server: server) { _ in }
            XCTAssertEqual(measurement.serverID, server.id)
            XCTAssertGreaterThan(measurement.latencyMilliseconds, 0)
            XCTAssertGreaterThan(measurement.downloadMbps, 0)
            XCTAssertGreaterThan(measurement.uploadMbps, 0)
            XCTAssertLessThanOrEqual(measurement.transferredBytes, 6_400 * 1_024)
        }
    }

    private var testServer: SpeedTestServer {
        SpeedTestServer(
            id: "test",
            title: "Test",
            provider: "Tests",
            downloadURL: URL(string: "https://speed.example/garbage")!,
            probeURL: URL(string: "https://speed.example/empty")!
        )
    }

    private func testConfiguration() -> SpeedTestClientConfiguration {
        SpeedTestClientConfiguration(
            latencySampleCount: 5,
            latencyWarmupCount: 1,
            phaseDuration: .seconds(60),
            overallTimeout: .seconds(5),
            parallelism: 2,
            downloadRequestBytes: 100,
            uploadRequestBytes: 100,
            maximumDownloadBytes: 400,
            maximumUploadBytes: 250
        )
    }
}

private extension SpeedTestPhase {
    static let allForTesting: [SpeedTestPhase] = [.latency, .download, .upload]
}

private struct RecordedSpeedTestRequest: Sendable {
    let method: String
    let isDownload: Bool
    let hasCacheBuster: Bool
    let bodyBytes: Int?
    let maximumResponseBytes: Int64
}

private actor DeterministicSpeedTestTransport: SpeedTestTransport {
    private(set) var requests: [RecordedSpeedTestRequest] = []
    private var probeIndex = 0
    private let downloadDuration: Double

    init(downloadDuration: Double = 0.5) {
        self.downloadDuration = downloadDuration
    }

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> SpeedTestTransportResponse {
        let isDownload = request.url?.path.contains("garbage") == true
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        requests.append(RecordedSpeedTestRequest(
            method: request.httpMethod ?? "GET",
            isDownload: isDownload,
            hasCacheBuster: items.contains { $0.name == "nool" },
            bodyBytes: request.httpBody?.count,
            maximumResponseBytes: maximumResponseBytes
        ))

        if isDownload {
            return SpeedTestTransportResponse(
                statusCode: 200,
                receivedBytes: maximumResponseBytes,
                durationSeconds: downloadDuration
            )
        }
        if request.httpMethod == "POST" {
            return SpeedTestTransportResponse(statusCode: 200, receivedBytes: 0, durationSeconds: 1)
        }
        let durations = [0.005, 0.01, 0.02, 0.03, 0.04, 0.05]
        defer { probeIndex += 1 }
        return SpeedTestTransportResponse(
            statusCode: 200,
            receivedBytes: 0,
            durationSeconds: durations[min(probeIndex, durations.count - 1)]
        )
    }
}

private struct FailingSpeedTestTransport: SpeedTestTransport {
    let statusCode: Int

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> SpeedTestTransportResponse {
        SpeedTestTransportResponse(statusCode: statusCode, receivedBytes: 0, durationSeconds: 0.01)
    }
}

private actor PartialTimeoutSpeedTestTransport: SpeedTestTransport {
    private var downloadCount = 0

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> SpeedTestTransportResponse {
        if request.url?.path.contains("garbage") == true {
            downloadCount += 1
            if downloadCount > 1 {
                try await Task.sleep(for: .seconds(10))
            }
            return SpeedTestTransportResponse(
                statusCode: 200,
                receivedBytes: maximumResponseBytes,
                durationSeconds: 0.01
            )
        }
        return SpeedTestTransportResponse(
            statusCode: 200,
            receivedBytes: 0,
            durationSeconds: 0.01
        )
    }
}

private actor CancellingSpeedTestTransport: SpeedTestTransport {
    private(set) var wasCancelled = false
    private var started = false

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> SpeedTestTransportResponse {
        started = true
        do {
            try await Task.sleep(for: .seconds(10))
            return SpeedTestTransportResponse(statusCode: 200, receivedBytes: 0, durationSeconds: 10)
        } catch {
            wasCancelled = true
            throw error
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private actor SpeedTestCancellationBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isBlocked = true
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum CancelledTransportOutcome: Equatable, Sendable {
    case response
    case cancelled
    case otherError
    case timedOut
}

private final class CancelledTransportOutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CancelledTransportOutcome, Never>?
    private var result: CancelledTransportOutcome?

    func install(_ continuation: CheckedContinuation<CancelledTransportOutcome, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: CancelledTransportOutcome) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

private func cancelledTransportOutcome(
    _ operation: Task<SpeedTestTransportResponse, Error>,
    timeout: Duration
) async -> CancelledTransportOutcome {
    let gate = CancelledTransportOutcomeGate()
    Task {
        do {
            _ = try await operation.value
            gate.finish(.response)
        } catch is CancellationError {
            gate.finish(.cancelled)
        } catch let error as URLError where error.code == .cancelled {
            gate.finish(.cancelled)
        } catch {
            gate.finish(.otherError)
        }
    }
    Task {
        try? await Task.sleep(for: timeout)
        gate.finish(.timedOut)
    }
    return await withCheckedContinuation { gate.install($0) }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SpeedTestProgress] = []

    func append(_ value: SpeedTestProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [SpeedTestProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
