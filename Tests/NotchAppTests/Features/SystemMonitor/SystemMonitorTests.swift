import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class SystemMonitorLayoutTests: XCTestCase {
    func testPreferencesSanitizeAndKeepOneMetric() {
        var preferences = SystemMonitorPreferences()
        preferences.interval = .nan
        preferences.metrics = [.memory, .memory, .cpu]
        preferences.position = .topRight
        XCTAssertEqual(preferences.sanitized.interval, 2)
        XCTAssertEqual(preferences.sanitized.metrics, [.cpu, .memory])
        XCTAssertEqual(preferences.sanitized.position, .right)
        preferences.style = .stack
        preferences.position = .left
        preferences.metrics = []
        XCTAssertEqual(preferences.sanitized.position, .bottomLeft)
        XCTAssertEqual(preferences.sanitized.metrics, [.cpu])
    }

    func testHiddenTriggerIsOnlyEightPixelsWideAndStackMatchesAIQuotas() {
        let screen = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        let visible = CGRect(x: -1_920, y: 48, width: 1_920, height: 1_008)
        for position in SystemMonitorPosition.allCases where position != .left && position != .right {
            var preferences = SystemMonitorPreferences()
            preferences.style = .stack
            preferences.position = position
            let layout = SystemMonitorLayout.overlays(in: screen, visibleFrame: visible, preferences: preferences)
            XCTAssertEqual(layout.trigger.width, 8)
            XCTAssertEqual(layout.trigger.height, QuotaCornerStackLayout.triggerHitHeight)
            XCTAssertTrue(screen.contains(layout.trigger))
            XCTAssertEqual(layout.items.count, preferences.metrics.count)
            for (index, frame) in layout.items.enumerated() {
                XCTAssertTrue(screen.contains(frame))
                XCTAssertEqual(frame, QuotaCornerStackLayout.itemFrame(in: screen, corner: layout.corner, index: index))
            }
            let dockOnSide = CGRect(x: screen.minX + 96, y: screen.minY,
                                   width: screen.width - 96, height: screen.height - 24)
            let withoutDock = SystemMonitorLayout.overlays(in: screen, visibleFrame: screen, preferences: preferences)
            let withSideDock = SystemMonitorLayout.overlays(in: screen, visibleFrame: dockOnSide, preferences: preferences)
            XCTAssertEqual(layout.items, withoutDock.items)
            XCTAssertEqual(layout.trigger, withoutDock.trigger)
            XCTAssertEqual(withSideDock.items, withoutDock.items)
            XCTAssertEqual(withSideDock.trigger, withoutDock.trigger)
        }
    }

    func testSidebarHasSameWaveGeometryAndEdgeTriggerAsQuotas() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let preferences = SystemMonitorPreferences()
        let layout = SystemMonitorLayout.overlays(in: screen, visibleFrame: screen, preferences: preferences)
        XCTAssertEqual(layout.rail, QuotaEdgePanelLayout.railFrame(in: screen, edge: .left, providerCount: 4))
        XCTAssertEqual(layout.trigger.width, 8)
        XCTAssertEqual(layout.trigger.minX, screen.minX)
        XCTAssertEqual(layout.trigger.minY, layout.rail.minY)
        XCTAssertEqual(layout.trigger.height, layout.rail.height)
    }

    func testAvoidsQuotaReservationWithoutOverlappingItsTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let occupied = CGRect(x: 0, y: 270, width: 320, height: 390)
        let preferences = SystemMonitorPreferences()
        let layout = SystemMonitorLayout.overlays(in: screen, visibleFrame: screen,
                                                 preferences: preferences, avoiding: [occupied])
        XCTAssertFalse(layout.rail.intersects(occupied))
        XCTAssertFalse(layout.trigger.intersects(occupied))
        XCTAssertTrue(screen.contains(layout.rail))
    }

    func testMissingMetricsAreNotPresentedAsZero() {
        for metric in SystemMonitorMetric.allCases {
            let reading = SystemMetricReading(metric: metric, snapshot: nil)
            XCTAssertEqual(reading.value, "—")
            XCTAssertNil(reading.fraction)
        }
    }
}

@MainActor
final class SystemMonitorStoreTests: XCTestCase {
    func testPreferencesPersistWithoutStartingCollection() async throws {
        let suite = "SystemMonitorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler = MonitorTestSampler()
        let store = SystemMonitorStore(defaults: defaults, sampler: sampler)
        var preferences = store.preferences
        preferences.style = .stack
        preferences.metrics = [.cpu, .memory]
        store.setPreferences(preferences)
        store.start()
        defer { store.stop() }
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.snapshot)
        let count = await sampler.count
        XCTAssertEqual(count, 0)
        let restored = SystemMonitorStore(defaults: defaults, sampler: sampler)
        XCTAssertEqual(restored.preferences, preferences.sanitized)
    }

    func testDisabledStoreDiscardsInflightReading() async throws {
        let suite = "SystemMonitorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler = MonitorTestSampler(blocked: true)
        let store = SystemMonitorStore(defaults: defaults, sampler: sampler)
        var preferences = store.preferences
        preferences.enabled = true
        store.setPreferences(preferences)
        store.start()
        defer { store.stop() }
        for _ in 0..<100 {
            if await sampler.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await sampler.count
        XCTAssertEqual(count, 1)
        preferences.enabled = false
        store.setPreferences(preferences)
        await sampler.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.snapshot)
    }

    func testIndependentSleepReasonsMustAllClearBeforeResume() async throws {
        let suite = "SystemMonitorTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler = MonitorTestSampler()
        let store = SystemMonitorStore(defaults: defaults, sampler: sampler)
        var preferences = store.preferences
        preferences.enabled = true
        store.setPreferences(preferences)
        store.start()
        defer { store.stop() }
        XCTAssertTrue(store.isRunning)
        store.setSuspended(true, reason: "display")
        store.setSuspended(true, reason: "session")
        store.setSuspended(false, reason: "display")
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.snapshot)
        store.setSuspended(false, reason: "session")
        XCTAssertTrue(store.isRunning)
        for _ in 0..<100 {
            if store.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.snapshot)
        store.stop()
        store.setSuspended(false, reason: "session")
        XCTAssertFalse(store.isRunning)
        XCTAssertNil(store.snapshot)
    }
}

@MainActor
final class SystemMonitorOverlayLifecycleTests: XCTestCase {
    func testOldSettingsActionsCannotOpenAfterReconfigurationOrStop() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let suite = "SystemMonitorOverlayTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SystemMonitorStore(defaults: defaults, sampler: MonitorTestSampler())
        var preferences = store.preferences
        preferences.enabled = true
        store.setPreferences(preferences)
        var opened = 0
        var processSorts: [SystemProcessSort] = []
        let coordinator = SystemMonitorWindowCoordinator(
            store: store, displaySettings: NotchDisplaySettings(defaults: defaults),
            occupiedFrames: { [] }, openSettings: { opened += 1 }, screenProvider: { screen },
            onOpenProcesses: { processSorts.append($0) }
        )
        coordinator.start()
        defer { coordinator.stop() }
        let sidebar = try XCTUnwrap(coordinator.ownedPanels[1].contentView as? NSHostingView<SystemMonitorSidebarView>)
        let oldSidebarAction = sidebar.rootView.onOpenMetric
        preferences.style = .stack
        store.setPreferences(preferences)
        oldSidebarAction(.disk)
        oldSidebarAction(.cpu)
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(processSorts.isEmpty)
        let stack = try XCTUnwrap(coordinator.ownedPanels.compactMap {
            $0.contentView as? NSHostingView<SystemMonitorStackItemView>
        }.first)
        let oldStackAction = stack.rootView.onOpenMetric
        preferences.position = .topRight
        store.setPreferences(preferences)
        oldStackAction(.disk)
        XCTAssertEqual(opened, 0)
        let current = try XCTUnwrap(coordinator.ownedPanels.compactMap {
            $0.contentView as? NSHostingView<SystemMonitorStackItemView>
        }.first)
        current.rootView.onOpenMetric(.disk)
        XCTAssertEqual(opened, 1)
        let cpuView = try XCTUnwrap(coordinator.ownedPanels[1].contentView as? NSHostingView<SystemMonitorSidebarView>)
        cpuView.rootView.onOpenMetric(.cpu)
        XCTAssertEqual(processSorts, [.cpu])
        let memoryView = try XCTUnwrap(coordinator.ownedPanels[1].contentView as? NSHostingView<SystemMonitorSidebarView>)
        memoryView.rootView.onOpenMetric(.memory)
        XCTAssertEqual(processSorts, [.cpu, .memory])
        coordinator.stop()
        current.rootView.onOpenMetric(.disk)
        oldSidebarAction(.disk)
        memoryView.rootView.onOpenMetric(.cpu)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(processSorts, [.cpu, .memory])
    }

    func testSidebarStartsHiddenAndReturnsToTriggerAfterLeaving() async throws {
        try await checkPresentation(style: .sidebar)
    }

    func testStackStartsHiddenAndReturnsToTriggerAfterLeaving() async throws {
        try await checkPresentation(style: .stack)
    }

    private func checkPresentation(style: SystemMonitorStyle) async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let suite = "SystemMonitorOverlayTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SystemMonitorStore(defaults: defaults, sampler: MonitorTestSampler())
        var preferences = store.preferences
        preferences.enabled = true
        preferences.style = style
        preferences.position = style == .sidebar ? .right : .bottomRight
        store.setPreferences(preferences)
        let coordinator = SystemMonitorWindowCoordinator(
            store: store, displaySettings: NotchDisplaySettings(defaults: defaults),
            occupiedFrames: { [] }, openSettings: {}, screenProvider: { screen }
        )
        coordinator.start()
        defer { coordinator.stop() }
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)
        XCTAssertEqual(coordinator.ownedPanels[0].frame.width, 8)
        XCTAssertTrue(coordinator.ownedPanels.dropFirst().allSatisfy { !$0.isVisible })

        coordinator.setSurfaceHovered("trigger", hovering: true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(coordinator.isPresented)
        let expectedContentCount = style == .sidebar ? 1 : preferences.metrics.count
        XCTAssertEqual(coordinator.ownedPanels.dropFirst().filter(\.isVisible).count, expectedContentCount)
        coordinator.setSurfaceHovered("trigger", hovering: false)
        coordinator.setSurfaceHovered("content", hovering: true)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(coordinator.isPresented, "Crossing from trigger to content must not dismiss it")
        coordinator.setSurfaceHovered("content", hovering: false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(coordinator.ownedPanels.dropFirst().allSatisfy { !$0.isVisible })
        XCTAssertTrue(coordinator.ownedPanels[0].isVisible)

        coordinator.setSurfaceHovered("trigger", hovering: true)
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(200))
        coordinator.synchronize()
        XCTAssertTrue(coordinator.ownedPanels.allSatisfy { !$0.isVisible },
                      "A delayed stack reveal must not resurrect stopped windows")
        coordinator.start()
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertTrue(coordinator.ownedPanels.dropFirst().allSatisfy { !$0.isVisible })
    }
}

private actor MonitorTestSampler: SystemMetricsSampling {
    var count = 0
    let blocked: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false) { self.blocked = blocked }
    func reset() {}
    func sample() async -> SystemMetricsSnapshot {
        count += 1
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return SystemMetricsSnapshot(sampledAt: Date(), cpuFraction: 0.4, memory: nil, disk: nil, network: nil)
    }
    func release() { continuation?.resume(); continuation = nil }
}
