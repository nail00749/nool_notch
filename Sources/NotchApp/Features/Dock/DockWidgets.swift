import AppKit
import SwiftUI

extension View {
    /// Click target for Dock cells. A SwiftUI `Button` on macOS tracks the mouse press itself,
    /// so the cell's `.onDrag` never starts and icons can't be reordered; a tap gesture
    /// leaves the drag to AppKit while VoiceOver still sees a button.
    /// `fillsFrame: false` keeps clicks on transparent gaps passing through (the fan).
    func dockTapTarget(_ label: String, fillsFrame: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(DockTapShape(fills: fillsFrame))
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct DockTapShape: ViewModifier {
    let fills: Bool
    func body(content: Content) -> some View {
        if fills { content.contentShape(Rectangle()) } else { content }
    }
}

struct DockActionWidget: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol).font(.system(size: 24, weight: .regular))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dockWidgetSurface().dockTapTarget(title, action: action).help(title)
    }
}

struct DockCalendarWidget: View {
    @ObservedObject var model: NotchViewModel
    let span: Int
    let interactionChanged: (Bool) -> Void
    @State private var showsDetails = false

    private var emptyStatus: String {
        switch model.calendarState {
        case .idle: "Откройте календарь"
        case .loading: "Загрузка…"
        case .loaded: "Ближайших событий нет"
        case .denied: "Нет доступа к календарю"
        }
    }
    private var compactStatus: String {
        switch model.calendarState {
        case .idle: "Открыть"
        case .loading: "Загрузка"
        case .loaded: "Сегодня"
        case .denied: "Нет доступа"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let events = model.dockCalendarEvents.filter { !$0.isAllDay && $0.endDate > context.date }
                .sorted { $0.startDate < $1.startDate }
            Group {
                HStack(spacing: 9) {
                    VStack(spacing: 1) {
                        Text(context.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(.red.opacity(0.9))
                        Text(context.date.formatted(.dateTime.day())).font(.system(size: 25, weight: .medium))
                    }.frame(width: 42, height: 44)
                    if span > 1 {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(events.first?.title ?? "Нет встреч").font(.system(size: span == 2 ? 10 : 11, weight: .semibold))
                            Text(events.first.map { $0.startDate.formatted(date: .omitted, time: .shortened) }
                                 ?? (span == 2 ? compactStatus : emptyStatus))
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                        }.lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, span > 1 ? 8 : 0).dockWidgetSurface()
            }.dockTapTarget("Календарь") { showsDetails.toggle() }.help("Календарь")
                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                    DockMonthCalendar(model: model, interactionChanged: interactionChanged)
                }
        }
    }
}

struct DockTimerWidget: View {
    @ObservedObject var source: NoolTimerSource
    let span: Int
    let interactionChanged: (Bool) -> Void
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "timer").font(.system(size: 24)).frame(width: 40)
            if span > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.snapshot?.countdownText ?? "Таймер").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    Text(source.snapshot?.state == .paused ? "Пауза" : source.snapshot == nil ? "Быстрый старт" : "Осталось")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, span > 1 ? 8 : 0).dockWidgetSurface()
            .dockTapTarget(source.snapshot?.countdownText ?? "Таймер") { showsDetails.toggle() }.help("Таймер")
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                VStack(spacing: 16) {
                    Text(source.snapshot?.countdownText ?? "Таймер").font(.system(size: 30, weight: .medium)).monospacedDigit()
                    if let snapshot = source.snapshot {
                        HStack {
                            Button(snapshot.state == .active ? "Пауза" : "Продолжить", action: source.toggle)
                                .disabled(snapshot.state == .completed)
                            Button("Сбросить", action: source.cancel)
                        }
                    } else {
                        HStack {
                            ForEach([5, 15, 25, 60], id: \.self) { minutes in
                                Button("\(minutes) мин") { _ = source.create(duration: TimeInterval(minutes * 60)) }
                            }
                        }
                    }
                }.padding(20).preferredColorScheme(.dark)
                    .onAppear { interactionChanged(true) }.onDisappear { interactionChanged(false) }
            }
    }
}

struct DockNoteWidget: View {
    @ObservedObject var preferences: DockPreferences
    let span: Int
    let interactionChanged: (Bool) -> Void
    @State private var showsEditor = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "note.text").font(.system(size: 24)).frame(width: 40)
            if span > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Заметка").font(.system(size: 11, weight: .semibold))
                    Text(preferences.noteText.isEmpty ? "Написать…" : preferences.noteText)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56)).lineLimit(span > 2 ? 2 : 1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, span > 1 ? 8 : 0).dockWidgetSurface()
            .dockTapTarget("Заметка") { showsEditor = true }.help("Заметка")
            .popover(isPresented: $showsEditor, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Заметка").font(.headline)
                        Spacer()
                        Text("\(preferences.noteText.count)/2000").font(.caption).foregroundStyle(.secondary)
                    }
                    TextEditor(text: Binding(get: { preferences.noteText }, set: { preferences.noteText = String($0.prefix(2000)) }))
                        .font(.system(size: 13)).focused($focused).scrollContentBackground(.hidden)
                        .padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .frame(height: 150).accessibilityLabel("Текст заметки")
                }.padding(16).frame(width: 320).preferredColorScheme(.dark)
                    .onAppear { interactionChanged(true); focused = true }
                    .onDisappear { interactionChanged(false) }
            }
    }
}

extension View {
    func dockWidgetSurface() -> some View {
        // Width changes with span; the painted surface never grows into the
        // optional application-label row or shrinks to an icon's intrinsic size.
        frame(maxWidth: .infinity)
            .frame(height: DockLayout.baseHeight)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06), lineWidth: 0.5) }
    }
}
