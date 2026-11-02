import Darwin
import Foundation

enum IperfTestProcessStopReason: Equatable, Sendable { case cancelled, timedOut, outputLimited, launchFailed }

struct IperfTestProcessResult: Sendable {
    let exitCode: Int32?
    let standardOutput: Data
    let standardError: String
    let stopReason: IperfTestProcessStopReason?
}

protocol IperfTestProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeoutSeconds: Double) async -> IperfTestProcessResult
}

struct SystemIperfTestProcessRunner: IperfTestProcessRunning {
    func run(executable: String, arguments: [String], timeoutSeconds: Double) async -> IperfTestProcessResult {
        let capture = IperfTestProcessCapture()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: capture.run(executable: executable, arguments: arguments,
                        timeoutSeconds: timeoutSeconds.isFinite ? min(45, max(0.1, timeoutSeconds)) : 15))
                }
            }
        } onCancel: { capture.cancel() }
    }
}

/// Only the utility worker accesses Process and the output buffers. Cancellation shares
/// one stop flag under a lock; termination and SIGKILL always target this capture's child.
private final class IperfTestProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: IperfTestProcessStopReason?
    private var output = Data()
    private var errors = Data()
    private static let maximumOutputBytes = 1024 * 1024

    func cancel() { stop(.cancelled) }

    func run(executable: String, arguments: [String], timeoutSeconds: Double) -> IperfTestProcessResult {
        guard stopReason == nil else { return result(exitCode: nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "LANG": "C"]) { _, fixed in fixed }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
        }
        for pipe in [stdout, stderr] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                stop(.launchFailed)
                return result(exitCode: nil)
            }
        }
        do { try process.run() }
        catch {
            stop(.launchFailed)
            return result(exitCode: nil)
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        var terminationTime: TimeInterval?
        while true {
            let readOutput = drain(stdout.fileHandleForReading.fileDescriptor, stderr: false)
            let readErrors = drain(stderr.fileHandleForReading.fileDescriptor, stderr: true)
            let running = process.isRunning
            let now = ProcessInfo.processInfo.systemUptime
            if running, now >= deadline { stop(.timedOut) }
            if stopReason != nil, running {
                if terminationTime == nil {
                    process.terminate()
                    terminationTime = now
                } else if now - terminationTime! >= 0.5 {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            if !running, !readOutput, !readErrors { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        return result(exitCode: process.terminationStatus)
    }

    private var stopReason: IperfTestProcessStopReason? { lock.withLock { reason } }
    private func stop(_ newReason: IperfTestProcessStopReason) {
        lock.withLock { if reason == nil { reason = newReason } }
    }
    private func result(exitCode: Int32?) -> IperfTestProcessResult {
        .init(exitCode: exitCode, standardOutput: output, standardError: String(decoding: errors, as: UTF8.self), stopReason: stopReason)
    }
    private func drain(_ fd: Int32, stderr: Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var readAny = false
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            readAny = true
            let remaining = max(0, Self.maximumOutputBytes - output.count - errors.count)
            let bytes = buffer.prefix(min(count, remaining))
            if stderr { errors.append(contentsOf: bytes) } else { output.append(contentsOf: bytes) }
            if count > remaining { stop(.outputLimited) }
        }
        return readAny
    }
}
