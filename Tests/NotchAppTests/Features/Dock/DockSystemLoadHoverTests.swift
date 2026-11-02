import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class DockSystemLoadHoverTests: XCTestCase {
    @MainActor
    func testRenderLiveGroupedSummary() async throws {
        guard ProcessInfo.processInfo.environment["NOOL_DOCK_LOAD_RENDER"] == "1" else {
            throw XCTSkip("Opt-in native monitoring fixture with real local readings")
        }
        _ = NSApplication.shared
        let sampler = SystemMetricsSampler()
        let first = await sampler.sample()
        let processes = SystemProcessesStore()
        let details = DockSystemLoadDetailState(processes: processes)
        details.select(.memory)
        defer { details.reset() }
        try await Task.sleep(for: .milliseconds(200))
        let second = await sampler.sample()
        XCTAssertFalse(processes.groups.isEmpty)
        XCTAssertTrue(processes.groups.contains { $0.applicationPath != nil }, "App groups must carry icon paths")
        let host = NSHostingView(rootView: DockSystemLoadSummary(snapshot: second, history: [first, second], details: details))
        host.sizingOptions = []
        let size = NSSize(width: 360, height: 660)
        let panel = NSPanel(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        host.frame = .init(origin: .zero, size: size)
        defer { panel.contentView = nil; panel.close() }
        panel.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/nool-dock-load-live.png"))
    }

    @MainActor
    func testNativeSummaryStaysAnchoredToScaledWidgetWithoutResizingDock() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        for scale in [0.8, 1.2] {
            let hover = DockSystemLoadHoverState()
            let store = DockSystemLoadStore(sampler: LoadSummarySampler())
            let processes = SystemProcessesStore(sampler: LoadDetailSampler())
            let details = DockSystemLoadDetailState(processes: processes)
            let frame = NSRect(x: screen.visibleFrame.midX - 240, y: screen.visibleFrame.minY + 80,
                               width: 480, height: 140)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView:
                DockSystemLoadWidget(span: 2, store: store, hover: hover, details: details)
                    .frame(width: DockLayout.width(span: 2, scale: 1), height: DockLayout.baseHeight)
                    .scaleEffect(scale)
                    .frame(width: DockLayout.width(span: 2, scale: scale),
                           height: DockLayout.baseHeight * scale)
                    .background(LoadAnchorMarker())
                    .frame(width: frame.width, height: frame.height)
            )
            host.sizingOptions = []
            panel.contentView = host
            panel.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let alreadyVisible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            hover.widgetHovered(true)
            hover.open()
            defer {
                hover.dismiss()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                panel.close()
            }
            var popup: NSWindow?
            let deadline = Date().addingTimeInterval(1)
            while popup == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                popup = NSApp.windows.first { $0.isVisible && !alreadyVisible.contains($0.windowNumber) }
            }
            let summary = try XCTUnwrap(popup, "Expected the actual native monitoring popover")
            let marker = try XCTUnwrap(Self.findAnchor(in: host))
            let source = panel.convertToScreen(marker.convert(marker.bounds, to: nil))
            XCTAssertEqual(source.width, DockLayout.width(span: 2, scale: scale), accuracy: 1)
            XCTAssertEqual(summary.frame.midX, source.midX, accuracy: 4)
            XCTAssertGreaterThanOrEqual(summary.frame.minY, source.maxY - 2)
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -2, dy: -2).contains(summary.frame))
            XCTAssertEqual(panel.frame, frame, "The popover must not resize the Dock panel")
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertEqual(panel.frame, frame)
            let summaryFrame = summary.frame
            let visibleWithSummary = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
            details.select(.cpu)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertEqual(processes.sort, .cpu)
            details.select(.memory)
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertTrue(summary.isVisible)
            XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber)), visibleWithSummary,
                           "Inline sections must not open another floating window")
            XCTAssertEqual(summary.frame, summaryFrame, "Expanding CPU/RAM must retain the panel frame")
            XCTAssertEqual(panel.frame, frame)
            XCTAssertTrue(processes.isRunning)
            hover.dismiss()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            XCTAssertFalse(processes.isRunning, "A retained NSPopover content controller must not retain active polling")
            XCTAssertNil(processes.snapshot)
        }
    }

    @MainActor
    func testMetricHoverStartsOnlySupportedSamplerAndBridgesToDetail() async throws {
        let sampler = LoadDetailSampler()
        let processes = SystemProcessesStore(sampler: sampler)
        let state = DockSystemLoadDetailState(processes: processes, openDelay: .milliseconds(10),
                                             closeDelay: .milliseconds(20))
        state.rowHovered(.cpu, inside: true)
        state.rowHovered(.cpu, inside: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(processes.isRunning)
        state.rowHovered(.cpu, inside: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(processes.isRunning)
        XCTAssertTrue(processes.isWarmingUp)
        XCTAssertEqual(state.metric, .cpu)
        state.rowHovered(.cpu, inside: false)
        state.detailHovered(.cpu, inside: true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(state.metric, .cpu)
        XCTAssertTrue(state.keepsSummaryOpen)
        let initialResetCount = await sampler.resetCount
        XCTAssertEqual(initialResetCount, 1)

        state.select(.memory)
        XCTAssertEqual(processes.sort, .memory)
        XCTAssertFalse(processes.isWarmingUp)
        XCTAssertEqual(processes.topProcesses.map(\.name), ["Largest", "Second", "Third", "Fourth", "Fifth"])
        let switchedResetCount = await sampler.resetCount
        XCTAssertEqual(switchedResetCount, 1, "Changing supported metric reuses the current sample stream")
        state.detailHovered(.memory, inside: true)
        state.detailHovered(.cpu, inside: false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(state.metric, .memory, "A closing CPU popover must not dismiss the newly entered RAM detail")
        XCTAssertTrue(processes.isRunning)
        state.select(.network)
        XCTAssertFalse(processes.isRunning)
        XCTAssertNil(processes.snapshot)
        state.select(.disk)
        XCTAssertFalse(processes.isRunning)
        state.dismiss()
        XCTAssertNil(state.metric)
        state.summaryHovered(true)
        state.select(.memory)
        state.dismiss()
        XCTAssertTrue(state.keepsSummaryOpen, "Closing details still over the summary should retain it")
        state.reset()
        XCTAssertFalse(state.keepsSummaryOpen, "Closing the whole summary clears stale hover state")
    }

    @MainActor
    func testMetricDetailsStopWhenPointerLeavesBothSurfaces() async throws {
        let processes = SystemProcessesStore(sampler: LoadDetailSampler())
        let state = DockSystemLoadDetailState(processes: processes, closeDelay: .milliseconds(10))
        state.select(.memory)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(processes.topProcesses.count, 5)
        state.detailHovered(.memory, inside: true)
        state.detailHovered(.memory, inside: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(state.metric)
        XCTAssertFalse(processes.isRunning)
        XCTAssertNil(processes.snapshot)
        XCTAssertFalse(state.keepsSummaryOpen)
    }

    @MainActor
    func testRenderSummaryFixture() throws {
        guard ProcessInfo.processInfo.environment["NOOL_DOCK_LOAD_RENDER"] == "1" else {
            throw XCTSkip("Opt-in monitoring summary rendering")
        }
        _ = NSApplication.shared
        let summaryProcesses = SystemProcessesStore(sampler: LoadDetailSampler(longNames: true))
        summaryProcesses.start(sort: .memory)
        defer { summaryProcesses.stop() }
        let details = DockSystemLoadDetailState(processes: summaryProcesses)
        details.select(.memory)
        let history = (0..<60).map { index in
            SystemMetricsSnapshot(sampledAt: Self.snapshot.sampledAt.addingTimeInterval(Double(index - 59) * 2),
                                  cpuFraction: 0.35 + sin(Double(index) / 5) * 0.1,
                                  memory: .init(usedBytes: 8_000_000_000 + UInt64(index) * 10_000_000,
                                                totalBytes: 16_000_000_000), disk: nil, network: nil)
        }
        let host = NSHostingView(rootView: DockSystemLoadSummary(snapshot: Self.snapshot, history: history, details: details))
        let size = host.fittingSize
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        defer { window.close() }
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/nool-dock-load-summary.png"))

        let processes = SystemProcessesStore(sampler: LoadDetailSampler(longNames: true))
        processes.start(sort: .cpu)
        defer { processes.stop() }
        let deadline = Date().addingTimeInterval(2.5)
        while processes.isWarmingUp && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(processes.isWarmingUp)
        let detailHost = NSHostingView(rootView: DockSystemLoadMetricDetails(metric: .cpu, store: processes))
        let detailSize = detailHost.fittingSize
        let detailWindow = NSPanel(contentRect: NSRect(origin: .zero, size: detailSize), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        detailWindow.isReleasedWhenClosed = false
        detailHost.sizingOptions = []
        detailWindow.contentView = detailHost
        detailHost.frame = NSRect(origin: .zero, size: detailSize)
        defer { detailWindow.close() }
        detailWindow.displayIfNeeded()
        detailHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let detailBitmap = try XCTUnwrap(detailHost.bitmapImageRepForCachingDisplay(in: detailHost.bounds))
        detailHost.cacheDisplay(in: detailHost.bounds, to: detailBitmap)
        let detailData = try XCTUnwrap(detailBitmap.representation(using: .png, properties: [:]))
        try detailData.write(to: URL(fileURLWithPath: "/tmp/nool-dock-load-cpu-details.png"))
    }

    @MainActor
    private static func findAnchor(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "load-summary-anchor" { return view }
        return view.subviews.lazy.compactMap { findAnchor(in: $0) }.first
    }

    private static let snapshot = SystemMetricsSnapshot(
        sampledAt: .now, cpuFraction: 0.42,
        memory: SystemResourceUsage(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000),
        disk: SystemResourceUsage(usedBytes: 100_000_000_000, totalBytes: 500_000_000_000),
        network: SystemNetworkRate(receivedBytesPerSecond: 1_250_000, sentBytesPerSecond: 640_000),
        memoryDetails: .init(compressedBytes: 2_400_000_000, cachedBytes: 1_200_000_000,
                             wiredBytes: 1_500_000_000, swapUsedBytes: 700_000_000,
                             swapTotalBytes: 1_000_000_000, pressure: .normal)
    )

    @MainActor
    func testLeavingBeforeDwellCancelsOpening() async throws {
        let state = DockSystemLoadHoverState(openDelay: .milliseconds(20), closeDelay: .milliseconds(20))
        state.widgetHovered(true)
        state.widgetHovered(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.isPresented)
    }

    @MainActor
    func testHoverOpensAndCanCrossIntoSummaryBeforeClosing() async throws {
        let state = DockSystemLoadHoverState(openDelay: .milliseconds(1), closeDelay: .milliseconds(20))
        state.widgetHovered(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(state.isPresented)
        state.widgetHovered(false)
        state.panelHovered(true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "Moving into the summary must cancel delayed dismissal")
        state.panelHovered(false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented)
    }

    @MainActor
    func testExternalDismissalCancelsPendingOpenAndNeedsPointerExit() async throws {
        let state = DockSystemLoadHoverState(openDelay: .milliseconds(10), closeDelay: .milliseconds(1))
        state.widgetHovered(true)
        state.dismiss()
        state.widgetHovered(true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(state.isPresented, "Escape or a Dock surface change must not reopen under a stationary pointer")
        state.widgetHovered(false)
        state.widgetHovered(true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(state.isPresented)
        state.dismiss()
    }

    @MainActor
    func testClickOpensImmediatelyAndSummaryHandlesMissingAndActualReadings() {
        _ = NSApplication.shared
        let state = DockSystemLoadHoverState()
        state.open()
        XCTAssertTrue(state.isPresented)
        state.presentationChanged(false)
        XCTAssertFalse(state.isPresented)

        let snapshot = SystemMetricsSnapshot(
            sampledAt: .now, cpuFraction: 0.42,
            memory: SystemResourceUsage(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000),
            disk: SystemResourceUsage(usedBytes: 100_000_000_000, totalBytes: 500_000_000_000),
            network: SystemNetworkRate(receivedBytesPerSecond: 1_250_000, sentBytesPerSecond: 640_000)
        )
        XCTAssertEqual(SystemMetricReading(metric: .cpu, snapshot: snapshot).value, "42%")
        XCTAssertEqual(SystemMetricReading(metric: .memory, snapshot: snapshot).fraction, 0.5)
        XCTAssertEqual(SystemMetricReading(metric: .network, snapshot: snapshot).detail, "↑ 640 KB/s")
        XCTAssertEqual(SystemMetricReading(metric: .cpu, snapshot: nil).value, "—")
        var previousSize: NSSize?
        for value in [nil, snapshot] {
            let host = NSHostingView(rootView: DockSystemLoadSummary(snapshot: value))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 360, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, 660, accuracy: 0.5)
            if let previousSize {
                XCTAssertEqual(host.fittingSize.height, previousSize.height, accuracy: 0.5,
                               "First real metrics must not move hovered rows or resize the summary")
            }
            previousSize = host.fittingSize
        }
    }
}

private struct LoadAnchorMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("load-summary-anchor")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private actor LoadSummarySampler: SystemMetricsSampling {
    func sample() async -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(sampledAt: .now, cpuFraction: 0.42, memory: nil, disk: nil, network: nil)
    }
    func reset() async {}
}

private actor LoadDetailSampler: SystemProcessSampling {
    let longNames: Bool
    private(set) var resetCount = 0
    init(longNames: Bool = false) { self.longNames = longNames }
    func reset() async { resetCount += 1 }
    func sample() async -> SystemProcessSnapshot {
        let names = ["Sixth", "Third", "Largest", "Fifth", "Second", "Fourth"]
        let memory: [UInt64] = [1, 4, 6, 2, 5, 3]
        return SystemProcessSnapshot(sampledAt: .now, processes: names.enumerated().map { index, name in
            MonitoredSystemProcess(id: "\(index)", pid: Int32(index + 100),
                                   name: longNames && name == "Fourth" ? "Browser · Web Content Renderer Helper" : name,
                                   cpuPercent: Double(index) * 50, residentMemoryBytes: memory[index] * 1_000_000)
        }, skippedProcessCount: 2)
    }
}
