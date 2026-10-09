import SwiftUI

private enum NotchCustomizationTab: String, CaseIterable, Identifiable {
    case layout
    case content
    case activity
    case behavior

    var id: Self { self }
    var title: String {
        switch self {
        case .layout: "Макет"
        case .content: "Содержимое"
        case .activity: "Активность"
        case .behavior: "Поведение"
        }
    }
}

struct NotchCustomizationSettingsView: View {
    @ObservedObject var settings: NotchCustomizationSettings
    @ObservedObject var model: NotchViewModel
    @ObservedObject var modules: AppModuleStore
    @ObservedObject var displaySettings: NotchDisplaySettings
    @ObservedObject var gestureSettings: NotchGestureSettings
    @State private var selectedTab = NotchCustomizationTab.layout

    var body: some View {
        VStack(spacing: 20) {
            Picker("Настройки чёлки", selection: $selectedTab) {
                ForEach(NotchCustomizationTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Настройки чёлки")

            switch selectedTab {
            case .layout:
                layoutPage
            case .content:
                contentPage
            case .activity:
                activityPage
            case .behavior:
                behaviorPage
            }
        }
        .font(.system(size: 13))
    }

    private var layoutPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Кнопки вокруг чёлки", icon: "rectangle.inset.filled") {
                VStack(spacing: 14) {
                    layoutPreview
                    VStack(alignment: .leading, spacing: 16) {
                        quickActionColumn(.leading)
                        quickActionColumn(.trailing)
                        quickActionColumn(.bottom)
                    }
                    Text("Добавляйте действия, меняйте их расположение и порядок. Для каждого действия можно задать своё название.")
                        .settingsHintStyle()
                }
            }

            SettingsCard(title: "Размер", icon: "arrow.up.left.and.arrow.down.right") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        ForEach(NotchLayoutPreset.allCases) { preset in
                            Button { settings.apply(preset) } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: preset == .compact ? "rectangle.compress.vertical" : "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 23, weight: .medium))
                                    Text(preset.title)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity, minHeight: 88)
                                .foregroundStyle(settings.layoutPreset == preset ? Color.accentColor : Color.primary)
                                .background(settings.layoutPreset == preset ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(settings.layoutPreset == preset ? Color.accentColor : .clear, lineWidth: 1.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(settings.layoutPreset == preset ? .isSelected : [])
                        }
                    }

                    dimensionSlider(
                        title: "Ширина",
                        value: expandedWidthBinding,
                        range: NotchCustomizationSettings.expandedWidthRange,
                        unit: "px"
                    )
                    dimensionSlider(
                        title: "Максимальная высота",
                        value: maxExpandedHeightBinding,
                        range: NotchCustomizationSettings.maxExpandedHeightRange,
                        unit: "px"
                    )

                    Toggle("Показывать контур чёлки", isOn: $settings.showsOutline)
                }
            }
        }
    }

    private var layoutPreview: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                previewColumn(.leading)
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("NooL App").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.5))
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .font(.system(size: 24))
                                .frame(width: 54, height: 58)
                                .background(.black, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Твоя музыка здесь").font(.system(size: 12, weight: .semibold))
                                Text("Трек и управление воспроизведением")
                                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(settings.showsOutline ? NotchPalette.accent : .clear, lineWidth: 1.5)
                }
                previewColumn(.trailing)
            }
            previewBottomRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Предпросмотр макета чёлки")
    }

    private var previewBottomRow: some View {
        HStack(spacing: 8) {
            ForEach(settings.actions(at: .bottom)) { action in
                previewAction(action)
            }
            if settings.actions(at: .bottom).count < NotchQuickActionPlacement.bottom.capacity {
                addActionMenu(for: .bottom)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Кнопки под чёлкой")
    }

    private func previewAction(_ action: NotchQuickAction) -> some View {
        Image(systemName: action.iconName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.black, in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 1) }
            .help(action.title)
            .accessibilityLabel(action.title)
    }

    private func previewColumn(_ placement: NotchQuickActionPlacement) -> some View {
        VStack(spacing: 8) {
            ForEach(settings.actions(at: placement)) { action in
                Image(systemName: action.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.black, in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 1) }
                    .help(action.title)
                    .accessibilityLabel(action.title)
            }
            if settings.actions(at: placement).count < placement.capacity {
                addActionMenu(for: placement)
            }
        }
        .frame(width: 38)
    }

    private func quickActionColumn(_ placement: NotchQuickActionPlacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(placement.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondary)
                Spacer()
                if settings.actions(at: placement).count < placement.capacity {
                    addActionMenu(for: placement)
                }
            }

            ForEach(settings.actions(at: placement)) { action in
                quickActionRow(action, placement: placement)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickActionRow(
        _ action: NotchQuickAction,
        placement: NotchQuickActionPlacement
    ) -> some View {
        let actions = settings.actions(at: placement)
        let index = actions.firstIndex(where: { $0.id == action.id }) ?? 0
        return HStack(spacing: 6) {
            Image(systemName: action.iconName)
                .frame(width: 17)
                .foregroundStyle(NotchPalette.accent)
            TextField(action.action.title, text: Binding(
                get: { settings.quickActions.first(where: { $0.id == action.id })?.customTitle ?? "" },
                set: { settings.rename(action.action, to: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 55)
            Button {
                settings.move(action.action, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .help("Переместить выше")
            Button {
                settings.move(action.action, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == actions.count - 1)
            .help("Переместить ниже")
            Menu {
                ForEach(NotchQuickActionPlacement.allCases) { destination in
                    Button(destination.title) {
                        settings.move(action.action, to: destination)
                    }
                    .disabled(destination == placement || settings.actions(at: destination).count >= destination.capacity)
                }
                Divider()
                Button("Удалить кнопку", role: .destructive) {
                    settings.remove(action.action)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Изменить расположение или удалить")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
    }

    private func addActionMenu(for placement: NotchQuickActionPlacement) -> some View {
        Menu {
            ForEach(NotchQuickActionID.allCases.filter {
                settings.canAdd($0, at: placement)
            }) { action in
                Button(action.title, systemImage: action.iconName) {
                    settings.add(action, at: placement)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NotchPalette.accent)
                .frame(width: 34, height: 34)
                .background(.clear, in: Circle())
                .overlay {
                    Circle().strokeBorder(NotchPalette.accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                }
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .help("Добавить действие \(placement.title.lowercased())")
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Добавить кнопку \(placement.title.lowercased())")
    }

    private func dimensionSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        unit: String
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(unit)")
                    .foregroundStyle(NotchPalette.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0.rounded() }
            ), in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) \(unit)")
        }
    }

    private var contentPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Панели чёлки", icon: "rectangle.stack") {
                VStack(spacing: 4) {
                    ForEach(model.panelOrder) { panel in
                        panelRow(panel, index: model.panelOrder.firstIndex(of: panel) ?? 0)
                    }
                    Text("Скрытие здесь влияет только на чёлку. Чтобы выключить функцию и её фоновые задачи, откройте каталог модулей.")
                        .settingsHintStyle()
                        .padding(.top, 6)
                }
            }

            SettingsCard(title: "При открытии", icon: "arrow.turn.down.right") {
                Picker("Открывать", selection: startupPanelBinding) {
                    Text("Последнюю открытую панель").tag("")
                    Text("Обзор разделов").tag("overview")
                    ForEach(model.visiblePanels) { panel in
                        Text(panel.title).tag(panel.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func panelRow(_ panel: PanelID, index: Int) -> some View {
        let available = model.isPanelAvailable(panel)
        let visible = model.visiblePanels.contains(panel)
        return HStack(spacing: 8) {
            Image(systemName: panel.iconName)
                .frame(width: 18)
                .foregroundStyle(available ? NotchPalette.accent : NotchPalette.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .foregroundStyle(available ? NotchPalette.text : NotchPalette.secondary)
                if !available {
                    Text("Модуль выключен")
                        .font(.system(size: 9))
                        .foregroundStyle(NotchPalette.secondary)
                }
            }
            Spacer()
            Button {
                model.movePanel(panel, by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(index == 0)
            .help("Переместить выше")
            Button {
                model.movePanel(panel, by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(index == model.panelOrder.count - 1)
            .help("Переместить ниже")
            Toggle(panel.title, isOn: Binding(
                get: { model.isPanelAvailable(panel) && model.hiddenPanelIDs.contains(panel) == false },
                set: { model.setPanelVisible(panel, isVisible: $0) }
            ))
            .labelsHidden()
            .disabled(!available || (visible && model.visiblePanels.count <= 1))
            .accessibilityLabel("Показывать панель \(panel.title)")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(NotchPalette.separator).frame(height: 1) }
    }

    private var activityPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "В покое", icon: "moon.zzz") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Показывать в покое", selection: $settings.showsQuotaWhenIdle) {
                        Text("Ничего").tag(false)
                        Text("Лимит AI").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!settings.showsQuotaIndicator || !modules.isEnabled(.quotas))
                    Text("Индикатор лимитов появляется, когда нет музыки или активного события.")
                        .settingsHintStyle()
                }
            }

            SettingsCard(title: "Компактные индикаторы", icon: "waveform.path") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Текущая музыка", isOn: $settings.showsMusicIndicator)
                        .disabled(!modules.isEnabled(.music))
                    Toggle("Лимит AI", isOn: $settings.showsQuotaIndicator)
                        .disabled(!modules.isEnabled(.quotas))
                    Text("Индикаторы занимают место по сторонам от физической камеры и не меняют её область.")
                        .settingsHintStyle()
                }
            }
        }
    }

    private var behaviorPage: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Открытие", icon: "cursorarrow.motionlines") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Раскрывать после наведения", selection: Binding(
                        get: { model.hoverExpansionDelay },
                        set: model.setHoverExpansionDelay
                    )) {
                        Text("Только по нажатию").tag(0.0)
                        Text("Через 0,5 с").tag(0.5)
                        Text("Через 1 с").tag(1.0)
                        Text("Через 1,5 с").tag(1.5)
                    }
                    .pickerStyle(.menu)
                    Text("Нажатие по чёлке всегда открывает её сразу. Наведение можно отключить или задать задержку.")
                        .settingsHintStyle()
                }
            }

            SettingsCard(title: "Отклик и жесты", icon: "hand.draw") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Тактильный отклик", isOn: $settings.hapticsEnabled)
                    Toggle("Включить жесты на чёлке", isOn: Binding(
                        get: { modules.isEnabled(.gestures) },
                        set: { modules.setEnabled(.gestures, enabled: $0) }
                    ))
                    if modules.isEnabled(.gestures) {
                        NotchGestureSettingsView(settings: gestureSettings)
                    } else {
                        Text("Жесты меняют системную громкость и управляют воспроизведением.")
                            .settingsHintStyle()
                    }
                }
            }

            SettingsCard(title: "Дисплей", icon: "display.2") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Показывать на", selection: $displaySettings.mode) {
                        ForEach(NotchDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    if displaySettings.mode == .fixed {
                        Picker("Дисплей", selection: fixedDisplayBinding) {
                            ForEach(displaySettings.connectedDisplays) { display in
                                Text(display.selectionTitle).tag(Optional(display.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("Выбор экрана и размер окна применяются сразу.")
                        .settingsHintStyle()
                }
            }
        }
        .onAppear { displaySettings.refreshConnectedDisplays() }
    }

    private var fixedDisplayBinding: Binding<String?> {
        Binding(
            get: { displaySettings.fixedDisplayID },
            set: { displaySettings.fixedDisplayID = $0 }
        )
    }

    private var expandedWidthBinding: Binding<Double> {
        Binding(get: { settings.expandedWidth }, set: { settings.expandedWidth = $0 })
    }

    private var maxExpandedHeightBinding: Binding<Double> {
        Binding(get: { settings.maxExpandedHeight }, set: { settings.maxExpandedHeight = $0 })
    }

    private var startupPanelBinding: Binding<String> {
        Binding(
            get: { model.opensOverviewOnExpansion ? "overview" : (model.startupPanel?.rawValue ?? "") },
            set: { rawValue in
                if rawValue == "overview" {
                    model.setOverviewAsStartup()
                } else {
                    model.setStartupPanel(rawValue.isEmpty ? nil : PanelID(rawValue: rawValue))
                }
            }
        )
    }
}
