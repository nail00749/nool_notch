import AppKit
import NotchCore
import SwiftUI

enum NotchSettingsSection: String, CaseIterable, Identifiable {
    case general
    case limits
    case music
    case jira

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Основные"
        case .limits: "Лимиты"
        case .music: "Музыка"
        case .jira: "Jira"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Поведение и оформление"
        case .limits: "Источники и компактный индикатор"
        case .music: "Источник текущего трека"
        case .jira: "Подключение и проекты"
        }
    }

    var iconName: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .limits: "gauge.with.dots.needle.67percent"
        case .music: "waveform"
        case .jira: "checkmark.square"
        }
    }
}

struct NotchSettingsView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var settings: NotchVisualSettings
    @ObservedObject var launchAtLogin: LaunchAtLoginManager

    @State private var selectedSection: NotchSettingsSection
    @State private var swipeTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var carouselAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .interpolatingSpring(stiffness: 260, damping: 32)
    }

    init(
        model: NotchViewModel,
        settings: NotchVisualSettings,
        launchAtLogin: LaunchAtLoginManager,
        initialSection: NotchSettingsSection = .general
    ) {
        self.model = model
        self.settings = settings
        self.launchAtLogin = launchAtLogin
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
        case .limits:
            limitsPage
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

    private var generalPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Поведение", icon: "cursorarrow.motionlines") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Задержка раскрытия")
                        Spacer()
                        Text(delayText)
                            .foregroundStyle(Color.signalMint)
                            .monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))

                    Slider(
                        value: Binding(
                            get: { model.hoverExpansionDelay },
                            set: model.setHoverExpansionDelay
                        ),
                        in: 0...1,
                        step: 0.1
                    )
                    .tint(Color.signalMint)

                    Text("Задержка применяется только к раскрытию челки наведением.")
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
                title: "Компактная челка",
                icon: "rectangle.topthird.inset.filled"
            ) {
                VStack(alignment: .leading, spacing: 10) {
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
                        Image(systemName: quotaProviderIcon(model.compactQuotaProviderID))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.signalMint)
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

                Image(systemName: quotaProviderIcon(provider.id))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isVisible ? .white.opacity(0.68) : .white.opacity(0.26))
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

    private func quotaProviderIcon(_ providerID: String) -> String {
        switch providerID {
        case "chatgpt-subscription": "bubble.left.and.text.bubble.right"
        case "claude-code-subscription": "sparkles"
        case "ollama-cloud": "cloud"
        default: "gauge.with.dots.needle.67percent"
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
