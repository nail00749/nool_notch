import AppKit
import SwiftUI

/// Content for the separate Dock panel. The window coordinator owns placement and scale.
struct NoolDockView: View {
    @ObservedObject var settings: NoolDockSettings
    @ObservedObject var model: NotchViewModel
    let openSettings: () -> Void
    let openLauncher: () -> Void
    let openApplication: (NoolDockItem) -> Void
    let interactionChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(settings.items) { item in
                        itemView(item)
                            .frame(width: item.baseWidth, height: 72)
                            .draggable(item.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let draggedID = ids.first, draggedID != item.id else {
                                    return false
                                }
                                settings.move(id: draggedID, before: item.id)
                                return true
                            }
                            .contextMenu {
                                Menu("Размер") {
                                    Button("Компактный") { settings.setSize(.compact, for: item.id) }
                                    Button("Обычный") { settings.setSize(.regular, for: item.id) }
                                }
                                Button("Убрать из Dock") { settings.remove(id: item.id) }
                            }
                    }
                }
                .padding(.horizontal, 1)
            }

            Rectangle()
                .fill(NotchPalette.separator)
                .frame(width: 1, height: 44)

            VStack(spacing: 2) {
                controlButton("magnifyingglass", label: "Открыть Launcher", action: openLauncher)
                controlButton("gearshape", label: "Настроить Nool Dock", action: openSettings)
            }
            .frame(width: 31)
        }
        .padding(8)
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(NotchPalette.surface.opacity(settings.opacity))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(NotchPalette.text.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 22, y: 7)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func itemView(_ item: NoolDockItem) -> some View {
        switch item.kind {
        case .app:
            NoolDockAppItem(item: item) { openApplication(item) }
        case .music:
            NoolDockMusicWidget(model: model, compact: item.size == .compact)
        case .calendar:
            NoolDockCalendarWidget(model: model, compact: item.size == .compact)
        case .timer:
            NoolDockTimerWidget(source: model.timerSource, compact: item.size == .compact)
        case .note:
            NoolDockNoteWidget(settings: settings, compact: item.size == .compact,
                               interactionChanged: interactionChanged)
        }
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(NotchPalette.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct NoolDockAppItem: View {
    let item: NoolDockItem
    let open: () -> Void
    @State private var icon: NSImage?

    var body: some View {
        Button(action: open) {
            VStack(spacing: 3) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.fill")
                            .resizable().scaledToFit()
                            .foregroundStyle(NotchPalette.accent)
                    }
                }
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)

                Text(item.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.text.opacity(0.82))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .background(NotchPalette.raised.opacity(0.62), in: RoundedRectangle(cornerRadius: 15))
        .help(item.title)
        .accessibilityLabel("Открыть \(item.title)")
        .onAppear(perform: loadIcon)
        .onChange(of: item.applicationPath) { _, _ in loadIcon() }
    }

    private func loadIcon() {
        guard let path = item.applicationPath else { icon = nil; return }
        icon = NSWorkspace.shared.icon(forFile: path)
    }
}

private struct NoolDockMusicWidget: View {
    @ObservedObject var model: NotchViewModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.nowPlayingSnapshot?.title ?? "Музыка")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(model.nowPlayingSnapshot?.artist ?? "Ничего не играет")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !compact, model.nowPlayingSnapshot != nil {
                Button(action: model.nowPlayingPreviousTrack) {
                    Image(systemName: "backward.fill")
                }
                .accessibilityLabel("Предыдущий трек")
            }

            if model.nowPlayingSnapshot != nil {
                Button(action: model.nowPlayingTogglePlayPause) {
                    Image(systemName: model.nowPlayingSnapshot?.playbackState.isPlaying == true
                          ? "pause.fill" : "play.fill")
                        .font(.system(size: 14))
                }
                .accessibilityLabel(model.nowPlayingSnapshot?.playbackState.isPlaying == true
                                    ? "Приостановить музыку" : "Воспроизвести музыку")
            } else {
                Button(action: model.refreshNowPlaying) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .accessibilityLabel("Обновить музыку")
            }

            if !compact, model.nowPlayingSnapshot != nil {
                Button(action: model.nowPlayingNextTrack) {
                    Image(systemName: "forward.fill")
                }
                .accessibilityLabel("Следующий трек")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .dockWidgetBackground()
    }
}

private struct NoolDockCalendarWidget: View {
    @ObservedObject var model: NotchViewModel
    let compact: Bool

    private func nextEvent(at date: Date) -> CalendarEvent? {
        model.dockCalendarEvents
            .filter { !$0.isAllDay && $0.endDate > date }
            .min { $0.startDate < $1.startDate }
    }

    private var emptyStatus: String {
        switch model.calendarState {
        case .idle: "Откройте календарь"
        case .loading: "Загрузка…"
        case .loaded: "Нет ближайших событий"
        case .denied: "Нет доступа к календарю"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let event = nextEvent(at: context.date)
            HStack(spacing: 9) {
                Button {
                    model.refreshCalendar()
                    model.openReminderCalendar()
                } label: {
                    VStack(spacing: 1) {
                        Text(context.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(NotchPalette.accent)
                        Text(context.date.formatted(.dateTime.day()))
                            .font(.system(size: 21, weight: .medium, design: .rounded))
                            .foregroundStyle(NotchPalette.text)
                    }
                    .frame(width: 36, height: 45)
                    .background(NotchPalette.text.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityLabel("Открыть календарь")

                VStack(alignment: .leading, spacing: 3) {
                    Text(event?.title ?? "Календарь")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(event.map { $0.startDate.formatted(date: .omitted, time: .shortened) }
                         ?? emptyStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !compact, let joinURL = event?.joinURL {
                    Button { model.openMeetingURL(joinURL) } label: {
                        Image(systemName: "video.fill")
                            .font(.system(size: 12))
                    }
                    .accessibilityLabel("Подключиться к встрече")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .dockWidgetBackground()
        }
    }
}

private struct NoolDockTimerWidget: View {
    @ObservedObject var source: NoolTimerSource
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 18))
                .foregroundStyle(NotchPalette.accent)

            if let snapshot = source.snapshot {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.countdownText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(snapshot.state == .paused ? "Пауза" :
                         snapshot.state == .completed ? "Готово" : "Таймер")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: source.toggle) {
                    Image(systemName: snapshot.state == .active ? "pause.fill" : "play.fill")
                }
                .disabled(snapshot.state == .completed)
                .accessibilityLabel(snapshot.state == .active ? "Приостановить таймер" : "Продолжить таймер")
                if !compact {
                    Button(action: source.cancel) { Image(systemName: "xmark") }
                        .accessibilityLabel("Сбросить таймер")
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Таймер").font(.system(size: 12, weight: .semibold))
                    Text("Быстрый старт").font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("5 минут") { _ = source.create(duration: 5 * 60) }
                    Button("15 минут") { _ = source.create(duration: 15 * 60) }
                    Button("25 минут") { _ = source.create(duration: 25 * 60) }
                    Button("1 час") { _ = source.create(duration: 60 * 60) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Запустить таймер")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .dockWidgetBackground()
    }
}

private struct NoolDockNoteWidget: View {
    @ObservedObject var settings: NoolDockSettings
    let compact: Bool
    let interactionChanged: (Bool) -> Void
    @State private var showsEditor = false
    @FocusState private var editorFocused: Bool

    private var note: Binding<String> {
        Binding(get: { settings.noteText }, set: { settings.noteText = String($0.prefix(2_000)) })
    }

    var body: some View {
        Button { showsEditor = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 17))
                    .foregroundStyle(NotchPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Заметка").font(.system(size: 12, weight: .semibold))
                    Text(settings.noteText.isEmpty ? "Нажмите, чтобы написать" : settings.noteText)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .dockWidgetBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Редактировать заметку Dock")
        .popover(isPresented: $showsEditor, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Заметка", systemImage: "note.text")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(settings.noteText.count)/2000")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                }
                TextEditor(text: note)
                    .font(.system(size: 12))
                    .focused($editorFocused)
                    .frame(height: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Текст заметки Dock")
            }
            .padding(14)
            .frame(width: 270)
            .background(NotchPalette.raised)
            .foregroundStyle(NotchPalette.text)
            .onAppear {
                interactionChanged(true)
                editorFocused = true
            }
            .onDisappear { interactionChanged(false) }
        }
    }
}

private extension View {
    func dockWidgetBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NotchPalette.raised.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(NotchPalette.text.opacity(0.06), lineWidth: 1)
            }
    }
}
