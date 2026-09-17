import AppKit
import NotchCore
import SwiftUI

enum NotchSettingsSection: String, CaseIterable, Identifiable {
    case general
    case launcher
    case displays
    case updates
    case limits
    case integrations
    case music
    case jira

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Основные"
        case .launcher: "Launcher"
        case .displays: "Дисплеи"
        case .updates: "Обновления"
        case .limits: "Лимиты"
        case .integrations: "Интеграции"
        case .music: "Музыка"
        case .jira: "Jira"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Поведение и оформление"
        case .launcher: "Поиск и буфер обмена"
        case .displays: "Экран и отдельные размеры"
        case .updates: "Версия и Homebrew"
        case .limits: "Источники и компактный индикатор"
        case .integrations: "GitHub, GitLab и PR/CI"
        case .music: "Источник текущего трека"
        case .jira: "Подключение и проекты"
        }
    }

    var iconName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .launcher: "magnifyingglass"
        case .displays: "display.2"
        case .updates: "arrow.triangle.2.circlepath"
        case .limits: "gauge.with.dots.needle.67percent"
        case .integrations: "point.3.connected.trianglepath.dotted"
        case .music: "waveform"
        case .jira: "checkmark.square"
        }
    }
}

struct NotchSettingsView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var settings: NotchVisualSettings
    @ObservedObject var displaySettings: NotchDisplaySettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let launcher: LauncherWindowCoordinator

    @State private var selectedSection: NotchSettingsSection
    @State private var swipeTranslation: CGFloat = 0
    @StateObject private var codeReviewIntegrations = CodeReviewIntegrationStore()
    @StateObject private var updateProvider = AppUpdateProvider()
    @AppStorage(UserDefaultsAppPreferences.cliHooksEnabledKey)
    private var cliHooksEnabled = false
    @State private var cliHooksMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var carouselAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .interpolatingSpring(stiffness: 260, damping: 32)
    }

    init(
        model: NotchViewModel,
        settings: NotchVisualSettings,
        displaySettings: NotchDisplaySettings,
        launchAtLogin: LaunchAtLoginManager,
        launcher: LauncherWindowCoordinator,
        initialSection: NotchSettingsSection = .general
    ) {
        self.model = model
        self.settings = settings
        self.displaySettings = displaySettings
        self.launchAtLogin = launchAtLogin
        self.launcher = launcher
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)

            SwipeCarousel(
                items: NotchSettingsSection.allCases,
                selection: selectedSection,
                translation: swipeTranslation,
                retainedRadius: NotchSettingsSection.allCases.count
            ) { section in
                sectionPage(section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: 520)
        .background(Color.black)
        .background {
            HorizontalSwipeMonitor(
                onChanged: updateSwipe,
                onThresholdReached: commitSwipe,
                onEnded: finishSwipe
            )
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedSection) { _, _ in launcher.settings.isRecordingShortcut = false }
        .onAppear {
            launchAtLogin.refresh()
            model.refreshAllQuotaProviders()
            model.refreshNowPlaying()
        }
    }

    private func selectSection(_ section: NotchSettingsSection) {
        guard section != selectedSection else { return }
        withAnimation(carouselAnimation) {
            swipeTranslation = 0
            selectedSection = section
        }
    }

    private func updateSwipe(_ distance: CGFloat) {
        guard reduceMotion == false else { return }
        let direction: HorizontalSwipeDirection = distance > 0 ? .next : .previous
        let resistance: CGFloat = targetSection(direction) == nil ? 0.16 : 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            swipeTranslation = -distance * resistance
        }
    }

    private func finishSwipe(_ direction: HorizontalSwipeDirection?) {
        guard let direction, let target = targetSection(direction) else {
            withAnimation(carouselAnimation) {
                swipeTranslation = 0
            }
            return
        }

        withAnimation(carouselAnimation) {
            swipeTranslation = 0
            selectedSection = target
        }
    }

    private func commitSwipe(_ direction: HorizontalSwipeDirection) -> Bool {
        guard targetSection(direction) != nil else { return false }
        NotchHaptics.selectionChanged()
        return true
    }

    private func targetSection(_ direction: HorizontalSwipeDirection) -> NotchSettingsSection? {
        let sections = NotchSettingsSection.allCases
        guard let currentIndex = sections.firstIndex(of: selectedSection) else { return nil }

        let nextIndex = direction == .next ? currentIndex + 1 : currentIndex - 1
        guard sections.indices.contains(nextIndex) else { return nil }
        return sections[nextIndex]
    }

    private func sectionPage(_ section: NotchSettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(section)

            ScrollView {
                sectionContent(section)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Color.signalMint, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 1) {
                    Text("NotchApp")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("Настройки")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.bottom, 14)

            ForEach(NotchSettingsSection.allCases) { section in
                sidebarButton(section)
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Выйти из NotchApp", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.signalCoral)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 11)
            }
            .buttonStyle(NotchButtonStyle())
        }
        .padding(16)
        .frame(width: 172)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.035))
    }

    private func sidebarButton(_ section: NotchSettingsSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            selectSection(section)
        } label: {
            Label(section.title, systemImage: section.iconName)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, 11)
                .background(
                    isSelected ? Color.white.opacity(0.11) : .clear,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pageHeader(_ section: NotchSettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(section.subtitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.44))
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func sectionContent(_ section: NotchSettingsSection) -> some View {
        switch section {
        case .general:
            generalPage
        case .launcher:
            LauncherSettingsView(settings: launcher.settings, clipboard: launcher.model.clipboard,
                                 aiChat: launcher.model.aiChat, open: launcher.show)
        case .displays:
            displaysPage
        case .updates:
            updatesPage
        case .limits:
            limitsPage
        case .integrations:
            integrationsPage
        case .music:
            musicPage
        case .jira:
            VStack(spacing: 12) {
                SettingsCard(title: "Подключение", icon: "key.horizontal") {
                    JiraConnectionSettingsView(model: model)
                }
                JiraPinnedSettingsView(model: model)
            }
        }
    }

    private var displaysPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Расположение", icon: "display.2") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Показывать Nool", selection: displayModeBinding) {
                        ForEach(NotchDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    if displaySettings.mode == .fixed {
                        Picker("Дисплей", selection: fixedDisplayBinding) {
                            ForEach(displaySettings.connectedDisplays) { display in
                                Text(display.selectionTitle).tag(display.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.signalMint)
                            .frame(width: 6, height: 6)
                        Text("Сейчас: \(displaySettings.activeDisplay?.name ?? "дисплей не определён")")
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Обновить") { displaySettings.refreshConnectedDisplays() }
                            .buttonStyle(NotchButtonStyle())
                            .foregroundStyle(Color.signalMint)
                            .frame(minHeight: 40)
                    }

                    Text(displayModeHint)
                        .settingsHintStyle()
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tint(Color.signalMint)
            }

            SettingsCard(title: "Размеры по дисплеям", icon: "arrow.up.left.and.arrow.down.right") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Отдельная высота для каждого дисплея",
                        isOn: $displaySettings.usesPerDisplayCompactHeight
                    )
                    .frame(minHeight: 40)

                    if displaySettings.usesPerDisplayCompactHeight {
                        ForEach(displaySettings.connectedDisplays) { display in
                            displayHeightRow(display)

                            if display.id != displaySettings.connectedDisplays.last?.id {
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                        }
                    } else {
                        Text("Используется общая высота из раздела «Основные».")
                            .settingsHintStyle()
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tint(Color.signalMint)
            }
        }
        .onAppear { displaySettings.refreshConnectedDisplays() }
    }

    private func displayHeightRow(_ display: NotchDisplayDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(
                        display.id == displaySettings.activeDisplayID
                            ? Color.signalMint : .white.opacity(0.42)
                    )
                    .frame(width: 18)
                Text(display.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(displayHeight(for: display).rounded())) px")
                    .foregroundStyle(Color.signalMint)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { displayHeight(for: display) },
                    set: { displaySettings.setCompactHeight($0, for: display.id) }
                ),
                in: NotchLayout.compactHeightRange,
                step: 1
            )
            .frame(minHeight: 40)
            .accessibilityLabel("Высота челки на дисплее \(display.name)")
        }
        .padding(.vertical, 3)
    }

    private var updatesPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Версия", icon: "shippingbox") {
                VStack(alignment: .leading, spacing: 10) {
                    DiagnosticRow(
                        title: "Установлена",
                        value: updateProvider.installedVersion.description,
                        showsDivider: updateProvider.state != .idle
                    )

                    updateStatusContent
                }
            }

            if case .result(let release, let availability) = updateProvider.state,
               availability == .updateAvailable {
                SettingsCard(title: "Что нового", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(release.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.88))

                        Text(release.notes)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .textSelection(.enabled)
                            .lineLimit(14)

                        Text(AppUpdateProvider.homebrewCommand)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.signalMint)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                .black.opacity(0.34),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        HStack(spacing: 8) {
                            SettingsActionButton(
                                title: "Скопировать команду",
                                icon: "doc.on.doc",
                                isAccent: true,
                                action: copyHomebrewCommand
                            )
                            SettingsActionButton(
                                title: "Открыть релиз",
                                icon: "arrow.up.right.square",
                                action: { NSWorkspace.shared.open(release.pageURL) }
                            )
                        }
                    }
                }
            }

            SettingsCard(title: "Как обновить", icon: "terminal") {
                Text("Nool не запускает установку без подтверждения. Команда обновляет Homebrew и только cask `nool-notch`; настройки и Keychain сохраняются.")
                    .settingsHintStyle()
            }
        }
        .task {
            if updateProvider.state == .idle {
                await updateProvider.check()
            }
        }
    }

    @ViewBuilder
    private var updateStatusContent: some View {
        switch updateProvider.state {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Color.signalMint)
                Text("Проверяю последний релиз…")
                    .settingsHintStyle()
            }
            .frame(minHeight: 40)
        case .result(let release, let availability):
            DiagnosticRow(
                title: "Последняя",
                value: release.version.description,
                isHealthy: availability != .updateAvailable,
                showsDivider: false
            )

            HStack(spacing: 8) {
                Image(systemName: availability == .updateAvailable
                    ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(availability == .updateAvailable
                        ? Color.signalAmber : Color.signalMint)
                Text(updateStatusText(availability))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
                Button("Проверить снова") {
                    Task { await updateProvider.check() }
                }
                .buttonStyle(NotchButtonStyle())
                .foregroundStyle(Color.signalMint)
                .frame(minHeight: 40)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        case .failed(let message):
            Text(message)
                .settingsHintStyle()
                .foregroundStyle(Color.signalAmber)
            SettingsActionButton(
                title: "Повторить проверку",
                icon: "arrow.clockwise",
                action: { Task { await updateProvider.check() } }
            )
        }
    }

    private var displayModeBinding: Binding<NotchDisplayMode> {
        Binding(
            get: { displaySettings.mode },
            set: { mode in
                if mode == .fixed, displaySettings.fixedDisplayID == nil {
                    displaySettings.fixedDisplayID = displaySettings.activeDisplayID
                        ?? displaySettings.connectedDisplays.first?.id
                }
                displaySettings.mode = mode
            }
        )
    }

    private var fixedDisplayBinding: Binding<String> {
        Binding(
            get: {
                displaySettings.fixedDisplayID
                    ?? displaySettings.activeDisplayID
                    ?? displaySettings.connectedDisplays.first?.id
                    ?? ""
            },
            set: { displaySettings.fixedDisplayID = $0 }
        )
    }

    private func displayHeight(for display: NotchDisplayDescriptor) -> CGFloat {
        displaySettings.compactHeight(for: display.id, fallback: settings.compactHeight)
    }

    private var displayModeHint: String {
        switch displaySettings.mode {
        case .automatic:
            "Nool остаётся на встроенном дисплее. Если его нет, используется экран под указателем."
        case .followPointer:
            "Свернутая челка переезжает, когда указатель переходит на другой экран. Открытая панель остаётся на месте."
        case .fixed:
            "Если выбранный дисплей отключён, Nool временно вернётся на встроенный или основной экран."
        }
    }

    private func updateStatusText(_ availability: AppUpdateAvailability) -> String {
        switch availability {
        case .updateAvailable: "Доступно обновление"
        case .upToDate: "Установлена актуальная версия"
        case .developmentBuild: "Сборка новее опубликованного релиза"
        }
    }

    private func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            AppUpdateProvider.homebrewCommand,
            forType: .string
        )
    }

    private var generalPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Поведение", icon: "cursorarrow.motionlines") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Раскрытие наведением", selection: Binding(
                        get: { model.hoverExpansionDelay },
                        set: model.setHoverExpansionDelay
                    )) {
                        Text("Выключено").tag(0.0)
                        Text("0,5 с").tag(0.5)
                        Text("1 с").tag(1.0)
                        Text("1,5 с").tag(1.5)
                    }
                    .pickerStyle(.menu)
                    Text("Короткое наведение слегка увеличивает челку. Клик всегда открывает панели сразу.")
                        .settingsHintStyle()
                }
            }

            panelConfigurationCard

            SettingsCard(title: "Оформление челки", icon: "paintbrush") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Высота компактной челки")
                            Spacer()
                            Text("\(Int(settings.compactHeight.rounded())) px")
                                .foregroundStyle(Color.signalMint)
                                .monospacedDigit()
                        }

                        HStack(spacing: 8) {
                            Text("39")
                                .foregroundStyle(.white.opacity(0.42))
                                .monospacedDigit()

                            Slider(
                                value: $settings.compactHeight,
                                in: NotchLayout.compactHeightRange,
                                step: 1
                            )
                            .frame(minHeight: 40)
                            .accessibilityLabel("Высота компактной челки")
                            .accessibilityValue("\(Int(settings.compactHeight.rounded())) пикселей")

                            Text("42")
                                .foregroundStyle(.white.opacity(0.42))
                                .monospacedDigit()
                        }
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    Toggle(
                        "Показывать маскота в открытой челке",
                        isOn: $settings.showsExpandedMascot
                    )

                    Toggle("Показывать линию", isOn: $settings.showsLine)
                    Toggle("Анимация линии", isOn: $settings.pulsesLine)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Сила свечения")
                            Spacer()
                            Text("\(Int((settings.pulseIntensity * 100).rounded()))%")
                                .foregroundStyle(.white.opacity(0.52))
                                .monospacedDigit()
                        }
                        Slider(value: $settings.pulseIntensity, in: 0...2)
                            .tint(Color.signalMint)
                    }

                    Picker("Режим цвета", selection: $settings.lineMode) {
                        ForEach(IndicatorColorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    ColorPicker(
                        "Основной цвет",
                        selection: $settings.lineColor,
                        supportsOpacity: false
                    )

                    if settings.lineMode == .gradient {
                        ColorPicker(
                            "Цвет градиента",
                            selection: $settings.lineGradientColor,
                            supportsOpacity: false
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tint(Color.signalMint)
                .animation(.easeInOut(duration: 0.18), value: settings.lineMode)
            }

            SettingsCard(title: "Система", icon: "macwindow") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Запускать при входе",
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        )
                    )
                    .frame(minHeight: 40)

                    if let statusMessage = launchAtLogin.statusMessage {
                        Text(statusMessage)
                            .settingsHintStyle()
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .tint(Color.signalMint)
            }
        }
    }

    private var panelConfigurationCard: some View {
        SettingsCard(title: "Панели", icon: "rectangle.3.group") {
            VStack(spacing: 6) {
                ForEach(model.panelOrder) { panel in
                    panelConfigurationRow(panel)
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))
                    .padding(.vertical, 4)

                Picker("При запуске", selection: startupPanelBinding) {
                    Text("Последняя открытая").tag("")
                    ForEach(model.visiblePanels) { panel in
                        Text(panel.title).tag(panel.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11, weight: .medium, design: .rounded))

                Text("Скрывайте ненужные панели и меняйте порядок стрелками. Минимум одна панель всегда остаётся.")
                    .settingsHintStyle()
            }
        }
    }

    private func panelConfigurationRow(_ panel: PanelID) -> some View {
        let isVisible = model.hiddenPanelIDs.contains(panel) == false
        let index = model.panelOrder.firstIndex(of: panel) ?? 0

        return HStack(spacing: 8) {
            Image(systemName: panel.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isVisible ? Color.signalMint : .white.opacity(0.28))
                .frame(width: 18)

            Text(panel.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isVisible ? .white.opacity(0.82) : .white.opacity(0.34))

            Spacer(minLength: 4)

            Button {
                model.movePanel(panel, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(index == model.panelOrder.startIndex)
            .accessibilityLabel("Переместить \(panel.title) выше")

            Button {
                model.movePanel(panel, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(NotchButtonStyle())
            .disabled(index == model.panelOrder.index(before: model.panelOrder.endIndex))
            .accessibilityLabel("Переместить \(panel.title) ниже")

            Toggle(
                "",
                isOn: Binding(
                    get: { model.hiddenPanelIDs.contains(panel) == false },
                    set: { model.setPanelVisible(panel, isVisible: $0) }
                )
            )
            .labelsHidden()
            .disabled(isVisible && model.canHidePanel(panel) == false)
            .accessibilityLabel("Показывать панель \(panel.title)")
        }
        .frame(minHeight: 40)
    }

    private var startupPanelBinding: Binding<String> {
        Binding(
            get: { model.startupPanel?.rawValue ?? "" },
            set: { rawValue in
                model.setStartupPanel(rawValue.isEmpty ? nil : PanelID(rawValue: rawValue))
            }
        )
    }

    private var limitsPage: some View {
        VStack(spacing: 12) {
            SettingsCard(
                title: "Панель лимитов",
                icon: "rectangle.topthird.inset.filled"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Режим")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))

                    HStack(spacing: 8) {
                        ForEach(CompactQuotaDisplayMode.allCases) { mode in
                            quotaDisplayModeButton(mode)
                        }
                    }

                    if model.compactQuotaDisplayMode == .top {
                        HStack(spacing: 10) {
                            Text("Источник справа")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))

                            Spacer()

                            Picker("", selection: compactQuotaProviderBinding) {
                                ForEach(model.visibleQuotaProviders, id: \.id) { provider in
                                    Text(provider.displayName).tag(provider.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }

                        HStack(spacing: 9) {
                            QuotaProviderBrandIcon(
                                providerID: model.compactQuotaProviderID,
                                size: 14,
                                color: .white.opacity(0.88)
                            )
                            .frame(width: 24, height: 24)
                            .background(
                                Color.signalMint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.compactQuotaProviderName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                Text("Недельный лимит")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.38))
                            }

                            Spacer()

                            Text(compactQuotaPreviewText)
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(compactQuotaPreviewColor)
                        }
                        .padding(10)
                        .background(
                            Color.black.opacity(0.34),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    } else if model.compactQuotaDisplayMode == .wave {
                        HStack(spacing: 10) {
                            Text("Сторона")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))

                            Spacer()

                            Picker("", selection: quotaPanelEdgeBinding) {
                                ForEach(QuotaPanelEdge.allCases) { edge in
                                    Text(edge.title).tag(edge)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }

                        HStack(spacing: 9) {
                            Image(systemName: model.quotaPanelEdge == .left
                                ? "sidebar.left"
                                : "sidebar.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.signalMint)
                                .frame(width: 24, height: 24)
                                .background(
                                    Color.signalMint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.quotaPanelEdge == .left
                                    ? "Панель у левого края"
                                    : "Панель у правого края")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                Text("Черная метка у края раскрывает панель. Детали появляются при наведении на кольцо")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.38))
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            Color.black.opacity(0.34),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    } else {
                        Text("Угол появления")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.46))

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)
                            ],
                            spacing: 8
                        ) {
                            ForEach(QuotaStackCorner.allCases) { corner in
                                quotaStackCornerButton(corner)
                            }
                        }

                        HStack(spacing: 9) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.signalMint)
                                .frame(width: 24, height: 24)
                                .background(
                                    Color.signalMint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.quotaStackCorner.title)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                Text("Наведите на метку в углу — лимиты раскроются каскадом")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.38))
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            Color.black.opacity(0.34),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                }
            }

            SettingsCard(title: "Провайдеры", icon: "point.3.connected.trianglepath.dotted") {
                VStack(spacing: 0) {
                    ForEach(Array(model.orderedQuotaProviders.enumerated()), id: \.element.id) { index, provider in
                        quotaProviderRow(provider, index: index)

                        if index < model.orderedQuotaProviders.count - 1 {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }

                    SettingsActionButton(
                        title: "Обновить все",
                        icon: "arrow.clockwise",
                        action: model.refreshAllQuotaProviders
                    )
                    .padding(.top, 12)
                }
            }
        }
    }

    private func quotaProviderRow(
        _ provider: any QuotaProvider,
        index: Int
    ) -> some View {
        let isVisible = model.hiddenQuotaProviderIDs.contains(provider.id) == false
        let snapshot = model.snapshot(for: provider.id)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(quotaStatusColor(snapshot?.connection))
                    .frame(width: 6, height: 6)

                QuotaProviderBrandIcon(
                    providerID: provider.id,
                    size: 13,
                    color: isVisible ? .white.opacity(0.68) : .white.opacity(0.26)
                )
                .frame(width: 17)

                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isVisible ? .white.opacity(0.84) : .white.opacity(0.34))
                    Text(snapshot?.connection.label ?? "ОЖИДАНИЕ")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(quotaStatusColor(snapshot?.connection))
                }

                Spacer(minLength: 4)

                Button {
                    model.moveQuotaProvider(provider.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up").frame(width: 34, height: 34)
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(index == 0)
                .accessibilityLabel("Переместить \(provider.displayName) выше")

                Button {
                    model.moveQuotaProvider(provider.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down").frame(width: 34, height: 34)
                }
                .buttonStyle(NotchButtonStyle())
                .disabled(index == model.orderedQuotaProviders.count - 1)
                .accessibilityLabel("Переместить \(provider.displayName) ниже")

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.hiddenQuotaProviderIDs.contains(provider.id) == false },
                        set: { model.setQuotaProviderVisible(provider.id, isVisible: $0) }
                    )
                )
                .labelsHidden()
                .disabled(isVisible && model.canHideQuotaProvider(provider.id) == false)
                .accessibilityLabel("Показывать \(provider.displayName)")
            }

            HStack(spacing: 8) {
                Text(snapshot?.message ?? "Нет данных")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if snapshot?.connection == .requiresAuthentication,
                   model.canBeginAuthentication(for: provider.id) {
                    Button("Войти") {
                        model.beginAuthentication(for: provider.id)
                    }
                    .foregroundStyle(Color.signalMint)
                    .buttonStyle(NotchButtonStyle())
                } else if let sourceURL = snapshot?.sourceURL ?? provider.sourceURL {
                    Button("Открыть") {
                        NSWorkspace.shared.open(sourceURL)
                    }
                    .foregroundStyle(Color.signalMint)
                    .buttonStyle(NotchButtonStyle())
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.leading, 31)
        }
        .padding(.vertical, 7)
    }

    private var compactQuotaProviderBinding: Binding<String> {
        Binding(
            get: { model.compactQuotaProviderID },
            set: model.setCompactQuotaProvider
        )
    }

    private var quotaPanelEdgeBinding: Binding<QuotaPanelEdge> {
        Binding(
            get: { model.quotaPanelEdge },
            set: model.setQuotaPanelEdge
        )
    }

    private func quotaDisplayModeButton(_ mode: CompactQuotaDisplayMode) -> some View {
        let isSelected = model.compactQuotaDisplayMode == mode
        return Button {
            model.setCompactQuotaDisplayMode(mode)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: quotaDisplayModeIcon(mode))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.signalMint : .white.opacity(0.58))
                    .frame(height: 20)
                Text(mode.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white.opacity(0.92) : .white.opacity(0.54))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                isSelected ? Color.signalMint.opacity(0.12) : Color.black.opacity(0.26),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.signalMint.opacity(0.42) : .white.opacity(0.06),
                        lineWidth: 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Режим лимитов: \(mode.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quotaStackCornerButton(_ corner: QuotaStackCorner) -> some View {
        let isSelected = model.quotaStackCorner == corner
        return Button {
            model.setQuotaStackCorner(corner)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: quotaStackCornerIcon(corner))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? Color.signalMint : .white.opacity(0.48))
                Text(corner.title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white.opacity(0.88) : .white.opacity(0.48))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                isSelected ? Color.signalMint.opacity(0.10) : Color.black.opacity(0.24),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? Color.signalMint.opacity(0.36) : .white.opacity(0.05),
                        lineWidth: 0.75
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(corner.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func quotaDisplayModeIcon(_ mode: CompactQuotaDisplayMode) -> String {
        switch mode {
        case .top: "rectangle.topthird.inset.filled"
        case .wave: "sidebar.right"
        case .stack: "square.stack.3d.up.fill"
        }
    }

    private func quotaStackCornerIcon(_ corner: QuotaStackCorner) -> String {
        switch corner {
        case .topLeft: "arrow.down.right"
        case .topRight: "arrow.down.left"
        case .bottomLeft: "arrow.up.right"
        case .bottomRight: "arrow.up.left"
        }
    }

    private var compactQuotaPreviewText: String {
        model.compactWeeklyRemainingRatio.map {
            "\(Int((min(max($0, 0), 1) * 100).rounded()))%"
        } ?? "--"
    }

    private var compactQuotaPreviewColor: Color {
        guard let ratio = model.compactWeeklyRemainingRatio else {
            return .white.opacity(0.34)
        }
        return ratio < 0.2 ? Color.signalCoral : Color.signalMint
    }

    private func quotaStatusColor(_ connection: ProviderConnectionState?) -> Color {
        switch connection {
        case .live:
            Color.signalMint
        case .stale, .requiresAuthentication:
            Color.signalAmber
        case .unavailable, nil:
            .white.opacity(0.28)
        }
    }

    private var musicPage: some View {
        SettingsCard(title: "Диагностика", icon: "waveform") {
            VStack(spacing: 0) {
                DiagnosticRow(
                    title: "Состояние",
                    value: healthText,
                    isHealthy: musicHealth == .active
                )
                DiagnosticRow(
                    title: "Подпись",
                    value: signingText,
                    isHealthy: hasStableSigning
                )
                DiagnosticRow(
                    title: "Источник",
                    value: model.nowPlayingDiagnostics.source.displayName,
                    isHealthy: model.nowPlayingDiagnostics.source != .unavailable
                )
                DiagnosticRow(
                    title: "Приложение",
                    value: model.nowPlayingDiagnostics.applicationName ?? "Не определено"
                )
                DiagnosticRow(
                    title: "Доступ",
                    value: accessText,
                    isHealthy: model.nowPlayingDiagnostics.requiresAccessibilityAccess == false
                )
                DiagnosticRow(
                    title: "Обновлено",
                    value: lastUpdateText,
                    showsDivider: false
                )

                HStack(spacing: 8) {
                    SettingsActionButton(
                        title: "Обновить",
                        icon: "arrow.clockwise",
                        action: model.refreshNowPlaying
                    )
                    SettingsActionButton(
                        title: "Системные настройки",
                        icon: "gearshape",
                        isAccent: model.nowPlayingDiagnostics.requiresAccessibilityAccess,
                        action: model.openAccessibilitySettings
                    )
                }
                .padding(.top, 12)
            }
        }
    }

    private var integrationsPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "CLI agents", icon: "terminal") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Разрешить approval из Nool",
                        isOn: Binding(
                            get: { cliHooksEnabled },
                            set: configureCLIHooks
                        )
                    )
                    .tint(Color.signalMint)

                    Text("Выключено по умолчанию. После включения Nool добавит только свои hook-записи Codex CLI и Claude Code; выключение удалит их, сохранив чужие настройки.")
                        .settingsHintStyle()

                    if let cliHooksMessage {
                        Text(cliHooksMessage)
                            .settingsHintStyle()
                            .foregroundStyle(cliHooksEnabled ? Color.signalMint : Color.signalAmber)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            }

            SettingsCard(title: "PR/CI", icon: "arrow.triangle.branch") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nool определяет GitHub или GitLab по remote репозитория активной или недавней AI-сессии.")
                        .settingsHintStyle()

                    ForEach(codeReviewIntegrations.statuses) { status in
                        CodeReviewIntegrationRow(
                            status: status,
                            onSetup: { host in
                                codeReviewIntegrations.beginSetup(for: status, host: host)
                            }
                        )

                        if status.id != codeReviewIntegrations.statuses.last?.id {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }

                    if codeReviewIntegrations.statuses.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.signalMint)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }

                    if let message = codeReviewIntegrations.message {
                        Text(message)
                            .settingsHintStyle()
                            .foregroundStyle(Color.signalAmber)
                    }

                    SettingsActionButton(
                        title: codeReviewIntegrations.isRefreshing ? "Проверяю…" : "Проверить снова",
                        icon: "arrow.clockwise",
                        action: refreshCodeReviewIntegrations
                    )
                    .disabled(codeReviewIntegrations.isRefreshing)
                }
            }

            SettingsCard(title: "Безопасность", icon: "lock.shield") {
                Text("Авторизацией и хранением credentials управляют gh и glab через macOS Keychain. Nool не запрашивает, не копирует и не логирует токены.")
                    .settingsHintStyle()
            }
        }
        .onAppear(perform: refreshCodeReviewIntegrations)
    }

    private func refreshCodeReviewIntegrations() {
        codeReviewIntegrations.refresh(
            workspacePaths: model.codeReviewSessions.compactMap(\.workspacePath)
        )
    }

    private func configureCLIHooks(_ isEnabled: Bool) {
        let previous = cliHooksEnabled
        do {
            if isEnabled {
                try CodexCLIHookInstaller.install()
                cliHooksMessage = "CLI hooks подключены"
            } else {
                try CodexCLIHookInstaller.uninstall()
                cliHooksMessage = "CLI hooks отключены"
            }
            cliHooksEnabled = isEnabled
        } catch {
            cliHooksEnabled = previous
            cliHooksMessage = isEnabled
                ? "Не удалось подключить CLI hooks"
                : "Не удалось отключить CLI hooks"
        }
    }

    private var musicHealth: NowPlayingHealth {
        model.nowPlayingDiagnostics.health(at: Date())
    }

    private var healthText: String {
        switch musicHealth {
        case .active:
            "Работает"
        case .playerNotFound:
            "Плеер не найден"
        case .accessibilityRequired:
            "Нужно разрешение Accessibility"
        case .stale:
            "Данные устарели"
        }
    }

    private var hasStableSigning: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NotchAppSigningMode") as? String == "stable"
    }

    private var signingText: String {
        hasStableSigning ? "Стабильная" : "Ad-hoc — доступ может сброситься"
    }

    private var delayText: String {
        String(format: "%.1f с", model.hoverExpansionDelay)
    }

    private var accessText: String {
        if model.nowPlayingDiagnostics.requiresAccessibilityAccess {
            return "Нужно разрешение"
        }
        return model.nowPlayingDiagnostics.source == .accessibility ? "Разрешён" : "Не требуется"
    }

    private var lastUpdateText: String {
        guard let date = model.nowPlayingDiagnostics.lastSuccessfulUpdate else {
            return "Нет данных"
        }
        return date.formatted(date: .omitted, time: .standard)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: String
    var isHealthy: Bool?
    var showsDivider = true

    var body: some View {
        HStack(spacing: 8) {
            if let isHealthy {
                Circle()
                    .fill(isHealthy ? Color.signalMint : Color.signalAmber)
                    .frame(width: 6, height: 6)
            }
            Text(title).foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
            }
        }
    }
}

private struct SettingsActionButton: View {
    let title: String
    let icon: String
    var isAccent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isAccent ? Color.signalMint : .white.opacity(0.78))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
        }
        .buttonStyle(NotchButtonStyle())
    }
}

private struct CodeReviewIntegrationRow: View {
    let status: CodeReviewIntegrationStatus
    let onSetup: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: status.provider == .github ? "chevron.left.forwardslash.chevron.right" : "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 28, height: 28)
                    .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(status.provider.rawValue)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                    Text(statusText)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.35)
                        .foregroundStyle(statusColor)
                }

                Spacer(minLength: 6)

                Text(status.cliName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 7)
                    .frame(minHeight: 24)
                    .background(.black.opacity(0.25), in: Capsule())
            }

            if status.isInstalled == false {
                setupButton(title: "Установить \(status.cliName)", host: nil)
            } else if status.hosts.isEmpty {
                Text("Открой AI-сессию в GitLab-репозитории — Nool сам добавит его хост из remote.")
                    .settingsHintStyle()
                    .padding(.leading, 37)
            } else {
                ForEach(status.hosts) { host in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(host.isAuthenticated ? Color.signalMint : Color.signalAmber)
                            .frame(width: 6, height: 6)
                        Text(host.host)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if host.isAuthenticated {
                            Text("Подключено")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.signalMint)
                        } else {
                            setupButton(title: "Подключить", host: host.host)
                                .frame(width: 112)
                        }
                    }
                    .padding(.leading, 37)
                    .frame(minHeight: 40)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        if status.isInstalled == false { return .signalCoral }
        if status.hosts.isEmpty || status.isReady == false { return .signalAmber }
        return .signalMint
    }

    private var statusText: String {
        if status.isInstalled == false { return "НЕ УСТАНОВЛЕН" }
        if status.hosts.isEmpty { return "ЖДЁТ РЕПОЗИТОРИЙ" }
        return status.isReady ? "ГОТОВ" : "НУЖЕН ВХОД"
    }

    private func setupButton(title: String, host: String?) -> some View {
        Button { onSetup(host) } label: {
            Label(
                title,
                systemImage: status.isInstalled ? "key.horizontal" : "arrow.down.circle"
            )
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.signalMint)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                Color.signalMint.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(NotchButtonStyle())
    }
}

private extension View {
    func settingsHintStyle() -> some View {
        font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension NowPlayingSource {
    var displayName: String {
        switch self {
        case .unavailable: "Нет данных"
        case .mediaRemote: "MediaRemote"
        case .accessibility: "Универсальный доступ"
        }
    }
}
