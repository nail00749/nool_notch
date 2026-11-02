import AppKit
import QuartzCore
import XCTest
@testable import NotchApp

@MainActor
final class DockSystemLoadActivityIconTests: XCTestCase {
    func testNoSampleAndReduceMotionKeepGlyphsStill() throws {
        _ = NSApplication.shared
        let noSample = DockSystemLoadActivityIconNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        noSample.configure(metric: .cpu, color: .systemGreen, hasSample: false,
                           receivedBytesPerSecond: 0, sentBytesPerSecond: 0, reduceMotion: false)
        XCTAssertTrue(animationKeys(in: noSample).isEmpty)

        let icon = DockSystemLoadActivityIconNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        let window = panel(content: icon)
        defer { window.close() }
        pump(for: 0.08)
        try requireVisible(window)

        icon.configure(metric: .cpu, color: .systemGreen, hasSample: true,
                       receivedBytesPerSecond: 0, sentBytesPerSecond: 0, reduceMotion: true)
        XCTAssertTrue(animationKeys(in: icon).isEmpty, "Reduce Motion disables the decorative CPU pulse")
    }

    func testCpuMemoryAndDiskUseTheirIntendedAnimationsWhenVisible() throws {
        _ = NSApplication.shared
        let cases: [(SystemMonitorMetric, String)] = [
            (.cpu, "system-load.cpu-pulse"),
            (.memory, "system-load.memory-pulse"),
            (.disk, "system-load.disk-glow")
        ]
        for (metric, expectedKey) in cases {
            let icon = DockSystemLoadActivityIconNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
            let window = panel(content: icon)
            defer { window.close() }
            pump(for: 0.06)
            try requireVisible(window)
            icon.configure(metric: metric, color: .systemOrange, hasSample: true,
                           receivedBytesPerSecond: 0, sentBytesPerSecond: 0, reduceMotion: false)
            let keys = animationKeys(in: icon)
            XCTAssertTrue(keys.contains(expectedKey), "Expected \(expectedKey) for \(metric)")
            if metric == .disk {
                XCTAssertFalse(keys.contains("system-load.disk-io"), "Disk usage does not claim disk I/O")
            }
            window.close()
        }
    }

    func testNetworkArrowsMoveOnlyForTheirActualTrafficDirectionsAndStopWhenHidden() throws {
        _ = NSApplication.shared
        let icon = DockSystemLoadActivityIconNSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        let window = panel(content: icon)
        defer { window.close() }
        pump(for: 0.06)
        try requireVisible(window)

        icon.configure(metric: .network, color: .systemGreen, hasSample: true,
                       receivedBytesPerSecond: 0, sentBytesPerSecond: 0, reduceMotion: false)
        XCTAssertFalse(animationKeys(in: icon).contains("system-load.network-receive"))
        XCTAssertFalse(animationKeys(in: icon).contains("system-load.network-send"))

        icon.configure(metric: .network, color: .systemGreen, hasSample: true,
                       receivedBytesPerSecond: 120, sentBytesPerSecond: 0, reduceMotion: false)
        XCTAssertTrue(animationKeys(in: icon).contains("system-load.network-receive"))
        XCTAssertFalse(animationKeys(in: icon).contains("system-load.network-send"))

        icon.configure(metric: .network, color: .systemGreen, hasSample: true,
                       receivedBytesPerSecond: 0, sentBytesPerSecond: 80, reduceMotion: false)
        XCTAssertFalse(animationKeys(in: icon).contains("system-load.network-receive"))
        XCTAssertTrue(animationKeys(in: icon).contains("system-load.network-send"))

        window.orderOut(nil)
        pump(for: 0.08)
        XCTAssertFalse(animationKeys(in: icon).contains("system-load.network-send"),
                       "Ordering out the Dock panel stops network arrow motion")
    }

    private func animationKeys(in icon: DockSystemLoadActivityIconNSView) -> Set<String> {
        Set(icon.subviews.compactMap(\.layer).flatMap { $0.animationKeys() ?? [] })
    }

    private func panel(content: NSView) -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let panel = NSPanel(contentRect: CGRect(x: screen.midX - 20, y: screen.midY - 20, width: 40, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        return panel
    }

    private func requireVisible(_ window: NSWindow) throws {
        let deadline = Date().addingTimeInterval(1)
        while !window.occlusionState.contains(.visible), Date() < deadline {
            pump(for: 0.02)
        }
        guard window.isVisible, window.occlusionState.contains(.visible) else {
            throw XCTSkip("AppKit did not report the test panel visible; native visibility-bound animation checks were skipped.")
        }
    }

    private func pump(for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any,
                                          until: min(until, Date().addingTimeInterval(0.01)),
                                          inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
        }
    }
}
