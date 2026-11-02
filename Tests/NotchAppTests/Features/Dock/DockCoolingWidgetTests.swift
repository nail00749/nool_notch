import AppKit
import NoolCoolingCore
import SwiftUI
import XCTest
@testable import NotchApp

@MainActor
final class DockCoolingWidgetTests: XCTestCase {
    func testRotorSpeedTracksMeasuredRPMAndStopsForMissingReadings() throws {
        let slow = try XCTUnwrap(CoolingRotorNSView.rotationDuration(rpm: 2000))
        let fast = try XCTUnwrap(CoolingRotorNSView.rotationDuration(rpm: 4000))
        XCTAssertEqual(slow, fast * 2, accuracy: 0.001)
        for rpm in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(CoolingRotorNSView.rotationDuration(rpm: rpm))
        }
        XCTAssertEqual(CoolingRotorNSView.rotationDuration(rpm: 1), 6)
        XCTAssertEqual(CoolingRotorNSView.rotationDuration(rpm: 100_000), 0.5)
    }

    func testQuickManualUsesBothSupportedFansAndHighestRelativeSpeed() {
        let snapshot = CoolingSnapshot(fans: [
            .init(id: 0, name: "Left", currentRPM: 3000, minimumRPM: 2000, maximumRPM: 6000, controlSupported: true),
            .init(id: 1, name: "Right", currentRPM: 5000, minimumRPM: 1000, maximumRPM: 6000, controlSupported: true),
            .init(id: 2, name: "Read only", currentRPM: 9000, minimumRPM: 0, maximumRPM: 9000)
        ])
        XCTAssertEqual(DockCoolingQuickActions.targets(snapshot).map(\.id), [0, 1])
        XCTAssertEqual(DockCoolingQuickActions.manualPercent(snapshot), 80, accuracy: 0.001)
    }

    func testQuickManualHandlesUnavailableAndInvalidReadings() {
        XCTAssertEqual(DockCoolingQuickActions.manualPercent(nil), 50)
        let snapshot = CoolingSnapshot(fans: [
            .init(id: 0, name: "Invalid", currentRPM: .nan, minimumRPM: 0, maximumRPM: 6000, controlSupported: true),
            .init(id: 1, name: "Stopped", currentRPM: 0, minimumRPM: 2000, maximumRPM: 6000, controlSupported: true)
        ])
        XCTAssertEqual(DockCoolingQuickActions.manualPercent(snapshot), 0)
    }

    func testRenderQuickActionsFixture() throws {
        guard ProcessInfo.processInfo.environment["NOOL_COOLING_DOCK_RENDER"] == "1" else {
            throw XCTSkip("Opt-in Dock cooling quick actions fixture")
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: DockCoolingDetails(store: CoolingStore(previewSnapshot: sample), openFullPanel: {}))
        let size = host.fittingSize
        XCTAssertEqual(size.width, 330, accuracy: 1)
        XCTAssertLessThan(size.height, 600)
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/nool-dock-cooling-quick-actions.png"))
    }

    func testCatalogOffersCoolingWithoutAutomaticallyPinningAndPersistsSize() throws {
        let suite = "DockCoolingWidgetTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        XCTAssertEqual(DockIntegrationRegistry.integration("cooling")?.supportedSpans, [1, 2, 3])
        XCTAssertEqual(DockPreferences.integrationTitles["cooling"], "Охлаждение")
        XCTAssertFalse(prefs.items.contains { $0.integrationID == "cooling" })
        XCTAssertTrue(prefs.addIntegration("cooling"))
        XCTAssertFalse(prefs.addIntegration("cooling"))
        let item = try XCTUnwrap(prefs.items.first { $0.integrationID == "cooling" })
        XCTAssertEqual(item.span, 2)
        XCTAssertEqual(DockPreferences(defaults: defaults).items.first { $0.integrationID == "cooling" }, item)
    }

    func testReadingUsesActualRPMAndRecognizedTemperatureZones() {
        let reading = DockCoolingReading(snapshot: sample)
        XCTAssertEqual(reading.fastestRPM, 4200)
        XCTAssertEqual(reading.fastestFraction, 0.7, accuracy: 0.001)
        XCTAssertEqual(reading.temperature, 65)
        XCTAssertEqual(reading.temperatureText, "65°")
        XCTAssertTrue(reading.accessibilitySummary.contains("4200 RPM"))
        XCTAssertNil(DockCoolingReading(snapshot: nil).fastestRPM)
        XCTAssertEqual(DockCoolingReading(snapshot: nil).temperatureText, "—°")
    }

    func testEveryCoolingSpanFitsDockHeight() {
        _ = NSApplication.shared
        let store = CoolingStore(previewSnapshot: sample)
        for span in 1...3 {
            let view = NSHostingView(rootView: DockCoolingWidget(store: store, span: span))
            XCTAssertEqual(view.fittingSize.height, DockLayout.baseHeight, accuracy: 0.5)
        }
    }

    func testNativeDockOrderOutReleasesTelemetrySubscription() async throws {
        _ = NSApplication.shared
        let client = DockCoolingCountingClient(snapshot: sample)
        let store = CoolingStore(testClient: client, snapshot: sample)
        let observation = DockCoolingObservation(store: store)
        let probe = DockCoolingVisibilityNSView(observation: observation)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let window = NSPanel(contentRect: .init(x: screen.midX - 100, y: screen.midY - 40, width: 200, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = probe
        defer { observation.setVisible(false); window.orderOut(nil); window.contentView = nil }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        for _ in 0..<100 where !observation.isViewing || client.reads == 0 {
            pumpWindowEvents()
            try await Task.sleep(for: .milliseconds(10))
        }
        guard window.occlusionState.contains(.visible) else {
            throw XCTSkip("WindowServer did not expose the native Dock fixture")
        }
        XCTAssertTrue(observation.isViewing, "visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), viewWindow=\(probe.window != nil)")
        XCTAssertGreaterThan(client.reads, 0)
        window.orderOut(nil)
        pumpWindowEvents()
        XCTAssertFalse(observation.isViewing)
        let reads = client.reads
        try await Task.sleep(for: .milliseconds(2_150))
        XCTAssertEqual(client.reads, reads, "A hidden native Dock must not keep polling telemetry")
        await store.shutdown()
    }

    func testVisibilitySubscriptionIsIdempotentAndStopsPollingWhenHidden() async throws {
        let client = DockCoolingCountingClient(snapshot: sample)
        let store = CoolingStore(testClient: client, snapshot: sample)
        let observation = DockCoolingObservation(store: store)
        observation.setVisible(true)
        observation.setVisible(true)
        for _ in 0..<100 where client.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(client.reads, 0)
        observation.setVisible(false)
        observation.setVisible(false)
        let reads = client.reads
        try await Task.sleep(for: .milliseconds(2_150))
        XCTAssertEqual(client.reads, reads, "Duplicate show events must not leave an extra telemetry subscription")
        await store.shutdown()
    }

    func testRenderCoolingWidgetFixture() throws {
        guard ProcessInfo.processInfo.environment["NOOL_COOLING_DOCK_RENDER"] == "1" else {
            throw XCTSkip("Opt-in native Dock cooling fixture")
        }
        _ = NSApplication.shared
        let store = CoolingStore(previewSnapshot: sample)
        let host = NSHostingView(rootView:
            HStack(spacing: 12) {
                ForEach(1...3, id: \.self) { span in
                    DockCoolingWidget(store: store, span: span).frame(width: DockLayout.width(span: span, scale: 1))
                }
            }.padding(20).background(Color.black)
        )
        host.frame.size = .init(width: 480, height: 104)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/nool-cooling-dock.png"))
    }

    private var sample: CoolingSnapshot {
        .init(fans: [
            .init(id: 0, name: "Левый", currentRPM: 4200, minimumRPM: 2000, maximumRPM: 6000, controlSupported: true),
            .init(id: 1, name: "Правый", currentRPM: 4000, minimumRPM: 2000, maximumRPM: 6000, controlSupported: true)
        ], sensors: [
            .init(id: "TC0D", name: "CPU", celsius: 65),
            .init(id: "unknown", name: "Неизвестный", celsius: 95, controlEligible: false)
        ], controlAvailable: true)
    }

    private func pumpWindowEvents() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
private final class DockCoolingCountingClient: CoolingClientTransport {
    let value: CoolingSnapshot
    var reads = 0
    init(snapshot: CoolingSnapshot) { value = snapshot }
    func snapshot() async throws -> CoolingSnapshot { reads += 1; return value }
    func apply(_ command: CoolingControlRequest) async throws -> CoolingSnapshot { value }
    func heartbeat(_ sessionID: String) async throws {}
    func release(_ sessionID: String) async throws {}
    func disconnect() {}
}
