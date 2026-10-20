import AppKit
import SwiftUI
import XCTest
@testable import NotchApp

/// Opt-in local rendering only. All preferences and system-Dock writes are isolated.
final class DockVisualFixtureTests: XCTestCase {
    @MainActor
    func testRenderMixedDockAndFolder() throws {
        guard ProcessInfo.processInfo.environment["NOOL_DOCK_RENDER_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in Dock visual fixture")
        }
        _ = NSApplication.shared
        let suite = "DockVisualFixture.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DockPreferences(defaults: defaults)
        for item in prefs.items { prefs.remove(id: item.id) }
        _ = prefs.addIntegration("calendar")
        let paths = ["/System/Applications/Calendar.app", "/System/Applications/Mail.app",
                     "/System/Applications/Notes.app", "/System/Applications/Reminders.app",
                     "/System/Applications/Maps.app", "/System/Applications/Music.app"]
        for path in paths { _ = prefs.addApplication(URL(fileURLWithPath: path)) }
        let folderID = prefs.addFolder(name: "На каждый день")
        for app in prefs.items.filter({ $0.kind == .app }).suffix(4) {
            _ = prefs.moveIntoFolder(app.id, folderID: folderID)
        }
        _ = prefs.addIntegration("music")
        prefs.setSpan(3, for: "integration:music")
        _ = prefs.addIntegration("note")
        prefs.setSpan(2, for: "integration:note")
        prefs.noteText = "Идеи для следующего релиза"
        let music = FakeNowPlayingProvider()
        let calendar = FakeCalendarProvider()
        calendar.canLoadWithoutPrompt = true
        let model = NotchViewModel(providers: [], calendarProvider: calendar, nowPlayingProvider: music,
                                   liveActivityCenter: LiveActivityCenter(additionalSources: []),
                                   jiraProvider: FakeJiraProvider(), preferences: MemoryAppPreferences(),
                                   displays: makeTestDisplayFeatureModel())
        music.send(snapshot: .fixture(title: "Neon Tidewater"))
        let apps = DockApplicationStore(catalogLoader: { [] })
        let feature = DockFeatureModel(prefs: prefs, applications: apps,
                                       systemDock: SystemDockController(operations: DockFixtureSystemOperations()))
        feature.availableWidth = 930
        let naturalWidth = prefs.items.reduce(CGFloat(0)) {
            $0 + DockLayout.width(span: $1.span, scale: prefs.scale) + DockLayout.spacing(scale: prefs.scale)
        } + DockLayout.trailingWidth(cells: feature.trailingCellCount, scale: prefs.scale)
        try render(DockView(feature: feature, model: model, interactionChanged: { _ in }, hoverChanged: { _ in })
            .frame(width: naturalWidth, height: DockLayout.height(scale: prefs.scale)), size: NSSize(width: naturalWidth + 100, height: 150),
                   path: "/tmp/nool-dock-mixed-fixture.png")
        let folder = try XCTUnwrap(prefs.items.first { $0.id == folderID })
        try render(DockFolderSurface(preferences: prefs, element: folder, interactionChanged: { _ in }) { item in
            VStack(spacing: 5) {
                DockApplicationIcon(applications: apps, path: item.applicationPath ?? "", title: item.title,
                                    magnification: 0, action: {}).frame(width: 64, height: 57)
                Text(item.title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width: 72, height: 83)
        }.background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 18)),
                   size: NSSize(width: 440, height: 250), path: "/tmp/nool-dock-folder-fixture.png")
        feature.availableWidth = 310
        try render(DockView(feature: feature, model: model, interactionChanged: { _ in }, hoverChanged: { _ in })
            .frame(width: 320, height: DockLayout.height(scale: prefs.scale)), size: NSSize(width: 360, height: 130),
                   path: "/tmp/nool-dock-small-fixture.png")
        prefs.showAppLabels = true
        feature.availableWidth = naturalWidth
        try render(DockView(feature: feature, model: model, interactionChanged: { _ in }, hoverChanged: { _ in })
            .frame(width: naturalWidth, height: DockLayout.height(scale: prefs.scale, showLabels: true)),
                   size: NSSize(width: naturalWidth + 100, height: 160),
                   path: "/tmp/nool-dock-labels-fixture.png")
        var monthCalendar = Calendar(identifier: .gregorian)
        monthCalendar.locale = Locale(identifier: "ru_RU")
        monthCalendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let date = monthCalendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        try render(DockMonthCalendar(model: model, interactionChanged: { _ in },
                                     calendar: monthCalendar, now: date)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 18)),
                   size: NSSize(width: 350, height: 460), path: "/tmp/nool-dock-month-fixture.png")
        try render(HStack(alignment: .top, spacing: 12) {
            ForEach(1...3, id: \.self) { span in
                VStack(spacing: 8) {
                    Text("\(span) \(span == 1 ? "ячейка" : "ячейки")").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    DockMusicWidget(model: model, span: span, interactionChanged: { _ in })
                    DockCalendarWidget(model: model, span: span, interactionChanged: { _ in })
                    DockTimerWidget(source: model.timerSource, span: span, interactionChanged: { _ in })
                    DockNoteWidget(preferences: prefs, span: span, interactionChanged: { _ in })
                }.frame(width: DockLayout.width(span: span, scale: 1))
            }
        }.foregroundStyle(.white), size: NSSize(width: 486, height: 310),
                   path: "/tmp/nool-dock-widget-spans-fixture.png")
    }

    @MainActor
    private func render<V: View>(_ view: V, size: NSSize, path: String) throws {
        let host = NSHostingView(rootView: ZStack {
            LinearGradient(colors: [Color(red: 0.19, green: 0.24, blue: 0.30),
                                    Color(red: 0.04, green: 0.06, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            view
        }.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.sizingOptions = []
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
        window.close()
    }
}

private actor DockFixtureSystemOperations: SystemDockOperating {
    func perform(_ operation: SystemDockOperation) async -> SystemDockOperationResult { .init(active: false) }
}
