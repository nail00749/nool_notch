import Darwin
import XCTest
@testable import NotchApp

final class IperfTestLoopbackTests: XCTestCase {
    func testRealTCPAndUDPOnOwnLoopbackServer() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_IPERF_LOOPBACK_TEST"] == "1" else {
            throw XCTSkip("Opt-in loopback-only iperf3 integration")
        }
        guard let executable = IperfTestRunner.installedExecutable else { throw XCTSkip("iperf3 is not installed") }
        let port = try availablePort()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["-s", "-B", "127.0.0.1", "-p", String(port), "--server-max-duration", "3"]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        // This test owns the server; its startup needs no external host or daemon.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(server.isRunning)
        let runner = IperfTestRunner(executable: executable)
        for transport in IperfTestTransport.allCases {
            let config = IperfTestConfiguration(host: "127.0.0.1", port: port, durationSeconds: 1,
                udpMegabitsPerSecond: 1, transport: transport)
            let result = try await runner.run(configuration: config, onPhase: { _ in })
            XCTAssertGreaterThan(result.uploadMbps, 0)
            XCTAssertGreaterThan(result.downloadMbps, 0)
            XCTAssertEqual(result.host, "127.0.0.1")
            XCTAssertEqual(result.transport, transport)
            if transport == .udp {
                XCTAssertNotNil(result.jitterMilliseconds)
                XCTAssertNotNil(result.lossPercent)
            } else {
                XCTAssertNil(result.jitterMilliseconds)
                XCTAssertNil(result.lossPercent)
            }
        }
    }

    private func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
