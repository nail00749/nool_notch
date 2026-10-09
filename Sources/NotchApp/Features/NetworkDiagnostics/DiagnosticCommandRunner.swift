import Darwin
import Foundation

enum DiagnosticCommandStopReason: Equatable, Sendable {
    case cancelled, timedOut, outputLimited, launchFailed
}

struct DiagnosticCommandResult: Sendable {
    let exitCode: Int32?
    let output: String
    let stopReason: DiagnosticCommandStopReason?
}

protocol DiagnosticCommandRunning: Sendable {
    func run(executable: String, arguments: [String], timeoutSeconds: Double) async -> DiagnosticCommandResult
}

struct SystemDiagnosticCommandRunner: DiagnosticCommandRunning {
    func run(executable: String, arguments: [String], timeoutSeconds: Double) async -> DiagnosticCommandResult {
        let capture = DiagnosticProcessCapture()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let result = capture.run(executable: executable, arguments: arguments,
                                             timeoutSeconds: min(max(timeoutSeconds, 0.1), 8))
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            capture.cancel()
        }
    }
}

private final class DiagnosticProcessCapture: @unchecked Sendable {
    private static let maximumOutputBytes = 64 * 1_024
    private let lock = NSLock()
    private var process: Process?
    private var output = Data()
    private var stopReason: DiagnosticCommandStopReason?

    func run(executable: String, arguments: [String], timeoutSeconds: Double) -> DiagnosticCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, fixed in fixed }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let shouldLaunch = lock.withLock { () -> Bool in
            guard stopReason == nil else { return false }
            self.process = process
            return true
        }
        guard shouldLaunch else {
            return DiagnosticCommandResult(exitCode: nil, output: "", stopReason: .cancelled)
        }

        do {
            try process.run()
        } catch {
            lock.withLock {
                self.process = nil
                if stopReason == nil { stopReason = .launchFailed }
            }
            return DiagnosticCommandResult(exitCode: nil, output: "", stopReason: .launchFailed)
        }
        pipe.fileHandleForWriting.closeFile()

        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let bytes = pipe.fileHandleForReading.readData(ofLength: 4_096)
                if bytes.isEmpty { break }
                append(bytes)
            }
            reader.leave()
        }

        if lock.withLock({ stopReason != nil }) { stopProcess(process) }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler { [weak self] in self?.stop(reason: .timedOut) }
        timer.resume()
        process.waitUntilExit()
        timer.cancel()
        if reader.wait(timeout: .now() + 1) == .timedOut {
            pipe.fileHandleForReading.closeFile()
        }
        let result = lock.withLock { () -> DiagnosticCommandResult in
            self.process = nil
            return DiagnosticCommandResult(exitCode: process.terminationStatus,
                                           output: String(decoding: output, as: UTF8.self),
                                           stopReason: stopReason)
        }
        return result
    }

    func cancel() { stop(reason: .cancelled) }

    private func append(_ bytes: Data) {
        let overflow = lock.withLock { () -> Bool in
            let remaining = max(0, Self.maximumOutputBytes - output.count)
            output.append(bytes.prefix(remaining))
            return bytes.count > remaining
        }
        if overflow { stop(reason: .outputLimited) }
    }

    private func stop(reason: DiagnosticCommandStopReason) {
        let running = lock.withLock { () -> Process? in
            guard stopReason == nil else { return nil }
            if reason == .timedOut, process?.isRunning != true { return nil }
            stopReason = reason
            return process
        }
        if let running { stopProcess(running) }
    }

    private func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
}
