import AppKit
import NoolCoolingCore
import SwiftUI
import XCTest
@testable import NotchApp

final class CoolingPanelFixtureTests: XCTestCase {
    @MainActor
    func testReadOnlyLiveSnapshotRenders() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_COOLING_RENDER_FIXTURE"] == "1",
              let input = ProcessInfo.processInfo.environment["NOOL_COOLING_LIVE_FIXTURE_PATH"], !input.isEmpty else {
            throw XCTSkip("Opt-in rendering of an explicitly supplied live snapshot")
        }
        _ = NSApplication.shared
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let snapshot = try JSONDecoder().decode(CoolingSnapshot.self, from: data)
        let store = CoolingStore(previewSnapshot: snapshot, history: [snapshot])
        try await render(CoolingPanel(store: store), path: "/tmp/nool-cooling-live.png")
        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertFalse(store.isBusy)
    }

    @MainActor
    func testNativePresentationStartsAndStopsObservation() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_COOLING_RENDER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in native presentation lifecycle")
        }
        _ = NSApplication.shared
        let client = CoolingPresentationFixtureClient(value: fixture(at: Date(), mode: .automatic))
        let store = CoolingStore(testClient: client, snapshot: client.value)
        let hosting = NSHostingView(rootView: CoolingPanel(store: store))
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 580, height: 690),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.displayIfNeeded()
        for _ in 0..<50 where client.reads == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(client.reads, 0, "Mounting the real hosting view must subscribe to monitoring")
        panel.contentView = nil
        panel.close()
        for _ in 0..<8 { await Task.yield() }
        let readsAtClose = client.reads
        try await Task.sleep(for: .milliseconds(2_150))
        XCTAssertEqual(client.reads, readsAtClose, "Removing the hosting view must release its observation")
        await store.shutdown()
    }

    @MainActor
    func testNativeCoolingPanelsRenderWithoutStartingHardwareControl() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_COOLING_RENDER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in native cooling panel fixture")
        }
        _ = NSApplication.shared
        let now = Date()
        for mode in [CoolingControlMode.manual, .curve, .boost] {
            let snapshot = fixture(at: now, mode: mode)
            let history = (0..<60).map { index in
                var value = fixture(at: now.addingTimeInterval(Double(index - 59) * 2), mode: mode)
                value.sensors[0].celsius = 59 + sin(Double(index) / 7) * 6 + Double(index) / 8
                return value
            }
            let store = CoolingStore(previewSnapshot: snapshot, history: history)
            try await render(CoolingPanel(store: store), path: "/tmp/nool-cooling-\(mode.rawValue).png")
            if mode == .manual {
                try await render(CoolingPanel(store: store).preferredColorScheme(.dark), path: "/tmp/nool-cooling-dark.png")
            }
            XCTAssertEqual(store.snapshot, snapshot)
            XCTAssertFalse(store.isBusy)
        }
        let missing = CoolingStore(previewSnapshot: .init(notice: "SMC не предоставил доступные вентиляторы."))
        try await render(CoolingPanel(store: missing), path: "/tmp/nool-cooling-unavailable.png")
    }

    @MainActor
    private func render<V: View>(_ view: V, path: String) async throws {
        let size = NSSize(width: 580, height: 690)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.sizingOptions = []
        let panel = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        panel.contentView = hosting
        hosting.frame = .init(origin: .zero, size: size)
        panel.displayIfNeeded()
        for _ in 0..<8 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.size, size)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 8_000)
        try data.write(to: .init(fileURLWithPath: path))
    }

    private func fixture(at date: Date, mode: CoolingControlMode) -> CoolingSnapshot {
        .init(sampledAt: date, fans: [
            .init(id: 0, name: "Left", currentRPM: 3147, minimumRPM: 2317, maximumRPM: 6800, targetRPM: 4100,
                  mode: mode, controlSupported: true, boostEndsAt: mode == .boost ? Date().addingTimeInterval(180) : nil,
                  sensorID: "cpu", curve: [.init(temperature: 45, percent: 0), .init(temperature: 60, percent: 30),
                                           .init(temperature: 75, percent: 65), .init(temperature: 90, percent: 100)]),
            .init(id: 1, name: "Right", currentRPM: 3104, minimumRPM: 2317, maximumRPM: 6800, mode: .automatic, controlSupported: true)
        ], sensors: [.init(id: "cpu", name: "CPU Performance", celsius: 64.4),
                     .init(id: "gpu", name: "GPU", celsius: 59.2),
                     .init(id: "battery", name: "Батарея", celsius: 32.5)], controlAvailable: true)
    }
}

@MainActor
private final class CoolingPresentationFixtureClient: CoolingClientTransport {
    let value: CoolingSnapshot
    var reads = 0
    init(value: CoolingSnapshot) { self.value = value }
    func snapshot() async throws -> CoolingSnapshot { reads += 1; return value }
    func apply(_ command: CoolingControlRequest) async throws -> CoolingSnapshot {
        XCTFail("Rendering a presentation must never apply fan control")
        throw CoolingError.invalidRequest("Unexpected fixture control command")
    }
    func heartbeat(_ sessionID: String) async throws {}
    func release(_ sessionID: String) async throws {}
    func disconnect() {}
}
