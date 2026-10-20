import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DockSettingsView: View {
    @ObservedObject var settings: DockPreferences
    var feature: DockFeatureModel? = nil
    @State private var screens: [DockScreenChoice] = []
    @State private var profileName = ""
    @State private var error: String?
    @State private var showsCatalog = false

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "NooL Dock", icon: "dock.rectangle") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Показывать NooL Dock", isOn: $settings.isEnabled).toggleStyle(.switch)
                    Toggle("Названия приложений под иконками", isOn: $settings.showAppLabels)
                        .toggleStyle(.switch)
                    Picker("Положение на экране", selection: $settings.position) {
                        ForEach(DockPosition.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Режим показа", selection: $settings.visibility) {
                        ForEach(DockVisibilityMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(settings.visibility == .intelligent
                         ? "Dock скрывается, когда окно перекрывает его область."
                         : settings.visibility == .autoHide
                            ? "Подведите курсор к \(settings.position.edgeDescription) краю экрана, чтобы показать Dock."
                         : "Dock остаётся у \(settings.position.edgeDescription) края экрана.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    Toggle("⌥⌘D включает и выключает автоскрытие", isOn: $settings.hideHotKeyEnabled)
                        .toggleStyle(.switch)
                    Picker("Дисплей", selection: $settings.displayUUID) {
                        Text("Основной дисплей").tag("")
                        ForEach(screens) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.menu)
                    labeledSlider("Размер", value: $settings.scale, range: 0.7...1.4,
                                  valueText: "\(Int(settings.scale * 100))%")
                    labeledSlider("Плотность стекла", value: $settings.opacity, range: 0.45...1,
                                  valueText: "\(Int(settings.opacity * 100))%")
                    labeledSlider("Увеличение при наведении", value: $settings.magnification, range: 0...1,
                                  valueText: settings.magnification < 0.01 ? "Выключено" : "\(Int(settings.magnification * 100))%")
                }.font(.system(size: 12))
            }
            DockBehaviorSettings(settings: settings)
            DockFullscreenSettings(settings: settings)
            if let feature { DockAccessibilitySettings(settings: settings, monitor: feature.accessibility) }
            if let feature {
                DockSystemSettings(settings: settings, systemDock: feature.systemDock, previews: feature.previews,
                                   restore: feature.restoreSystemDock)
            } else {
                SettingsCard(title: "Превью окон", icon: "macwindow.on.rectangle") {
                    Toggle("Показывать окна при наведении", isOn: $settings.previewEnabled).toggleStyle(.switch)
                }
            }
            SettingsCard(title: "Профили", icon: "rectangle.3.group") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(settings.profiles) { profile in
                        HStack {
                            Button { settings.selectProfile(profile.id) } label: {
                                Image(systemName: profile.id == settings.activeProfileID ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.plain).accessibilityLabel("Выбрать \(profile.name)")
                            TextField("Название", text: Binding(
                                get: { profile.name }, set: { settings.renameProfile(profile.id, name: $0) }
                            )).textFieldStyle(.plain)
                            Text("\(profile.elements.count)").font(.caption).foregroundStyle(.secondary)
                            Button { settings.removeProfile(profile.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).disabled(settings.profiles.count == 1).accessibilityLabel("Удалить профиль")
                        }.padding(8).background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                    HStack {
                        TextField("Новый профиль", text: $profileName).textFieldStyle(.roundedBorder)
                        Button("Создать") {
                            _ = settings.createProfile(name: profileName.isEmpty ? "Новый профиль" : profileName, duplicateCurrent: false)
                            profileName = ""
                        }
                        Button("Дублировать") {
                            _ = settings.createProfile(name: profileName.isEmpty ? "Копия профиля" : profileName, duplicateCurrent: true)
                            profileName = ""
                        }
                    }.controlSize(.small)
                }.font(.system(size: 12))
            }
            SettingsCard(title: "Состав Dock", icon: "square.grid.2x2") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button { choose(directory: false) } label: { Label("Приложение", systemImage: "plus") }
                        Button { choose(directory: true) } label: { Label("Файловый стэк", systemImage: "folder.badge.plus") }
                        Button { _ = settings.addFolder(name: "Новая папка") } label: { Label("Папка приложений", systemImage: "square.grid.2x2") }
                        if let feature {
                            Button { showsCatalog = true } label: { Label("Найти…", systemImage: "magnifyingglass") }
                                .popover(isPresented: $showsCatalog, arrowEdge: .bottom) {
                                    DockCatalogView(preferences: settings, applications: feature.applications,
                                                    interactionChanged: { _ in })
                                }
                        }
                    }.buttonStyle(.bordered).controlSize(.small)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("Перетаскивайте для смены порядка. Папки раскрываются в Dock; добавляйте в них приложения из контекстного меню.")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    ForEach(settings.items) { element in
                        itemRow(element)
                            .draggable(element.id)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, id != element.id else { return false }
                                settings.move(id: id, before: element.id)
                                return true
                            }
                    }
                }
            }
            SettingsCard(title: "Виджеты и действия", icon: "rectangle.3.group") {
                VStack(spacing: 9) {
                    ForEach(DockIntegrationRegistry.integrations, id: \.id) { integration in
                        HStack(spacing: 10) {
                            Image(systemName: integration.symbol).frame(width: 22)
                            Text(integration.title).font(.system(size: 12))
                            Spacer()
                            let existing = settings.items.first { $0.integrationID == integration.id }
                            Button(existing == nil ? "Добавить" : "Убрать") {
                                if let existing { settings.remove(id: existing.id) }
                                else { _ = settings.addIntegration(integration.id) }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            if settings.items.contains(where: { $0.integrationID == "note" }) {
                SettingsCard(title: "Заметка", icon: "note.text") {
                    TextEditor(text: Binding(get: { settings.noteText }, set: { settings.noteText = String($0.prefix(2000)) }))
                        .font(.system(size: 12)).frame(height: 90).scrollContentBackground(.hidden)
                        .padding(7).background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .onAppear(perform: refreshScreens)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in refreshScreens() }
    }

    private func itemRow(_ item: DockElement) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
            Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if item.kind == .folder { Text("\(item.children.count) приложений").foregroundStyle(.secondary) }
            if settings.supportedSpans(for: item).count > 1 {
                Picker("Ячейки", selection: Binding(get: { item.span }, set: { settings.setSpan($0, for: item.id) })) {
                    ForEach(settings.supportedSpans(for: item), id: \.self) { Text("\($0) яч.").tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 78)
            }
            Button { settings.remove(id: item.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Убрать \(item.title)")
        }.font(.system(size: 11)).padding(9)
            .background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text(valueText).foregroundStyle(NotchPalette.secondary).monospacedDigit() }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    private func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return DockScreenChoice(id: CFUUIDCreateString(nil, uuid) as String, title: screen.localizedName)
        }
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = true; panel.prompt = "Добавить"
        if !directory { panel.allowedContentTypes = [.applicationBundle] }
        panel.begin { result in
            guard result == .OK else { return }
            Task { @MainActor in
                var success = true
                for url in panel.urls { success = (directory ? settings.addStack(url) : settings.addApplication(url)) && success }
                error = success ? nil : "Некоторые элементы уже добавлены или недоступны."
            }
        }
    }
}

private struct DockScreenChoice: Identifiable { let id: String; let title: String }

/// System Dock behaviours: sections, launch feedback and Downloads presentation.
private struct DockBehaviorSettings: View {
    @ObservedObject var settings: DockPreferences

    var body: some View {
        SettingsCard(title: "Поведение", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Недавние приложения", isOn: $settings.showRecentApplications).toggleStyle(.switch)
                Text("До трёх недавно открытых приложений, которые не закреплены и уже закрыты.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                if !settings.recentApplications.isEmpty {
                    Button("Очистить список недавних", action: settings.clearRecentApplications).controlSize(.small)
                }
                Toggle("Анимировать открытие приложений", isOn: $settings.animateLaunch).toggleStyle(.switch)
                Toggle("Скрытые приложения полупрозрачные", isOn: $settings.dimHiddenApplications).toggleStyle(.switch)
                Toggle("Загрузки", isOn: $settings.showDownloads).toggleStyle(.switch)
                Picker("Вид Загрузок", selection: $settings.downloadsStyle) {
                    ForEach(DockStackStyle.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).disabled(!settings.showDownloads)
                Toggle("Корзина", isOn: $settings.showTrash).toggleStyle(.switch)
                Text("⌘-клик показывает приложение в Finder, ⌥-клик скрывает остальные. Перетащите значок за пределы Dock, чтобы убрать его.")
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            }.font(.system(size: 12))
        }
    }
}

/// Features that need Accessibility. The prompt appears only from the explicit button.
private struct DockAccessibilitySettings: View {
    @ObservedObject var settings: DockPreferences
    @ObservedObject var monitor: DockAccessibilityMonitor

    var body: some View {
        SettingsCard(title: "Универсальный доступ", icon: "accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Доступ")
                    Spacer()
                    if monitor.isTrusted {
                        Label("Разрешено", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Button("Разрешить", action: monitor.requestAccess).controlSize(.small)
                    }
                }
                Toggle("Бейджи уведомлений", isOn: $settings.showBadges).toggleStyle(.switch)
                Text("Счётчики берутся из системного Dock, который продолжает работать скрытым.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                Toggle("Свёрнутые окна в Dock", isOn: $settings.showMinimizedWindows).toggleStyle(.switch)
                Text("Свёрнутые окна появляются перед Загрузками; клик разворачивает окно. Подпрыгивание приложений, требующих внимания, macOS сторонним Dock не передаёт.")
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            }.font(.system(size: 12)).onAppear { monitor.refreshTrust() }
        }
    }
}

/// Full-screen behaviour: the edge summons the Dock like the system one, except in games,
/// playing video and applications the user excluded.
private struct DockFullscreenSettings: View {
    @ObservedObject var settings: DockPreferences

    var body: some View {
        SettingsCard(title: "Полноэкранный режим", icon: "arrow.up.left.and.arrow.down.right") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Поверх полноэкранного приложения Dock скрыт и появляется, когда указатель касается нижнего края.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                Toggle("Не показывать в играх", isOn: $settings.hideInFullscreenGames).toggleStyle(.switch)
                Toggle("Не показывать во время видео", isOn: $settings.hideInFullscreenVideo).toggleStyle(.switch)
                Text("Исключения — в этих приложениях на весь экран край не вызывает Dock.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                ForEach(settings.fullscreenExclusions, id: \.self) { identifier in
                    let app = DockExcludedApplication(bundleIdentifier: identifier)
                    HStack(spacing: 9) {
                        Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                        Text(app.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button { settings.removeFullscreenExclusion(identifier) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Убрать \(app.title)")
                    }.font(.system(size: 11)).padding(8)
                        .background(NotchPalette.surface, in: RoundedRectangle(cornerRadius: 9))
                }
                HStack {
                    Button("Добавить приложение…", action: chooseApplication)
                    Menu("Из запущенных") {
                        ForEach(runningApplications, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                                if let identifier = app.bundleIdentifier { settings.addFullscreenExclusion(identifier) }
                            }
                        }
                    }.fixedSize()
                }.controlSize(.small)
            }.font(.system(size: 12))
        }
    }

    private var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !settings.fullscreenExclusions.contains($0.bundleIdentifier ?? "") }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.begin { result in
            guard result == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    if let identifier = Bundle(url: url)?.bundleIdentifier { settings.addFullscreenExclusion(identifier) }
                }
            }
        }
    }
}

/// Display data for an excluded bundle identifier; an uninstalled app keeps its identifier.
private struct DockExcludedApplication {
    let title: String
    let icon: NSImage

    init(bundleIdentifier: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            title = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            title = bundleIdentifier
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }
}

private struct DockSystemSettings: View {
    @ObservedObject var settings: DockPreferences
    @ObservedObject var systemDock: SystemDockController
    @ObservedObject var previews: DockWindowPreviewService
    let restore: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Системный Dock", icon: "dock.rectangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Заменять системный Dock", isOn: $settings.replaceSystemDock)
                        .toggleStyle(.switch).disabled(systemDock.isBusy || !settings.isEnabled)
                    Text("Системный Dock скрывается на время работы NooL. При отключении возвращаются ваши прежние настройки.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    Button("Вернуть системный Dock", action: restore)
                        .disabled(systemDock.isBusy).controlSize(.small)
                    if systemDock.isBusy { ProgressView().controlSize(.small) }
                    if let error = systemDock.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                }.font(.system(size: 12))
            }
            SettingsCard(title: "Превью окон", icon: "macwindow.on.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Показывать окна при наведении", isOn: $settings.previewEnabled).toggleStyle(.switch)
                    permissionRow("Миниатюры окон", allowed: previews.hasCaptureAccess, action: previews.requestCaptureAccess)
                    permissionRow("Выбор окна и действия", allowed: previews.hasAccessibilityAccess, action: previews.requestAccessibilityAccess)
                    Text("Снимки загружаются только при открытом превью. Окна других приложений не сохраняются на диск.")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                }.font(.system(size: 12)).onAppear { previews.refreshPermissions() }
            }
        }
    }

    private func permissionRow(_ title: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if allowed { Label("Разрешено", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary) }
            else { Button("Разрешить", action: action).controlSize(.small) }
        }
    }
}
