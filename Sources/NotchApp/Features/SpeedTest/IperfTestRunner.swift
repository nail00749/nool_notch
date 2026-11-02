import Foundation

struct IperfTestRunner: IperfTestRunning {
    private let executable: String?
    private let processRunner: any IperfTestProcessRunning

    init(executable: String? = Self.installedExecutable,
         processRunner: any IperfTestProcessRunning = SystemIperfTestProcessRunner()) {
        self.executable = executable
        self.processRunner = processRunner
    }

    static var installedExecutable: String? {
        ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3", "/usr/bin/iperf3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func run(configuration: IperfTestConfiguration,
             onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult {
        if let error = configuration.validationError { throw IperfTestError.invalidConfiguration(error) }
        guard let host = configuration.validatedHost else { throw IperfTestError.invalidResponse }
        guard let executable else { throw IperfTestError.binaryMissing }
        var values: [IperfTestDirectionMeasurement] = []
        for reverse in [false, true] {
            try Task.checkCancellation()
            onPhase("\(configuration.transport.title) · \(reverse ? "Приём" : "Отдача")")
            let result = await processRunner.run(executable: executable,
                arguments: Self.arguments(configuration: configuration, reverse: reverse),
                timeoutSeconds: Double(configuration.durationSeconds + 10))
            try Task.checkCancellation()
            if let reason = result.stopReason {
                switch reason {
                case .cancelled: throw IperfTestError.cancelled
                case .timedOut: throw IperfTestError.timedOut
                case .outputLimited: throw IperfTestError.outputLimited
                case .launchFailed: throw IperfTestError.launchFailed
                }
            }
            guard result.exitCode == 0 else { throw IperfTestError.processFailed(result.exitCode ?? -1) }
            values.append(try IperfTestJSON.decode(result.standardOutput, transport: configuration.transport, reverse: reverse))
        }
        return IperfTestResult(downloadMbps: values[1].megabitsPerSecond, uploadMbps: values[0].megabitsPerSecond,
            jitterMilliseconds: values.compactMap(\.jitterMilliseconds).max(),
            lossPercent: values.compactMap(\.lossPercent).max(), measuredAt: Date(), transport: configuration.transport, host: host)
    }

    static func arguments(configuration: IperfTestConfiguration, reverse: Bool) -> [String] {
        var arguments = ["-c", configuration.validatedHost ?? configuration.host, "-p", String(configuration.port),
                         "-t", String(configuration.durationSeconds), "-J", "--get-server-output", "--connect-timeout", "3000"]
        if configuration.transport == .udp { arguments += ["-u", "-b", "\(configuration.udpMegabitsPerSecond)M"] }
        if reverse { arguments.append("-R") }
        return arguments
    }
}

struct IperfTestDirectionMeasurement: Equatable, Sendable {
    let megabitsPerSecond: Double
    let jitterMilliseconds: Double?
    let lossPercent: Double?
}

enum IperfTestJSON {
    private struct Summary: Decodable {
        let bits_per_second: Double?
        let seconds: Double?
        let jitter_ms: Double?
        let lost_percent: Double?
        let lost_packets: Double?
        let packets: Double?
        let sender: Bool?
    }
    private struct End: Decodable {
        let sum_received: Summary?
        let sum_sent: Summary?
        let sum: Summary?
    }
    private struct Remote: Decodable { let end: End?; let error: String? }
    private struct Document: Decodable {
        let end: End?
        let error: String?
        let server_output_json: Remote?
    }

    static func decode(_ data: Data, transport: IperfTestTransport, reverse: Bool) throws -> IperfTestDirectionMeasurement {
        guard data.count <= 1024 * 1024, let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw IperfTestError.invalidResponse
        }
        if let error = document.error, !error.isEmpty { throw IperfTestError.server(String(error.prefix(200))) }
        if let error = document.server_output_json?.error, !error.isEmpty { throw IperfTestError.server(String(error.prefix(200))) }
        let summary: Summary?
        if transport == .tcp {
            // sum_sent measures what the sender offered, not what the receiver delivered.
            summary = document.end?.sum_received ?? (!reverse ? document.server_output_json?.end?.sum_received : nil)
        } else if reverse {
            // In reverse mode the local client receives UDP; the remote server is the sender.
            summary = document.end?.sum_received ?? document.end?.sum
        } else {
            let remote = document.server_output_json?.end
            // Modern servers expose sum_received. Legacy UDP sum contains receiver statistics;
            // prefer the remote receiver's sum over the local sender's summary when supplied.
            summary = remote?.sum_received ?? document.end?.sum_received ?? document.end?.sum
                ?? remote?.sum.flatMap { $0.sender == true ? nil : $0 }
        }
        guard let summary, let bps = summary.bits_per_second, bps.isFinite, bps >= 0,
              let seconds = summary.seconds, seconds.isFinite, seconds > 0 else { throw IperfTestError.invalidResponse }
        if transport == .tcp {
            return .init(megabitsPerSecond: bps / 1_000_000, jitterMilliseconds: nil, lossPercent: nil)
        }
        guard let jitter = summary.jitter_ms, jitter.isFinite, jitter >= 0 else { throw IperfTestError.invalidResponse }
        let loss: Double?
        if let percentage = summary.lost_percent { loss = percentage }
        else if let lost = summary.lost_packets, let packets = summary.packets,
                lost.isFinite, packets.isFinite, lost >= 0, packets > 0, lost <= packets {
            loss = lost / packets * 100
        } else { loss = nil }
        guard let loss, loss.isFinite, (0...100).contains(loss) else { throw IperfTestError.invalidResponse }
        return .init(megabitsPerSecond: bps / 1_000_000, jitterMilliseconds: jitter, lossPercent: loss)
    }
}
