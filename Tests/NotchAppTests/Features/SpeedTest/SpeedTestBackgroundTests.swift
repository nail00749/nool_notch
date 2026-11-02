import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class SpeedTestBackgroundTests: XCTestCase {
    func testHTTPContinuesAfterNativePopoverDismissal() async throws {
        _ = NSApplication.shared
        let suite = "speedtest-popover-background-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = BackgroundTestGate()
        let session = SpeedTestSession(http: SpeedTestStore(runner: BackgroundHTTP(gate: gate), defaults: defaults),
                                      iperf: IperfTestStore(defaults: defaults))
        let screen = try XCTUnwrap(NSScreen.main)
        let dock = NSPanel(contentRect: .init(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY,
                                            width: 150, height: 56),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        dock.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DockSpeedTestWidget(session: session, span: 2, interactionChanged: { _ in }))
        host.sizingOptions = []
        dock.contentView = host
        dock.orderFrontRegardless()
        defer { session.cancel(); dock.contentView = nil; dock.close() }
        host.layoutSubtreeIfNeeded()
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView:
            DockSpeedTestDetails(session: session, didStart: {}, openFullPanel: {}))
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .maxY)
        defer { popover.close() }
        XCTAssertTrue(popover.isShown)
        XCTAssertTrue(session.startHTTP())
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(session.isRunning)
        popover.close()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(session.isCancelling)
        await gate.release()
        await session.waitForCompletion()
        XCTAssertEqual(session.http.history.count, session.http.servers.count)
    }

    func testHTTPFinishesAndPersistsAfterWindowCloseAndDockRemoval() async throws {
        _ = NSApplication.shared
        let suite = "speedtest-background-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = BackgroundTestGate()
        let http = SpeedTestStore(runner: BackgroundHTTP(gate: gate), defaults: defaults)
        let session = SpeedTestSession(http: http, iperf: IperfTestStore(defaults: defaults))
        let coordinator = SpeedTestWindowCoordinator(session: session)
        defer { coordinator.stop() }
        coordinator.show()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Speedtest" })
        XCTAssertTrue(session.startHTTP())
        let run = session.activeRunID
        window.orderOut(nil)
        window.close()
        // Removing the Dock's hosting view must not own or cancel the session.
        let dock = NSPanel(contentRect: .init(x: 0, y: 0, width: 150, height: 56),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        dock.isReleasedWhenClosed = false
        dock.contentView = NSHostingView(rootView: DockSpeedTestWidget(session: session, span: 2,
                                                                     interactionChanged: { _ in }))
        dock.contentView?.layoutSubtreeIfNeeded()
        dock.contentView = nil
        dock.close()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(session.isCancelling)
        XCTAssertEqual(session.activeRunID, run)
        coordinator.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(session.activeRunID, run, "Reopening must observe the existing run")
        window.close()
        await gate.release()
        await session.waitForCompletion()
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(http.history.count, http.servers.count)
        XCTAssertEqual(SpeedTestStore(defaults: defaults).history.count, http.servers.count)
    }

    func testIperfSurvivesCloseButApplicationStopCancelsIt() async throws {
        _ = NSApplication.shared
        let suite = "iperf-background-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let iperf = IperfTestStore(runner: BackgroundIperf(), defaults: defaults)
        iperf.configuration.host = "test.example"
        let session = SpeedTestSession(http: SpeedTestStore(defaults: defaults), iperf: iperf)
        let coordinator = SpeedTestWindowCoordinator(session: session)
        defer { coordinator.stop() }
        coordinator.show(section: .iperf)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Speedtest" && $0.isVisible })
        XCTAssertTrue(session.startIperf())
        window.close()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(iperf.isRunning)
        XCTAssertFalse(iperf.isCancelling)
        coordinator.stop()
        XCTAssertTrue(iperf.isCancelling)
        await coordinator.waitForCompletion()
        XCTAssertFalse(iperf.isRunning)
        XCTAssertNil(iperf.result)
    }
}

private actor BackgroundTestGate {
    private var released = false
    func release() { released = true }
    func wait() async throws {
        while !released { try await Task.sleep(for: .milliseconds(5)) }
    }
}

private struct BackgroundHTTP: SpeedTestRunning {
    let gate: BackgroundTestGate
    func run(server: SpeedTestServer, onProgress: @escaping @Sendable (SpeedTestProgress) -> Void) async throws -> SpeedTestMeasurement {
        onProgress(.init(phase: .download, fraction: 0.5, megabitsPerSecond: 80))
        try await gate.wait()
        return .init(serverID: server.id, measuredAt: Date(), latencyMilliseconds: 12,
                     jitterMilliseconds: 1, downloadMbps: 80, uploadMbps: 20, transferredBytes: 100)
    }
}

private struct BackgroundIperf: IperfTestRunning {
    func run(configuration: IperfTestConfiguration, onPhase: @escaping @Sendable (String) -> Void) async throws -> IperfTestResult {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
