import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NoolDockSettingsView: View {
    @ObservedObject var settings: NoolDockSettings
    @State private var displays: [DockDisplayChoice] = []
    @State private var pickerError: String?

    private let widgets: [NoolDockItemKind] = [.music, .calendar, .timer, .note]

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Отдельный Dock", icon: "dock.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Показывать Nool Dock", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)

                    Text("Панель с приложениями и виджетами у нижнего края экрана.")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.secondary)

                    Divider().overlay(NotchPalette.separator)

                    Toggle("Автоматически скрывать", isOn: $settings.autoHide)
                        .toggleStyle(.switch)

                    Picker("Дисплей", selection: $settings.displayID) {
                        Text("Основной дисплей").tag("")
                        ForEach(displays) { display in
                            Text(display.title).tag(display.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Дисплей Nool Dock")

                    labeledSlider("Размер", value: $settings.scale,
                                  range: 0.8...1.2,
                                  description: "\(Int(settings.scale * 100))%")
                    labeledSlider("Непрозрачность", value: $settings.opacity,
                                  range: 0.55...1,
                                  description: "\(Int(settings.opacity * 100))%")
                }
                .font(.system(size: 12))
            }

            SettingsCard(title: "Приложения", icon: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        chooseApplication()
                    } label: {
                        Label("Добавить приложение", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Добавить приложение в Nool Dock")

                    if let pickerError {
                        Text(pickerError)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    Text("Выберите .app из папки «Программы» или другого расположения.")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.secondary)
                }
            }

            SettingsCard(title: "Виджеты", icon: "rectangle.3.group") {
                VStack(spacing: 8) {
                    ForEach(widgets, id: \.self) { kind in
                        HStack(spacing: 9) {
                            Image(systemName: kind.systemImage)
                                .foregroundStyle(NotchPalette.accent)
                                .frame(width: 18)
                            Text(kind.title)
                                .font(.system(size: 12))
                            Spacer()
                            let existing = settings.items.first(where: { $0.kind == kind })
                            Button(existing == nil ? "Добавить" : "Убрать") {
                                if let existing {
                                    settings.remove(id: existing.id)
                                } else {
                                    settings.addWidget(kind)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("\(existing == nil ? "Добавить" : "Убрать") \(kind.title)")
                        }
                        if kind != widgets.last {
                            Divider().overlay(NotchPalette.separator)
                        }
                    }
                }
            }

            if !settings.items.isEmpty {
                SettingsCard(title: "Порядок и размер", icon: "line.3.horizontal.decrease") {
                    VStack(spacing: 6) {
                        ForEach(settings.items) { item in
                            itemRow(item, index: settings.items.firstIndex(where: { $0.id == item.id }) ?? 0)
                                .draggable(item.id)
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let draggedID = ids.first, draggedID != item.id else {
                                        return false
                                    }
                                    settings.move(id: draggedID, before: item.id)
                                    return true
                                }
                        }
                    }
                }
            }

            if settings.items.contains(where: { $0.kind == .note }) {
                SettingsCard(title: "Заметка", icon: "note.text") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextEditor(text: Binding(
                            get: { settings.noteText },
                            set: { settings.noteText = String($0.prefix(2_000)) }
                        ))
                        .font(.system(size: 12))
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel("Заметка Dock")
                        Text("\(settings.noteText.count)/2000")
                            .font(.system(size: 10))
                            .foregroundStyle(NotchPalette.secondary)
                    }
                }
            }
        }
        .onAppear(perform: refreshScreens)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in refreshScreens() }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(description)
                    .foregroundStyle(NotchPalette.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(NotchPalette.accent)
                .accessibilityLabel(title)
        }
    }

    private func itemRow(_ item: NoolDockItem, index: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(NotchPalette.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Image(systemName: item.kind.systemImage)
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 17)
            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Размер", selection: Binding(
                get: { item.size },
                set: { settings.setSize($0, for: item.id) }
            )) {
                Text("Компактный").tag(NoolDockItemSize.compact)
                Text("Обычный").tag(NoolDockItemSize.regular)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 92)
            .accessibilityLabel("Размер: \(item.title)")

            Button { settings.move(id: item.id, by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Переместить \(item.title) выше")

            Button { settings.move(id: item.id, by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == settings.items.count - 1)
            .accessibilityLabel("Переместить \(item.title) ниже")

            Button(role: .destructive) { settings.remove(id: item.id) } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Убрать \(item.title) из Dock")
        }
        .buttonStyle(.plain)
        .font(.system(size: 10))
        .padding(.vertical, 6)
        .padding(.horizontal, 7)
        .background(NotchPalette.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                pickerError = settings.addApplication(url)
                    ? nil : "Приложение уже добавлено или недоступно."
            }
        }
    }

    private func refreshScreens() {
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            return DockDisplayChoice(id: number.stringValue, title: screen.localizedName)
        }
    }
}

private struct DockDisplayChoice: Identifiable {
    let id: String
    let title: String
}
