import Foundation
import Darwin

enum SpeedTestError: LocalizedError, Equatable, Sendable {
    case invalidServer
    case invalidResponse
    case redirected
    case httpStatus(Int)
    case responseTooLarge
    case emptyDownload
    case timedOut
    case cancelled
    case network

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Некорректный адрес сервера Speedtest."
        case .invalidResponse:
            "Сервер Speedtest вернул некорректный ответ."
        case .redirected:
            "Сервер Speedtest попытался перенаправить запрос."
        case let .httpStatus(status):
            "Сервер Speedtest ответил с кодом HTTP \(status)."
        case .responseTooLarge:
            "Сервер Speedtest превысил допустимый объём данных."
        case .emptyDownload:
            "Сервер Speedtest не передал данные для измерения."
        case .timedOut:
            "Тест скорости не завершился вовремя."
        case .cancelled:
            "Тест скорости отменён."
        case .network:
            "Не удалось связаться с сервером Speedtest."
        }
    }
}

struct SpeedTestTransportResponse: Sendable {
    let statusCode: Int
    let receivedBytes: Int64
    let durationSeconds: Double
}

protocol SpeedTestTransport: Sendable {
    func execute(_ request: URLRequest, maximumResponseBytes: Int64) async throws -> SpeedTestTransportResponse
}

struct SpeedTestClientConfiguration: Sendable {
    var latencySampleCount = 5
    var latencyWarmupCount = 1
    var phaseDuration: Duration = .seconds(7)
    var overallTimeout: Duration = .seconds(35)
    var parallelism = 4
    var downloadRequestBytes: Int64 = 8 * 1_024 * 1_024
    var uploadRequestBytes: Int64 = 2 * 1_024 * 1_024
    var maximumDownloadBytes: Int64 = 256 * 1_024 * 1_024
    var maximumUploadBytes: Int64 = 128 * 1_024 * 1_024
}

struct SpeedTestClient: SpeedTestRunning, Sendable {
    private let transport: any SpeedTestTransport
    private let configuration: SpeedTestClientConfiguration

    init() {
        self.init(transport: SpeedTestURLSessionTransport(), configuration: .init())
    }

    init(
        transport: any SpeedTestTransport,
        configuration: SpeedTestClientConfiguration
    ) {
        self.transport = transport
        self.configuration = configuration
    }

    func run(
        server: SpeedTestServer,
        onProgress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestMeasurement {
        guard Self.isValid(server: server) else { throw SpeedTestError.invalidServer }

        do {
            return try await withThrowingTaskGroup(of: SpeedTestMeasurement.self) { group in
                group.addTask {
                    try await performRun(server: server, onProgress: onProgress)
                }
                group.addTask {
                    try await Task.sleep(for: configuration.overallTimeout)
                    throw SpeedTestError.timedOut
                }

                guard let measurement = try await group.next() else {
                    throw SpeedTestError.invalidResponse
                }
                group.cancelAll()
                return measurement
            }
        } catch is CancellationError {
            throw SpeedTestError.cancelled
        } catch let error as SpeedTestError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw SpeedTestError.cancelled
        } catch {
            throw SpeedTestError.network
        }
    }

    private func performRun(
        server: SpeedTestServer,
        onProgress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> SpeedTestMeasurement {
        let latency = try await measureLatency(server: server, onProgress: onProgress)
        let download = try await measureBandwidth(
            phase: .download,
            server: server,
            onProgress: onProgress
        )
        let upload = try await measureBandwidth(
            phase: .upload,
            server: server,
            onProgress: onProgress
        )

        return SpeedTestMeasurement(
            serverID: server.id,
            measuredAt: .now,
            latencyMilliseconds: latency.medianMilliseconds,
            jitterMilliseconds: latency.jitterMilliseconds,
            downloadMbps: download.megabitsPerSecond,
            uploadMbps: upload.megabitsPerSecond,
            transferredBytes: download.bytes + upload.bytes
        )
    }

    private func measureLatency(
        server: SpeedTestServer,
        onProgress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> (medianMilliseconds: Double, jitterMilliseconds: Double) {
        let warmups = max(configuration.latencyWarmupCount, 0)
        for _ in 0..<warmups {
            try Task.checkCancellation()
            let response = try await transport.execute(
                request(url: server.probeURL, method: "GET", timeout: 3),
                maximumResponseBytes: 64 * 1_024
            )
            try validate(response)
        }

        let sampleCount = max(configuration.latencySampleCount, 5)
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let response = try await transport.execute(
                request(url: server.probeURL, method: "GET", timeout: 3),
                maximumResponseBytes: 64 * 1_024
            )
            try validate(response)
            samples.append(max(response.durationSeconds, 0) * 1_000)
            onProgress(SpeedTestProgress(
                phase: .latency,
                fraction: Double(index + 1) / Double(sampleCount)
            ))
        }

        let sorted = samples.sorted()
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }
        let differences = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        let jitter = differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
        return (median, jitter)
    }

    private func measureBandwidth(
        phase: SpeedTestPhase,
        server: SpeedTestServer,
        onProgress: @escaping @Sendable (SpeedTestProgress) -> Void
    ) async throws -> (bytes: Int64, megabitsPerSecond: Double) {
        let maximumBytes = phase == .download
            ? configuration.maximumDownloadBytes
            : configuration.maximumUploadBytes
        let maximumRequestBytes = max(
            1,
            phase == .download ? configuration.downloadRequestBytes : configuration.uploadRequestBytes
        )
        var requestBytes = min(
            maximumRequestBytes,
            phase == .download ? 1 * 1_024 * 1_024 : 256 * 1_024
        )
        let parallelism = min(max(configuration.parallelism, 1), 4)
        let uploadPayload = phase == .upload
            ? Self.randomPayload(byteCount: Int(maximumRequestBytes))
            : nil
        let phaseStartedAt = ContinuousClock.now
        let deadline = phaseStartedAt.advanced(by: configuration.phaseDuration)
        var transferred: Int64 = 0
        var measuredSeconds = 0.0

        while ContinuousClock.now < deadline, transferred < maximumBytes {
            try Task.checkCancellation()
            let remaining = maximumBytes - transferred
            let desiredParallelism = transferred == 0 ? 1 : parallelism
            let operationCount = min(
                desiredParallelism,
                Int((remaining + requestBytes - 1) / requestBytes)
            )
            let remainingDuration = ContinuousClock.now.duration(to: deadline)
            guard remainingDuration > .zero else { break }
            let responses: [SpeedTestBandwidthOperation]
            responses = try await bandwidthBatch(
                phase: phase,
                server: server,
                operationCount: operationCount,
                requestBytes: requestBytes,
                remainingBytes: remaining,
                uploadPayload: uploadPayload,
                timeout: remainingDuration
            )
            if responses.isEmpty {
                if transferred > 0 { break }
                throw SpeedTestError.timedOut
            }

            let batchBytes = responses.reduce(0) { $0 + $1.acceptedBytes }
            if phase == .download, batchBytes == 0 { throw SpeedTestError.emptyDownload }
            transferred += batchBytes
            let batchDuration = responses.map(\.response.durationSeconds).max() ?? 0
            measuredSeconds += batchDuration
            if batchDuration > 0, !responses.isEmpty {
                let bytesPerStreamSecond = Double(batchBytes)
                    / batchDuration
                    / Double(responses.count)
                var oneSecondRequest = Int64(bytesPerStreamSecond.rounded(.down))
                if phase == .download, maximumRequestBytes >= 1_024 * 1_024 {
                    let mebibyte: Int64 = 1_024 * 1_024
                    oneSecondRequest = max(mebibyte, oneSecondRequest / mebibyte * mebibyte)
                }
                requestBytes = min(maximumRequestBytes, max(requestBytes, oneSecondRequest))
            }
            let elapsed = Self.seconds(phaseStartedAt.duration(to: .now))
            let speed = Self.megabitsPerSecond(
                bytes: transferred,
                seconds: max(measuredSeconds, elapsed)
            )
            onProgress(SpeedTestProgress(
                phase: phase,
                fraction: Double(transferred) / Double(maximumBytes),
                megabitsPerSecond: speed
            ))
        }

        guard transferred > 0, measuredSeconds > 0 else {
            throw phase == .download ? SpeedTestError.emptyDownload : SpeedTestError.invalidResponse
        }
        let elapsed = Self.seconds(phaseStartedAt.duration(to: .now))
        let speed = Self.megabitsPerSecond(bytes: transferred, seconds: max(measuredSeconds, elapsed))
        onProgress(SpeedTestProgress(phase: phase, fraction: 1, megabitsPerSecond: speed))
        return (transferred, speed)
    }

    private func bandwidthBatch(
        phase: SpeedTestPhase,
        server: SpeedTestServer,
        operationCount: Int,
        requestBytes: Int64,
        remainingBytes: Int64,
        uploadPayload: Data?,
        timeout: Duration
    ) async throws -> [SpeedTestBandwidthOperation] {
        try await withThrowingTaskGroup(of: SpeedTestBandwidthBatchEvent.self) { race in
            for operationIndex in 0..<operationCount {
                let allowance = min(
                    requestBytes,
                    remainingBytes - Int64(operationIndex) * requestBytes
                )
                race.addTask {
                    let benchmarkRequest: URLRequest
                    if phase == .download {
                        benchmarkRequest = request(
                            url: downloadURL(server.downloadURL, byteCount: allowance),
                            method: "GET",
                            timeout: 10
                        )
                    } else {
                        let body = Data((uploadPayload ?? Data()).prefix(Int(allowance)))
                        benchmarkRequest = request(
                            url: server.probeURL,
                            method: "POST",
                            body: body,
                            timeout: 10
                        )
                    }
                    let response = try await transport.execute(
                        benchmarkRequest,
                        maximumResponseBytes: phase == .download ? allowance : 64 * 1_024
                    )
                    try validate(response)
                    return .response(SpeedTestBandwidthOperation(
                        response: response,
                        acceptedBytes: phase == .download ? response.receivedBytes : allowance
                    ))
                }
            }
            race.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            var responses: [SpeedTestBandwidthOperation] = []
            while let event = try await race.next() {
                switch event {
                case let .response(response):
                    responses.append(response)
                    if responses.count == operationCount {
                        race.cancelAll()
                        return responses
                    }
                case .timedOut:
                    race.cancelAll()
                    return responses
                }
            }
            return responses
        }
    }

    private func validate(_ response: SpeedTestTransportResponse) throws {
        if (300...399).contains(response.statusCode) { throw SpeedTestError.redirected }
        guard response.statusCode == 200 else { throw SpeedTestError.httpStatus(response.statusCode) }
        guard response.durationSeconds.isFinite, response.durationSeconds >= 0 else {
            throw SpeedTestError.invalidResponse
        }
    }

    private func request(
        url: URL,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval
    ) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "nool", value: UUID().uuidString))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store, no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Nool Speedtest", forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func downloadURL(_ url: URL, byteCount: Int64) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        let mebibytes = max(1, Int((byteCount + 1_048_575) / 1_048_576))
        queryItems.append(URLQueryItem(name: "ckSize", value: String(mebibytes)))
        components.queryItems = queryItems
        return components.url!
    }

    private static func isValid(server: SpeedTestServer) -> Bool {
        [server.downloadURL, server.probeURL].allSatisfy {
            $0.scheme?.lowercased() == "https" && $0.host?.isEmpty == false
        }
    }

    private static func megabitsPerSecond(bytes: Int64, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) * 8 / 1_000_000 / seconds
    }

    private static func randomPayload(byteCount: Int) -> Data {
        var data = Data(count: max(byteCount, 1))
        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            arc4random_buf(baseAddress, buffer.count)
        }
        return data
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

}

private struct SpeedTestBandwidthOperation: Sendable {
    let response: SpeedTestTransportResponse
    let acceptedBytes: Int64
}

private enum SpeedTestBandwidthBatchEvent: Sendable {
    case response(SpeedTestBandwidthOperation)
    case timedOut
}

private final class SpeedTestRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func install(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if isCancelled {
            task.cancel()
            return false
        }
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class SpeedTestRequestState: @unchecked Sendable {
    let continuation: CheckedContinuation<SpeedTestTransportResponse, Error>
    let maximumResponseBytes: Int64
    let startedAt = ContinuousClock.now
    var statusCode: Int?
    var receivedBytes: Int64 = 0
    var terminalError: Error?

    init(
        continuation: CheckedContinuation<SpeedTestTransportResponse, Error>,
        maximumResponseBytes: Int64
    ) {
        self.continuation = continuation
        self.maximumResponseBytes = maximumResponseBytes
    }
}

final class SpeedTestURLSessionTransport: SpeedTestTransport, @unchecked Sendable {
    private let delegate: SpeedTestURLSessionDelegate
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let delegate = SpeedTestURLSessionDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64
    ) async throws -> SpeedTestTransportResponse {
        try await delegate.execute(
            request,
            maximumResponseBytes: maximumResponseBytes,
            session: session
        )
    }
}

private final class SpeedTestURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: SpeedTestRequestState] = [:]

    func execute(
        _ request: URLRequest,
        maximumResponseBytes: Int64,
        session: URLSession
    ) async throws -> SpeedTestTransportResponse {
        let cancellation = SpeedTestRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = SpeedTestRequestState(
                    continuation: continuation,
                    maximumResponseBytes: maximumResponseBytes
                )
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()
                if cancellation.install(task) {
                    task.resume()
                } else {
                    lock.lock()
                    let pending = states.removeValue(forKey: task.taskIdentifier)
                    lock.unlock()
                    pending?.continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              let state = state(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        state.statusCode = response.statusCode
        if response.expectedContentLength > state.maximumResponseBytes {
            state.terminalError = SpeedTestError.responseTooLarge
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask.taskIdentifier) else { return }
        let newTotal = state.receivedBytes + Int64(data.count)
        if newTotal > state.maximumResponseBytes {
            state.terminalError = SpeedTestError.responseTooLarge
            dataTask.cancel()
        } else {
            state.receivedBytes = newTotal
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let terminalError = state.terminalError {
            state.continuation.resume(throwing: terminalError)
            return
        }
        if let error {
            state.continuation.resume(throwing: error)
            return
        }
        guard let statusCode = state.statusCode else {
            state.continuation.resume(throwing: SpeedTestError.invalidResponse)
            return
        }
        let duration = state.startedAt.duration(to: .now).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
        state.continuation.resume(returning: SpeedTestTransportResponse(
            statusCode: statusCode,
            receivedBytes: state.receivedBytes,
            durationSeconds: max(seconds, .leastNonzeroMagnitude)
        ))
    }

    private func state(for taskIdentifier: Int) -> SpeedTestRequestState? {
        lock.lock()
        defer { lock.unlock() }
        return states[taskIdentifier]
    }
}
