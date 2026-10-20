import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class DockIntegrationTests: XCTestCase {
    func testDockRespectsSpaceReservedForSystemDockAndExternalDisplayOrigin() {
        let visible = NSRect(x: -1_920, y: 75, width: 1_920, height: 965)
        let frame = DockLayout.frame(screenFrame: visible, visibleFrame: visible, contentWidth: 900,
                                    scale: 1, replacingSystemDock: false)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.minY, 83)
        XCTAssertTrue(visible.contains(frame))
        let trigger = DockLayout.triggerFrame(screenFrame: visible, dockFrame: frame)
        XCTAssertEqual(trigger.midX, frame.midX)
        XCTAssertEqual(trigger.minY, visible.minY)
    }

    func testOverflowAndScaleStayInsideSmallScreen() {
        let visible = NSRect(x: 100, y: 100, width: 800, height: 600)
        for scale in [0.8, 1.0, 1.2, Double.nan, Double.infinity] {
            let frame = DockLayout.frame(screenFrame: visible, visibleFrame: visible, contentWidth: 4_000,
                                        scale: scale, replacingSystemDock: false)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.width, 776)
            XCTAssertEqual(frame.midX, visible.midX)
        }
    }

    func testAutohideWaitsForPopoverPointerAndDragToFinish() {
        XCTAssertTrue(DockLayout.canHide(hovered: false, interacting: false, mouseButtons: 0))
        XCTAssertFalse(DockLayout.canHide(hovered: true, interacting: false, mouseButtons: 0))
        XCTAssertFalse(DockLayout.canHide(hovered: false, interacting: true, mouseButtons: 0))
        XCTAssertFalse(DockLayout.canHide(hovered: false, interacting: false, mouseButtons: 1))
    }

    @MainActor
    func testDockUsesExistingMusicProviderWithoutLosingNotchVisibility() {
        let music = FakeNowPlayingProvider()
        let model = makeModel(music: music)
        XCTAssertEqual(music.pollingModes.last, .background)
        model.setDockWidgets(musicVisible: true, calendarEnabled: false)
        XCTAssertEqual(music.pollingModes.last, .visibleMusic)
        model.setDockWidgets(musicVisible: false, calendarEnabled: false)
        XCTAssertEqual(music.pollingModes.last, .background)
        model.selectPanel(.music)
        model.isExpanded = true
        model.setDockWidgets(musicVisible: true, calendarEnabled: false)
        model.setDockWidgets(musicVisible: false, calendarEnabled: false)
        XCTAssertEqual(music.pollingModes.last, .visibleMusic)
    }

    @MainActor
    func testDockCalendarDoesNotRequestPermissionInBackground() async {
        let calendar = FakeCalendarProvider()
        let model = makeModel(calendar: calendar)
        model.setDockWidgets(musicVisible: false, calendarEnabled: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
        XCTAssertTrue(model.dockCalendarEvents.isEmpty)
    }

    @MainActor
    func testOpeningCalendarExplicitlyRestoresHiddenNotchPanel() {
        let model = makeModel()
        XCTAssertFalse(model.visiblePanels.contains(.calendar))
        model.openReminderCalendar()
        XCTAssertTrue(model.visiblePanels.contains(.calendar))
        XCTAssertEqual(model.selectedPanel, .calendar)
        XCTAssertTrue(model.isExpanded)
    }

    @MainActor
    func testDockCalendarLoadsWhenNotchCalendarIsHiddenAndClearsWhenDisabled() async {
        let calendar = FakeCalendarProvider()
        let event = CalendarEvent(id: "dock-event", title: "Design review",
                                  startDate: .now.addingTimeInterval(600), endDate: .now.addingTimeInterval(1800),
                                  isAllDay: false, calendarTitle: "Work")
        calendar.canLoadWithoutPrompt = true
        calendar.upcomingState = .loaded(CalendarSnapshot(upcomingEvents: [event], monthEvents: []))
        let model = makeModel(calendar: calendar)
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 0)
        model.setDockWidgets(musicVisible: false, calendarEnabled: true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calendar.loadUpcomingEventsCallCount, 1)
        XCTAssertEqual(model.dockCalendarEvents, [event])
        XCTAssertNil(model.compactMeetingReminder)
        model.setDockWidgets(musicVisible: false, calendarEnabled: false)
        XCTAssertTrue(model.dockCalendarEvents.isEmpty)
    }

    @MainActor
    func testNativeDockHostingCannotResizeItsWindowAfterItemChanges() throws {
        let suite = "NoolDockIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DockPreferences(defaults: defaults)
        let feature = makeFeature(settings)
        let model = makeModel()
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 700, height: 88),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: DockView(feature: feature, model: model,
                                                  interactionChanged: { _ in }, hoverChanged: { _ in }))
        host.sizingOptions = []
        window.contentView = host
        let initial = window.frame
        for item in settings.items { settings.remove(id: item.id) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(window.frame, initial)
        XCTAssertEqual(host.frame.width, initial.width, accuracy: 1)
    }

    @MainActor
    func testCoordinatorPositionsResizesAndDisablesRealPanels() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let suite = "NoolDockWindowTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DockPreferences(defaults: defaults)
        settings.visibility = .always
        settings.displayUUID = DockWindowCoordinator.uuid(for: screen)
        let coordinator = DockWindowCoordinator(feature: makeFeature(settings), model: makeModel())
        defer { coordinator.stop() }
        coordinator.start()
        let panel = coordinator.ownedPanel
        XCTAssertFalse(panel.isVisible)
        settings.isEnabled = true
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY + 8, accuracy: 1)
        // The strip is 64 pt; the panel adds transparent headroom above it for bouncing icons.
        XCTAssertEqual(panel.frame.height, 64 + DockLayout.headroom(scale: 1), accuracy: 1)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        settings.scale = 1.2
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.height, 76.8 + DockLayout.headroom(scale: 1.2), accuracy: 1)
        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(panel.contentView?.frame.width ?? 0, panel.frame.width, accuracy: 1)
        settings.isEnabled = false
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(coordinator.ownedTrigger.isVisible)
    }

    @MainActor
    func testUnresolvedStartupRecoveryKeepsRecoveryActionVisibleWhenModuleIsOff() async throws {
        _ = NSApplication.shared
        let suite = "DockRecoveryUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        prefs.isEnabled = false
        let controller = SystemDockController(operations: DockTestPendingRecovery())
        let feature = DockFeatureModel(prefs: prefs, systemDock: controller)
        let coordinator = DockWindowCoordinator(feature: feature, model: makeModel())
        await coordinator.waitForRestoration()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(controller.recoveryPending)
        XCTAssertTrue(coordinator.ownedPanel.isVisible)
        XCTAssertEqual(coordinator.ownedPanel.frame.width, 360)
        coordinator.stop()
        await coordinator.waitForRestoration()
        coordinator.ownedPanel.orderOut(nil)
    }

    @MainActor
    func testReenablingAfterFailedRestoreDoesNotKeepRecoveryPanelGeometry() async throws {
        _ = NSApplication.shared
        guard NSScreen.screens.first != nil else { throw XCTSkip("Requires an AppKit display") }
        let suite = "DockRecoveryGeometry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        prefs.visibility = .always
        prefs.isEnabled = true
        let operations = DockTestFailingRestore()
        let controller = SystemDockController(operations: operations)
        let coordinator = DockWindowCoordinator(feature: DockFeatureModel(prefs: prefs, systemDock: controller),
                                                model: makeModel())
        defer { coordinator.stop(); coordinator.ownedPanel.orderOut(nil) }
        coordinator.start()
        prefs.replaceSystemDock = true
        await coordinator.waitForRestoration()
        let dockFrame = coordinator.ownedPanel.frame
        XCTAssertTrue(controller.isActive)
        await operations.setFailRestore(true)
        prefs.isEnabled = false
        await coordinator.waitForRestoration()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(coordinator.ownedPanel.frame.width, 360)
        prefs.replaceSystemDock = false
        prefs.isEnabled = true
        XCTAssertNotEqual(coordinator.ownedPanel.frame.width, 360)
        XCTAssertEqual(coordinator.ownedPanel.frame.height, dockFrame.height, accuracy: 1)
    }

    func testCellGeometryAndTemporarySpanDoNotChangeSavedChoice() {
        XCTAssertEqual(DockLayout.width(span: 3, scale: 1), 204)
        XCTAssertEqual(DockLayout.effectiveSpan(3, supported: [1, 2, 3], availableWidth: 140, scale: 1), 2)
        XCTAssertEqual(DockLayout.effectiveSpan(3, supported: [1, 2, 3], availableWidth: 600, scale: 1), 3)
    }

    func testPrimaryDisplaySelectionIgnoresFocusedScreenOrder() {
        let screens: [(id: UInt32, uuid: String)] = [(20, "focused-external"), (10, "system-primary")]
        XCTAssertEqual(DockLayout.selectedDisplayID(preferredUUID: "", displays: screens, primaryID: 10), 10)
        XCTAssertEqual(DockLayout.selectedDisplayID(preferredUUID: "focused-external", displays: screens, primaryID: 10), 20)
        XCTAssertEqual(DockLayout.selectedDisplayID(preferredUUID: "disconnected", displays: screens, primaryID: 10), 10)
        XCTAssertNil(DockLayout.selectedDisplayID(preferredUUID: "", displays: [], primaryID: 10))
    }

    @MainActor
    private func makeFeature(_ prefs: DockPreferences) -> DockFeatureModel {
        DockFeatureModel(prefs: prefs, systemDock: SystemDockController(operations: DockTestSystemOperations()))
    }

    @MainActor
    private func makeModel(calendar: FakeCalendarProvider = FakeCalendarProvider(),
                           music: FakeNowPlayingProvider = FakeNowPlayingProvider()) -> NotchViewModel {
        NotchViewModel(providers: [], calendarProvider: calendar, nowPlayingProvider: music,
                       liveActivityCenter: LiveActivityCenter(additionalSources: []),
                       jiraProvider: FakeJiraProvider(),
                       preferences: MemoryAppPreferences(hiddenPanelIDs: [.calendar]),
                       modules: AppModuleStore(defaults: nil),
                       displays: makeTestDisplayFeatureModel())
    }
}

private actor DockTestSystemOperations: SystemDockOperating {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        switch operation {
        case .enable: .init(active: true)
        case .restore, .recover: .init(active: false)
        }
    }
}

private actor DockTestPendingRecovery: SystemDockOperating {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        .init(active: false, error: "Fixture restore failed", recoveryPending: true)
    }
}

private actor DockTestFailingRestore: SystemDockOperating {
    private var failRestore = false
    func setFailRestore(_ value: Bool) { failRestore = value }
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult {
        if operation == .enable { return .init(active: true) }
        return failRestore ? .init(active: false, error: "Fixture restore failed", recoveryPending: true) : .init(active: false)
    }
}
