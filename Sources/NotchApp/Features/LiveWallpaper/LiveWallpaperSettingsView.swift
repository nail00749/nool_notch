import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LiveWallpaperSettingsView: View {
    @ObservedObject var controller: LiveWallpaperController
    @State private var isDropTargeted = false
    @State private var target: LiveWallpaperTarget = .allDisplays

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Живые обои", icon: "play.rectangle") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Показывать видео на рабочем столе", isOn: preference(\.enabled))
                        .frame(minHeight: 40)
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Видео зацикливается под иконками рабочего стола на всех дисплеях и не перехватывает клики.")
                        .settingsHintStyle()
                }
            }

            if controller.displays.count > 1 { displaysCard }

            SettingsCard(title: "Библиотека", icon: "film.stack") {
                VStack(alignment: .leading, spacing: 12) {
                    if controller.displays.count > 1, !controller.items.isEmpty {
                        Label("Для: \(targetTitle)", systemImage: "scope")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NotchPalette.accent)
                    }
                    sectionTitle("Интерактивные сцены")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(LiveWallpaperItem.presets) { item in tile(item) }
                    }
                    sectionTitle("Видео и картинки")
                    if controller.fileItems.isEmpty {
                        emptyLibrary
                    } else {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(controller.fileItems) { item in tile(item) }
                        }
                    }
                    HStack(spacing: 8) {
                        Button(controller.isImporting ? "Добавляется…" : "Добавить файлы…", action: chooseVideos)
                            .buttonStyle(.bordered)
                            .disabled(controller.isImporting)
                        Button("Открыть папку", action: controller.revealFolder)
                            .buttonStyle(.bordered)
                        Button("Обновить", action: controller.reloadLibrary)
                            .buttonStyle(.plain).foregroundStyle(NotchPalette.accent)
                    }
                    .frame(minHeight: 40)
                    Text("Видео MP4, MOV, M4V и картинки JPEG, PNG, HEIC копируются в локальную папку NooL. Картинка становится сценой с параллаксом и частицами. Файлы можно перетащить сюда.")
                        .settingsHintStyle()
                }
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(NotchPalette.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .opacity(isDropTargeted ? 1 : 0)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    controller.importVideos(urls)
                    return !urls.isEmpty
                } isTargeted: { isDropTargeted = $0 }
            }

            SettingsCard(title: "Воспроизведение", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Масштаб", selection: preference(\.scaleMode)) {
                        ForEach(LiveWallpaperScaleMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    slider("Громкость", value: preference(\.volume), range: 0...1,
                           valueLabel: controller.preferences.volume == 0
                               ? "Без звука" : "\(Int(controller.preferences.volume * 100))%")
                    slider("Скорость", value: preference(\.playbackRate), range: 0.25...2,
                           valueLabel: String(format: "%.2g×", controller.preferences.playbackRate))
                }
            }

            sceneCard

            overlayCard

            SettingsCard(title: "Энергосбережение", icon: "leaf") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Пауза от батареи и в режиме энергосбережения", isOn: preference(\.pausesOnBattery))
                        .frame(minHeight: 32)
                    Toggle("Пауза, когда рабочий стол закрыт окнами", isOn: preference(\.pausesWhenCovered))
                        .frame(minHeight: 32)
                    Text("Во сне и на экране блокировки видео всегда останавливается. На паузе остаётся последний кадр.")
                        .settingsHintStyle()
                }
            }

            SettingsCard(title: "Системные обои", icon: "photo") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Ставить кадр обоев системными обоями", isOn: preference(\.syncsSystemWallpaper))
                        .frame(minHeight: 32)
                    Text("Кадр видео, картинку или снимок сцены видно на экране блокировки, в Mission Control и после выхода из NooL. Прежние обои автоматически не возвращаются — их можно выбрать в Системных настройках.")
                        .settingsHintStyle()
                }
            }

            if let message = controller.message {
                Text(message).settingsHintStyle()
                    .foregroundStyle(Color.signalCoral)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .default))
        .task { controller.reloadLibrary() }
        .onChange(of: controller.displays) { _, displays in
            if case .display(let key) = target, !displays.contains(where: { $0.key == key }) { target = .allDisplays }
        }
    }

    private var targetTitle: String {
        switch target {
        case .allDisplays: "все экраны"
        case .display(let key): controller.displays.first { $0.key == key }?.name ?? "экран"
        }
    }

    private var targetHint: String {
        switch target {
        case .allDisplays:
            "Общее видео показывают все экраны без своего выбора."
        case .display(let key):
            controller.preferences.displayFileNames[key] == nil
                ? "Экран показывает общее видео. Выберите ролик ниже, чтобы задать ему свои обои."
                : "У экрана свои обои, остальные экраны не меняются."
        }
    }

    /// One list both shows what each display plays and picks where the next chosen video goes.
    private var displaysCard: some View {
        SettingsCard(title: "Экраны", icon: "display.2") {
            VStack(alignment: .leading, spacing: 6) {
                targetRow(.allDisplays, icon: "rectangle.on.rectangle", title: "Все экраны",
                          subtitle: sharedSummary, fileName: controller.preferences.selectedFileName,
                          resetAction: resetAllAction,
                          resetHelp: "Убрать свои обои у всех экранов")
                ForEach(controller.displays) { display in
                    targetRow(.display(display.key),
                              icon: CGDisplayIsBuiltin(display.displayID) != 0 ? "laptopcomputer" : "display",
                              title: display.name,
                              subtitle: displaySummary(display),
                              fileName: controller.preferences.fileName(forDisplay: display.key),
                              resetAction: resetAction(for: display),
                              resetHelp: "Показывать общее видео")
                }
                Text(targetHint).settingsHintStyle().padding(.top, 4)
            }
        }
    }

    private func targetRow(_ rowTarget: LiveWallpaperTarget, icon: String, title: String, subtitle: String,
                           fileName: String?, resetAction: (() -> Void)?, resetHelp: String) -> some View {
        let isSelected = target == rowTarget
        return HStack(spacing: 12) {
            Button { target = rowTarget } label: {
                HStack(spacing: 12) {
                    poster(fileName, cornerRadius: 6)
                        .frame(width: 72, height: 45)
                    VStack(alignment: .leading, spacing: 2) {
                        Label(title, systemImage: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(NotchPalette.text)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchPalette.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let resetAction {
                Button(action: resetAction) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchPalette.secondary)
                .help(resetHelp)
                .accessibilityLabel(resetHelp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(NotchPalette.accent.opacity(isSelected ? 0.12 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NotchPalette.accent.opacity(isSelected ? 0.6 : 0), lineWidth: 1)
        }
    }

    private var resetAllAction: (() -> Void)? {
        guard !controller.preferences.displayFileNames.isEmpty else { return nil }
        return { controller.resetAllDisplays() }
    }

    private func resetAction(for display: LiveWallpaperDisplay) -> (() -> Void)? {
        guard controller.hasOverride(display) else { return nil }
        return { controller.resetDisplay(display.key) }
    }

    private var sharedSummary: String {
        controller.item(named: controller.preferences.selectedFileName)?.title ?? "Не выбрано"
    }

    private func displaySummary(_ display: LiveWallpaperDisplay) -> String {
        let name = controller.item(named: controller.preferences.fileName(forDisplay: display.key))?.title
        guard let name else { return "Системные обои" }
        return controller.hasOverride(display) ? "Свои · \(name)" : "Общие · \(name)"
    }

    /// The frame sizes the poster; the image fills it and is clipped, so wide clips never widen the layout.
    private func poster(_ fileName: String?, cornerRadius: CGFloat) -> some View {
        Group {
            if let preset = fileName.flatMap(LiveWallpaperScenePreset.init(key:)) {
                presetPoster(preset)
            } else {
                filePoster(fileName)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Built-in scenes have no file, so their preview is the scene's own gradient and symbol.
    private func presetPoster(_ preset: LiveWallpaperScenePreset) -> some View {
        let (top, bottom) = preset.gradient
        return LinearGradient(colors: [Color(red: top.x, green: top.y, blue: top.z),
                                       Color(red: bottom.x, green: bottom.y, blue: bottom.z)],
                              startPoint: .top, endPoint: .bottom)
            .overlay {
                Image(systemName: preset.symbolName)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .white.opacity(0.5), radius: 8)
            }
    }

    private func filePoster(_ fileName: String?) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.35))
            .overlay {
                if let fileName, let image = controller.thumbnails[fileName] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if fileName != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo").foregroundStyle(NotchPalette.secondary)
                }
            }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(NotchPalette.secondary)
            .padding(.top, 2)
    }

    private var sceneCard: some View {
        SettingsCard(title: "Сцены и картинки", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Курсор", selection: scenePreference(\.cursorMode)) {
                    ForEach(LiveWallpaperCursorMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Сила реакции", value: scenePreference(\.cursorStrength), range: 0...1,
                       valueLabel: "\(Int(controller.preferences.scene.cursorStrength * 100))%")
                    .disabled(controller.preferences.scene.cursorMode == .off)
                slider("Параллакс", value: scenePreference(\.parallax), range: 0...1,
                       valueLabel: controller.preferences.scene.parallax == 0
                           ? "Выключен" : "\(Int(controller.preferences.scene.parallax * 100))%")
                slider("Количество частиц", value: scenePreference(\.density), range: 0.25...2,
                       valueLabel: "\(Int(controller.preferences.scene.density * 100))%")
                Picker("Частицы на картинках", selection: scenePreference(\.imageParticles)) {
                    ForEach(LiveWallpaperParticleStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Частота кадров", selection: scenePreference(\.framesPerSecond)) {
                    Text("30 к/с").tag(30)
                    Text("60 к/с").tag(60)
                }
                .pickerStyle(.segmented)
                Text(controller.usesScenes
                     ? "Сцены следят за курсором без кликов: рабочий стол и иконки работают как обычно. 60 к/с плавнее, но заметнее расходует батарею."
                     : "Настройки применятся, когда на экране будет сцена или картинка из библиотеки.")
                    .settingsHintStyle()
            }
        }
    }

    private var overlayCard: some View {
        let overlay = controller.preferences.overlay
        return SettingsCard(title: "Данные на обоях", icon: "gauge.with.dots.needle.33percent") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Нагрузка на железо", isOn: overlayPreference(\.showsSystem))
                    .frame(minHeight: 32)
                HStack(spacing: 6) {
                    ForEach(SystemMonitorMetric.allCases) { metric in
                        Toggle(isOn: metricBinding(metric)) {
                            Label(metric.title, systemImage: metric.symbol)
                        }
                        .toggleStyle(.button)
                    }
                }
                .disabled(!overlay.showsSystem)
                Toggle("Лимиты AI-провайдеров", isOn: overlayPreference(\.showsQuotas))
                    .frame(minHeight: 32)
                Toggle("Сцены ускоряются и теплеют под нагрузкой CPU", isOn: overlayPreference(\.scenesReactToLoad))
                    .frame(minHeight: 32)
                Picker("Положение", selection: overlayPreference(\.position)) {
                    ForEach(LiveWallpaperOverlayPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Размер", selection: overlayPreference(\.size)) {
                    ForEach(LiveWallpaperOverlaySize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("Отступ по горизонтали", value: overlayPreference(\.horizontalInset),
                       range: LiveWallpaperOverlaySettings.insetRange,
                       valueLabel: "\(Int(overlay.horizontalInset)) pt")
                    .disabled(overlay.position == .center)
                slider("Отступ по вертикали", value: overlayPreference(\.verticalInset),
                       range: LiveWallpaperOverlaySettings.insetRange,
                       valueLabel: "\(Int(overlay.verticalInset)) pt")
                    .disabled(overlay.position == .center)
                Text("Отступы от краёв экрана помогают освободить место для Dock. В положении «По центру» не применяются.")
                    .settingsHintStyle()
                slider("Непрозрачность", value: overlayPreference(\.opacity), range: 0.3...1,
                       valueLabel: "\(Int(overlay.opacity * 100))%")
                Toggle("Только на главном экране", isOn: overlayPreference(\.mainDisplayOnly))
                    .frame(minHeight: 32)
                Text("Данные рисуются прямо в обоях под иконками рабочего стола и обновляются раз в 2 секунды, пока обои воспроизводятся. Лимиты берутся у включённых провайдеров модуля «Лимиты».")
                    .settingsHintStyle()
            }
        }
    }

    private func overlayPreference<T>(_ keyPath: WritableKeyPath<LiveWallpaperOverlaySettings, T>) -> Binding<T> {
        Binding(get: { controller.preferences.overlay[keyPath: keyPath] }, set: { value in
            var preferences = controller.preferences
            preferences.overlay[keyPath: keyPath] = value
            controller.setPreferences(preferences)
        })
    }

    private func metricBinding(_ metric: SystemMonitorMetric) -> Binding<Bool> {
        Binding(get: { controller.preferences.overlay.metrics.contains(metric) }, set: { isOn in
            var preferences = controller.preferences
            preferences.overlay.metrics.removeAll { $0 == metric }
            if isOn { preferences.overlay.metrics.append(metric) }
            controller.setPreferences(preferences)
        })
    }

    private func scenePreference<T>(_ keyPath: WritableKeyPath<LiveWallpaperSceneSettings, T>) -> Binding<T> {
        Binding(get: { controller.preferences.scene[keyPath: keyPath] }, set: { value in
            var preferences = controller.preferences
            preferences.scene[keyPath: keyPath] = value
            controller.setPreferences(preferences)
        })
    }

    private var statusText: String {
        switch controller.playbackState {
        case .playing:
            let count = controller.activeDisplays.count
            return count == controller.displays.count
                ? "Воспроизводится на всех экранах"
                : "Воспроизводится на экранах: \(count) из \(controller.displays.count)"
        case .paused(let reason): return reason.title
        case .hidden:
            if controller.items.isEmpty { return "Добавьте видео, чтобы включить живые обои." }
            else if controller.activeDisplays.isEmpty { return "Выберите обои в библиотеке." }
            else { return "Выключено" }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(NotchPalette.secondary)
            Text("Пока нет видео")
                .font(.system(size: 12, weight: .semibold))
            Text("Перетащите сюда видео или картинку")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func tile(_ item: LiveWallpaperItem) -> some View {
        let isSelected = controller.fileName(for: target) == item.fileName
        return Button { controller.assign(item, to: target) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay { poster(item.fileName, cornerRadius: 10) }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? NotchPalette.accent : NotchPalette.separator,
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if case .image = item.content {
                            Label("Сцена", systemImage: "sparkles")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white, NotchPalette.accent)
                            .padding(6)
                    }
                }
                Text(item.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? NotchPalette.text : NotchPalette.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("На все экраны") { controller.assign(item, to: .allDisplays) }
            ForEach(controller.displays.count > 1 ? controller.displays : []) { display in
                Button("Только на «\(display.name)»") { controller.assign(item, to: .display(display.key)) }
            }
            if item.url != nil {
                Button("Показать в Finder") { controller.reveal(item) }
                Divider()
                Button("Переместить в Корзину", role: .destructive) { controller.remove(item) }
            }
        }
    }

    private func chooseVideos() {
        let panel = NSOpenPanel()
        panel.title = "Выберите видео или картинки для обоев"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video") ?? .movie,
                                     .jpeg, .png, .heic]
        guard panel.runModal() == .OK else { return }
        controller.importVideos(panel.urls)
    }

    private func preference<T>(_ keyPath: WritableKeyPath<LiveWallpaperPreferences, T>) -> Binding<T> {
        Binding(get: { controller.preferences[keyPath: keyPath] }, set: { value in
            var preferences = controller.preferences
            preferences[keyPath: keyPath] = value
            controller.setPreferences(preferences)
        })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        valueLabel: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(valueLabel).foregroundStyle(NotchPalette.accent).monospacedDigit()
            }
            Slider(value: value, in: range).accessibilityLabel(title).frame(minHeight: 28)
        }
    }
}
