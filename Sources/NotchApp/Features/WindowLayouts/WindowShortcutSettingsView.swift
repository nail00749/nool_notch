import AppKit
import SwiftUI

struct WindowShortcutSettingsView: View {
    @ObservedObject var controller: WindowShortcutController
    @ObservedObject var settings: WindowShortcutSettings
    @State private var monitor: Any?
    @State private var message: String?
    @State private var recordingID = UUID()

    var body: some View {
        GroupBox("Горячие клавиши окон") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Управлять активным окном сочетаниями", isOn: $settings.enabled)
                    .font(.system(size: 12, weight: .medium))
                Text("Работают без открытия Launcher. ↑ разворачивает в рабочую область, ↓ возвращает исходное положение и размер. Для перемещения окон нужен «Универсальный доступ».")
                    .font(.caption).foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.enabled {
                    ForEach(WindowLayoutAction.allCases) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) {
                                Image(systemName: action.systemImage).frame(width: 18)
                                    .foregroundStyle(NotchPalette.secondary)
                                Text(action.title).font(.system(size: 12))
                                Spacer(minLength: 8)
                                Button(settings.recordingAction == action ? "Нажмите сочетание…" :
                                        (settings.shortcut(for: action)?.title ?? "Назначить…")) {
                                    beginRecording(action)
                                }
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .accessibilityLabel("Сочетание: \(action.title)")
                                Button {
                                    endRecording()
                                    message = settings.assign(nil, to: action, launcher: controller.launcherSettings.shortcut)
                                } label: { Image(systemName: "xmark.circle").frame(width: 24, height: 24) }
                                .buttonStyle(.plain)
                                .help("Отключить сочетание: \(action.title)")
                                .accessibilityLabel("Отключить сочетание: \(action.title)")
                                .disabled(settings.shortcut(for: action) == nil)
                            }
                            if let error = controller.errors[action.rawValue] {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if settings.recordingAction != nil {
                    Text("Нажмите клавишу с ⌘, ⌥ или ⌃. Escape — отмена.")
                        .font(.caption).foregroundStyle(NotchPalette.secondary)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
                if let status = controller.lastMessage {
                    Text(status).font(.caption).foregroundStyle(NotchPalette.secondary)
                }
                Button("Вернуть стандартные сочетания") { endRecording(); settings.reset(); message = nil }
                    .font(.caption)
            }.padding(8)
        }
        .onDisappear { endRecording() }
        .onChange(of: settings.enabled) { _, _ in endRecording() }
        .onReceive(controller.launcherSettings.$isRecordingShortcut) { recording in
            if !recording { endRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in endRecording() }
    }

    private func beginRecording(_ action: WindowLayoutAction) {
        guard settings.recordingAction == nil || monitor != nil else {
            message = "Сначала завершите запись в другом окне (Escape)."
            return
        }
        let previous = settings.recordingAction
        endRecording()
        guard previous != action else { return }
        message = nil
        guard controller.launcherSettings.beginShortcutRecording(owner: recordingID) else {
            message = "Сначала завершите запись другого сочетания (Escape)."
            return
        }
        settings.recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard settings.recordingAction == action else { return event }
            if event.keyCode == 53 { endRecording(); return nil }
            guard let shortcut = LauncherShortcut.from(event) else {
                message = "Добавьте ⌘, ⌥ или ⌃ к сочетанию."
                return nil
            }
            message = settings.assign(shortcut, to: action, launcher: controller.launcherSettings.shortcut)
            if message == nil { endRecording() }
            return nil
        }
    }

    private func endRecording() {
        let ownedRecording = monitor != nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if ownedRecording {
            settings.recordingAction = nil
            controller.launcherSettings.endShortcutRecording(owner: recordingID)
        }
    }
}
