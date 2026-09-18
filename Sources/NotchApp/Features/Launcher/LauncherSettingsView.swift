import AppKit
import SwiftUI

struct LauncherSettingsView: View {
    @ObservedObject var settings: LauncherSettings
    @ObservedObject var clipboard: LauncherClipboardStore
    @ObservedObject var aiChat: AIChatStore
    let open: () -> Void
    @State private var recordingMonitor: Any?
    @State private var shortcutMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Панель поиска") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Приложения, файлы, буфер обмена и калькулятор — в одном окне.")
                        .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                    HStack {
                        Text("Горячая клавиша").font(.system(size: 12))
                        Spacer()
                        Button(settings.isRecordingShortcut ? "Нажмите сочетание…" : settings.shortcut.title) { beginRecording() }
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    if settings.isRecordingShortcut {
                        Text("Используйте ⌘, ⌥ или ⌃. Escape — отмена.").font(.caption).foregroundStyle(NotchPalette.secondary)
                    }
                    if let error = shortcutMessage ?? settings.hotKeyError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Открыть Launcher", action: open).buttonStyle(.borderedProminent).tint(NotchPalette.accent)
                        Button("Сбросить клавишу") {
                            endRecording()
                            settings.shortcut = .standard
                            shortcutMessage = nil
                        }.font(.caption)
                    }
                }.padding(8)
            }

            AIChatSettingsView(store: aiChat)

            GroupBox("Поиск файлов") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Поиск по имени через Spotlight. Доступны файлы, проиндексированные macOS.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary)
                    ForEach(settings.folderPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(NotchPalette.accent)
                            Text(abbreviate(path)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                .help(path)
                            Spacer(minLength: 0)
                            Button {
                                settings.folderPaths.removeAll { $0 == path }
                            } label: { Image(systemName: "minus.circle").frame(width: 28, height: 28) }
                                .buttonStyle(.plain).accessibilityLabel("Убрать папку \(URL(fileURLWithPath: path).lastPathComponent)")
                        }
                    }
                    if settings.folderPaths.isEmpty {
                        Text("Добавьте папку, чтобы включить поиск файлов.").font(.caption).foregroundStyle(NotchPalette.secondary)
                    }
                    Button("Добавить папку…", action: chooseFolders)
                }.padding(8)
            }

            GroupBox("История буфера обмена") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Сохранять текст и изображения", isOn: $settings.clipboardEnabled)
                        .font(.system(size: 12))
                    Text("Хранится только на этом Mac. Выключение удаляет историю. Скрытые и служебные записи не сохраняются.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary)
                    if settings.clipboardEnabled {
                        Picker("Лимит записей", selection: $settings.clipboardLimit) {
                            ForEach([50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Хранить", selection: $settings.retentionDays) {
                            Text("1 день").tag(1)
                            Text("7 дней").tag(7)
                            Text("30 дней").tag(30)
                        }
                        Text("До 5 МБ на запись, до 50 МБ всего. Enter копирует; ⌘ Enter вставляет в предыдущее приложение.")
                            .font(.caption).foregroundStyle(NotchPalette.secondary)
                    }
                    HStack {
                        Text("Записей: \(clipboard.items.count)").font(.caption).foregroundStyle(NotchPalette.secondary).monospacedDigit()
                        Spacer()
                        Button("Очистить историю") { clipboard.clear() }
                            .disabled(clipboard.items.isEmpty)
                    }
                    if let error = clipboard.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(8)
            }
        }
        .groupBoxStyle(LauncherSettingsGroupStyle())
        .onDisappear { endRecording() }
        .onChange(of: settings.isRecordingShortcut) { _, recording in
            if !recording { endRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            endRecording()
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolders() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = true
        picker.prompt = "Добавить"
        picker.message = "Выберите папки для поиска в Launcher"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { settings.addFolders(picker.urls) }
        }
        if let window = NSApp.keyWindow { picker.beginSheetModal(for: window, completionHandler: completion) }
        else { picker.begin(completionHandler: completion) }
    }

    private func beginRecording() {
        if settings.isRecordingShortcut { endRecording(); return }
        settings.isRecordingShortcut = true
        shortcutMessage = nil
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard settings.isRecordingShortcut else { return event }
                if event.keyCode == 53 { endRecording(); return nil }
                guard let shortcut = LauncherShortcut.from(event) else {
                    shortcutMessage = "Сочетание должно содержать ⌘, ⌥ или ⌃."
                    return nil
                }
                settings.shortcut = shortcut
                shortcutMessage = nil
                endRecording()
                return nil
        }
    }

    private func endRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        if settings.isRecordingShortcut { settings.isRecordingShortcut = false }
    }
}

private struct LauncherSettingsGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(NotchPalette.text.opacity(0.9))
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 14))
    }
}
