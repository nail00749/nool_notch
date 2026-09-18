import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class NoolDockIntegrationTests: XCTestCase {
    func testDockRespectsSpaceReservedForSystemDockAndExternalDisplayOrigin() {
        let visible = NSRect(x: -1_920, y: 75, width: 1_920, height: 965)
        let frame = NoolDockLayout.frame(visibleFrame: visible, contentWidth: 900, scale: 1)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.minY, 87)
        XCTAssertTrue(visible.contains(frame))
        let trigger = NoolDockLayout.triggerFrame(dockFrame: frame)
        XCTAssertEqual(trigger.midX, frame.midX)
        XCTAssertEqual(trigger.minY, frame.minY)
    }

    func testOverflowAndScaleStayInsideSmallScreen() {
        let visible = NSRect(x: 100, y: 100, width: 800, height: 600)
        for scale in [0.8, 1.0, 1.2, Double.nan, Double.infinity] {
            let frame = NoolDockLayout.frame(visibleFrame: visible, contentWidth: 4_000, scale: scale)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.width, 776)
            XCTAssertEqual(frame.midX, visible.midX)
        }
    }

    func testAutohideWaitsForPopoverPointerAndDragToFinish() {
        XCTAssertTrue(NoolDockLayout.canAutoHide(hovered: false, interacting: false, mouseButtons: 0))
        XCTAssertFalse(NoolDockLayout.canAutoHide(hovered: true, interacting: false, mouseButtons: 0))
        XCTAssertFalse(NoolDockLayout.canAutoHide(hovered: false, interacting: true, mouseButtons: 0))
        XCTAssertFalse(NoolDockLayout.canAutoHide(hovered: false, interacting: false, mouseButtons: 1))
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
        let settings = NoolDockSettings(defaults: defaults)
        let model = makeModel()
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 700, height: 88),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: NoolDockView(settings: settings, model: model,
                                                      openSettings: {}, openLauncher: {}, openApplication: { _ in },
                                                      interactionChanged: { _ in }))
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
        let settings = NoolDockSettings(defaults: defaults)
        let coordinator = NoolDockWindowCoordinator(settings: settings, model: makeModel(),
                                                    openSettings: {}, openLauncher: {})
        defer { coordinator.stop() }
        coordinator.start()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Nool Dock" })
        XCTAssertFalse(panel.isVisible)
        settings.isEnabled = true
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY + 12, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 88, accuracy: 1)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        settings.scale = 1.2
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.height, 105.6, accuracy: 1)
        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(panel.contentView?.frame.width ?? 0, panel.frame.width, accuracy: 1)
        settings.isEnabled = false
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(NSApp.windows.first { $0.title == "Показать Nool Dock" }?.isVisible ?? true)
    }

    @MainActor
    private func makeModel(calendar: FakeCalendarProvider = FakeCalendarProvider(),
                           music: FakeNowPlayingProvider = FakeNowPlayingProvider()) -> NotchViewModel {
        NotchViewModel(providers: [], calendarProvider: calendar, nowPlayingProvider: music,
                       liveActivityCenter: LiveActivityCenter(additionalSources: []),
                       jiraProvider: FakeJiraProvider(),
                       preferences: MemoryAppPreferences(hiddenPanelIDs: [.calendar]))
    }
}
