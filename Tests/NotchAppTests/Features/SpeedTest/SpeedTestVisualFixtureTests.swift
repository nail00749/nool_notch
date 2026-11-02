import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class SpeedTestVisualFixtureTests: XCTestCase {
    @MainActor
    func testDockAndExpandedHTTPAndUDPFixtures() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_SPEEDTEST_RENDER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in AppKit visual fixtures")
        }
        _ = NSApplication.shared
        let suite = "speedtest-fixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = SpeedTestSession(http: SpeedTestStore(runner: FixtureHTTP(), defaults: defaults),
            iperf: IperfTestStore(runner: FixtureIperf(), defaults: defaults))
        session.iperf.configuration.host = "speed.example"
        session.iperf.configuration.transport = .udp
        XCTAssertTrue(session.startHTTP())
        await session.waitForCompletion()
        XCTAssertTrue(session.startIperf())
        await session.waitForCompletion()
        for _ in 0..<10 { await Task.yield() }
        try render(HStack(spacing: 16) {
            ForEach(1...3, id: \.self) { span in
                DockSpeedTestWidget(session: session, span: span, interactionChanged: { _ in })
                    .frame(width: DockLayout.width(span: span, scale: 1), height: 56)
            }
        }.padding(20), size: .init(width: 520, height: 100), path: "/tmp/nool-speedtest-dock.png")
        for section in [DockSpeedTestDetails.Section.http, .iperf, .diagnostics] {
            try render(DockSpeedTestDetails(session: session, initialSection: section,
                didStart: {}, openFullPanel: {}), size: .init(width: 408, height: 540),
                path: "/tmp/nool-speedtest-\(section.rawValue).png")
        }
        try render(SpeedTestView(session: session, store: session.http, diagnostics: session.diagnostics,
                                 navigation: SpeedTestNavigation()), size: .init(width: 760, height: 540),
                   path: "/tmp/nool-speedtest-full.png")
        try render(HStack {
            SpeedTestDial(value: 428.5, phase: .download, isRunning: true)
            SpeedTestDial(value: 87.3, phase: .upload, isRunning: true)
            SpeedTestDial(value: nil, isRunning: true, compact: true)
            SpeedTestActivityIcon(value: 428.5, isRunning: true)
        }.padding(12), size: .init(width: 760, height: 220), path: "/tmp/nool-speedtest-active.png")
        let active = SpeedTestSession(http: SpeedTestStore(runner: FixtureActiveHTTP(), defaults: defaults),
                                      iperf: IperfTestStore(defaults: defaults))
        XCTAssertTrue(active.startHTTP())
        try await Task.sleep(for: .milliseconds(30))
        try render(DockSpeedTestDetails(session: active, didStart: {}, openFullPanel: {}),
                   size: .init(width: 408, height: 540), path: "/tmp/nool-speedtest-running.png")
        active.cancel()
        await active.waitForCompletion()
        XCTAssertFalse(active.isRunning)
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color.black.opacity(0.9)).preferredColorScheme(.dark))
        host.sizingOptions = []
        let window = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = host
        host.frame = .init(origin: .zero, size: size)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

private struct FixtureHTTP: SpeedTestRunning {
    func run(server: SpeedTestServer, onProgress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestMeasurement {
        .init(serverID: server.id, measuredAt: Date(), latencyMilliseconds: 28, jitterMilliseconds: 1.4,
              downloadMbps: 248.7, uploadMbps: 94.2, transferredBytes: 1024)
    }
}
private struct FixtureActiveHTTP: SpeedTestRunning {
    func run(server: SpeedTestServer, onProgress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestMeasurement {
        onProgress(.init(phase: .download, fraction: 0.4, megabitsPerSecond: 428.5))
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
private struct FixtureIperf: IperfTestRunning {
    func run(configuration: IperfTestConfiguration, onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult {
        .init(downloadMbps: 49.8, uploadMbps: 49.6, jitterMilliseconds: 0.6, lossPercent: 0.12,
              measuredAt: Date(), transport: configuration.transport, host: configuration.host)
    }
}
