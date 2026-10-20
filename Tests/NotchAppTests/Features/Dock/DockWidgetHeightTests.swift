import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

final class DockWidgetHeightTests: XCTestCase {
    @MainActor
    func testEveryWidgetWidthHasTheSameIntrinsicHeight() throws {
        _ = NSApplication.shared
        let suite = "DockWidgetHeightTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DockPreferences(defaults: defaults)
        preferences.noteText = "Длинная заметка, которая занимает две строки в широком виджете"
        let model = NotchViewModel(providers: [], calendarProvider: FakeCalendarProvider(),
                                   nowPlayingProvider: FakeNowPlayingProvider(),
                                   liveActivityCenter: LiveActivityCenter(additionalSources: []),
                                   jiraProvider: FakeJiraProvider(), preferences: MemoryAppPreferences(),
                                   displays: makeTestDisplayFeatureModel())
        for span in 1...3 {
            let widgets: [(String, AnyView)] = [
                ("music", AnyView(DockMusicWidget(model: model, span: span, interactionChanged: { _ in }))),
                ("calendar", AnyView(DockCalendarWidget(model: model, span: span, interactionChanged: { _ in }))),
                ("timer", AnyView(DockTimerWidget(source: model.timerSource, span: span, interactionChanged: { _ in }))),
                ("note", AnyView(DockNoteWidget(preferences: preferences, span: span, interactionChanged: { _ in }))),
                ("batteries", AnyView(DockBatteryWidget(span: span, store: DeviceBatteryStore()))),
                ("systemLoad", AnyView(DockSystemLoadWidget(span: span, store: DockSystemLoadStore()))),
                ("quotas", AnyView(DockQuotaWidget(model: model, span: span))),
                ("toggles", AnyView(DockTogglesWidget(model: model, span: span, store: SystemTogglesStore())))
            ]
            for (name, widget) in widgets {
                let host = NSHostingView(rootView: widget.frame(width: DockLayout.width(span: span, scale: 1)))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.height, DockLayout.baseHeight, accuracy: 0.5,
                               "\(name), span \(span) must retain its common widget height")
            }
        }
        let action = NSHostingView(rootView: DockActionWidget(symbol: "display.2", title: "Дисплеи", action: {})
            .frame(width: DockLayout.width(span: 1, scale: 1)))
        XCTAssertEqual(action.fittingSize.height, DockLayout.baseHeight, accuracy: 0.5)
    }
}
