import SwiftUI

struct DisplaysPanel: View {
    @ObservedObject var model: DisplayFeatureModel
    var isActive = true
    @State private var expandedDisplayUUIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: DisplayFeatureModel, isActive: Bool = true, initiallyExpandedUUIDs: Set<String> = []) {
        self.model = model
        self.isActive = isActive
        _expandedDisplayUUIDs = State(initialValue: initiallyExpandedUUIDs)
    }
    private var adjustingDisplay: DisplayInfo? {
        model.displays.first { $0.id == model.adjustingDisplayUUID && $0.isEnabled }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let display = adjustingDisplay {
                    DisplayImageAdjustmentView(model: model, display: display)
                } else if model.isManagingPresets {
                    DisplayPresetManagerView(model: model)
                } else if model.isArranging {
                    DisplayArrangementView(displays: model.displays, isPending: model.isPending,
                                           onApply: { placements in
                        model.requestArrangement(placements)
                    }, onClose: { model.isArranging = false })
                }
                if let message = model.errorMessage {
                    notice(message, icon: "exclamationmark.triangle.fill", color: .orange)
                }
                if model.isPending {
                    if model.rollbackFailed {
                        Button("Повторить возврат настроек", action: model.cancelChange)
                            .buttonStyle(DisplayActionStyle(prominent: true))
                    } else if !model.isApplyingPreset {
                        notice("Оставить настройки? Подтвердите на дисплее в течение 15 секунд.",
                               icon: "clock.arrow.circlepath", color: .white)
                    }
                }
                if model.displays.isEmpty && !model.isManagingPresets {
                    VStack(spacing: 14) {
                        Image(systemName: "display").font(.system(size: 32, weight: .light))
                        Text("Нет подключённых дисплеев").font(.headline)
                        Button("Обновить", action: model.refresh)
                            .buttonStyle(DisplayActionStyle(prominent: true))
                    }
                    .frame(maxWidth: .infinity).padding(28)
                    .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 22))
                }
                if !model.isArranging && !model.isManagingPresets && adjustingDisplay == nil {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(model.displays) { display in
                            DisplayControls(model: model, display: display, isExpanded: Binding(
                                get: { expandedDisplayUUIDs.contains(display.id) },
                                set: { expanded in
                                    if expanded { expandedDisplayUUIDs.insert(display.id) }
                                    else { expandedDisplayUUIDs.remove(display.id) }
                                }
                            ))
                        }
                    }
                    VStack(spacing: 8) {
                        DisplaySystemControlsView(model: model.systemSettings, keepAwake: model.keepAwake,
                                                  isDisabled: model.isPending || model.isApplyingPreset)
                        HStack(spacing: 8) {
                            footerAction("Пресеты", symbol: "square.stack") { model.isManagingPresets = true }
                                .disabled(model.isPending)
                            footerAction("Расположение", symbol: "display.2") { model.isArranging = true }
                                .disabled(model.isPending || model.displays.filter {
                                    $0.isEnabled && $0.mirrorMasterID == nil && $0.frame.width > 0 && $0.frame.height > 0
                                }.count < 2)
                                .help("Зеркальные экраны следуют за основным дисплеем.")
                            DisplayCursorCrossingButton(model: model.cursorCrossing,
                                                        isDisabled: model.isPending || model.isApplyingPreset)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: expandedDisplayUUIDs)
        }
        .disabled(model.isApplyingPreset)
        .background(.black)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            if isActive { model.refreshBrightness() }
            model.systemSettings.setVisible(isActive)
        }
        .task(id: isActive) {
            if isActive {
                await model.refreshColorProfiles()
                await model.refreshHDR()
                await model.refreshAdvancedSettings()
            }
        }
        .onDisappear { model.systemSettings.setVisible(false) }
        .onChange(of: isActive) { _, active in
            model.systemSettings.setVisible(active)
            if active { model.refreshBrightness() }
            else {
                model.isArranging = false
                model.isManagingPresets = false
                model.adjustingDisplayUUID = nil
            }
        }
        .onChange(of: model.isPending) { _, pending in
            if pending {
                model.isArranging = false
                model.adjustingDisplayUUID = nil
            }
        }
        .onChange(of: model.displays) { _, _ in
            if model.adjustingDisplayUUID != nil, adjustingDisplay == nil { model.adjustingDisplayUUID = nil }
        }
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func footerAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct DisplayControls: View {
    @ObservedObject var model: DisplayFeatureModel
    let display: DisplayInfo
    @Binding var isExpanded: Bool
    private var displaySubtitle: String {
        if !display.isEnabled { return "Выключен" }
        if model.isSafetyEnabled(for: display) { return "Включён временно" }
        return display.isMain ? "Главный дисплей" : (display.isBuiltin ? "Встроенный" : "Внешний")
    }
    private var fieldHeight: CGFloat { isExpanded ? 32 : 38 }
    private var scalingValue: String {
        if model.smoothScalingState(for: display)?.needsReconnect == true { return "Переподключите" }
        return display.currentMode?.isHiDPI == true ? "HiDPI" : "Стандартный"
    }

    private var resolutions: [DisplayModeOption] {
        var seen = Set<String>()
        return display.modes.filter { seen.insert("\($0.width)x\($0.height)").inserted }
    }

    private var currentVariants: [DisplayModeOption] {
        guard let current = display.currentMode else { return [] }
        return display.modes.filter { $0.width == current.width && $0.height == current.height }
    }

    private var frequencyVariants: [DisplayModeOption] {
        var seen = Set<Double>()
        let variants = currentVariants.filter { $0.isHiDPI == display.currentMode?.isHiDPI }
        return variants.filter { seen.insert($0.refreshRate).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if display.isEnabled {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 4) {
                        DisplayDimmingSlider(value: Binding(get: { model.dimming(for: display) },
                                                            set: { model.setDimming($0, for: display) }),
                                             label: "\(model.brightnessSourceLabel(for: display)): \(display.name)", vertical: true,
                                             source: model.isHardwareBrightness(for: display) ? "Экран" : "Софт",
                                             verticalTrackHeight: isExpanded ? 84 : 88)
                            .frame(height: isExpanded ? 120 : 124, alignment: .top)
                            .disabled(model.isPending || model.isApplyingPreset)
                            .help(model.brightnessSourceLabel(for: display))
                        if isExpanded { DisplayLuminanceControlsView(model: model, display: display) }
                    }
                    .frame(width: 44, alignment: .top)
                    VStack(spacing: isExpanded ? 2 : 4) {
                        resolutionMenu
                        frequencyMenu
                        if isExpanded {
                            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                            hiDPIMenu
                            colorProfileMenu
                            if model.referencePresetState(for: display)?.options.isEmpty == false {
                                referencePresetMenu
                            }
                        }
                    }
                    .disabled(model.isPending || model.isApplyingPreset)
                    .opacity(model.isPending || model.isApplyingPreset ? 0.5 : 1)
                }
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "Свернуть" : "Подробнее")
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DisplayControlTheme.secondary)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Дополнительные настройки: \(display.name)")
                .accessibilityValue(isExpanded ? "Развёрнуты" : "Свёрнуты")
            } else {
                Text("Дисплей выключен").font(.system(size: 10))
                    .foregroundStyle(DisplayControlTheme.secondary)
                Button { model.setDisplayEnabled(true, for: display) } label: {
                    Label("Включить", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DisplayActionStyle(prominent: true))
                .disabled(model.isPending || !model.canTogglePower(for: display))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .font(.system(size: 18, weight: .light))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(display.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .help(display.name)
                Text(displaySubtitle)
                    .font(.system(size: 9)).foregroundStyle(DisplayControlTheme.secondary).lineLimit(1)
                    .help(model.isSafetyEnabled(for: display)
                          ? "Экран временно включён, чтобы рабочий стол не остался без доступного дисплея. Выберите «Оставить включённым», чтобы отменить сохранённое отключение."
                          : displaySubtitle)
            }
            Spacer(minLength: 4)
            if display.isEnabled { arrangementControls }
        }
    }

    private var resolutionMenu: some View {
        Menu {
            ForEach(resolutions) { resolution in
                Button {
                    let variants = display.modes.filter { $0.width == resolution.width && $0.height == resolution.height }
                    let preferred = variants.first {
                        $0.isHiDPI == display.currentMode?.isHiDPI && $0.refreshRate == display.currentMode?.refreshRate
                    } ?? variants.first { $0.isHiDPI == display.currentMode?.isHiDPI } ?? resolution
                    select(preferred)
                } label: {
                    if resolution.width == display.currentMode?.width && resolution.height == display.currentMode?.height {
                        Label("\(resolution.width) × \(resolution.height)", systemImage: "checkmark")
                    } else { Text("\(resolution.width) × \(resolution.height)") }
                }
            }
        } label: {
            DisplayMenuField(title: "Разрешение", value: display.currentMode.map { "\($0.width) × \($0.height)" } ?? "Выбрать",
                             icon: "arrow.up.left.and.arrow.down.right", compact: true, compactHeight: fieldHeight)
        }
        .displayMenuStyle()
        .disabled(display.modes.isEmpty)
    }

    private var frequencyMenu: some View {
        Menu {
            ForEach(frequencyVariants) { mode in
                Button { select(mode) } label: {
                    if mode.refreshRate == display.currentMode?.refreshRate {
                        Label(rateLabel(mode.refreshRate), systemImage: "checkmark")
                    } else { Text(rateLabel(mode.refreshRate)) }
                }
            }
        } label: {
            DisplayMenuField(title: "Частота", value: display.currentMode.map { rateLabel($0.refreshRate) } ?? "—", icon: "waveform.path", compact: true, compactHeight: fieldHeight)
        }
        .displayMenuStyle()
        .disabled(frequencyVariants.isEmpty)
    }

    private var hiDPIMenu: some View {
        Menu {
            ForEach([true, false], id: \.self) { hiDPI in
                let variants = currentVariants.filter { $0.isHiDPI == hiDPI }
                if let mode = variants.first(where: { $0.refreshRate == display.currentMode?.refreshRate }) ?? variants.first {
                    Button { select(mode) } label: {
                        if hiDPI == display.currentMode?.isHiDPI {
                            Label(hiDPI ? "HiDPI" : "Стандартное", systemImage: "checkmark")
                        } else { Text(hiDPI ? "HiDPI" : "Стандартное") }
                    }
                }
            }
            if let scaling = model.smoothScalingState(for: display) {
                Divider()
                Button(scaling.isEnabled ? "Выключить Smooth Scaling…" : "Включить Smooth Scaling…") {
                    Task { await model.setSmoothScaling(!scaling.isEnabled, for: display) }
                }
                .disabled(!scaling.canModify || model.isAdvancedSettingsLoading(for: display))
                if scaling.canModify { Text("Потребуется пароль администратора").disabled(true) }
                if let detail = scaling.detail, !detail.isEmpty { Text(detail).disabled(true) }
            }
        } label: {
            DisplayMenuField(title: "Масштаб", value: scalingValue, icon: "textformat.size", compact: true, compactHeight: fieldHeight)
        }
        .displayMenuStyle()
        .disabled(currentVariants.isEmpty && model.smoothScalingState(for: display) == nil)
        .help(model.advancedSettingsError(for: display) ?? model.smoothScalingState(for: display)?.detail ?? "Масштаб изображения")
    }

    private var referencePresetMenu: some View {
        let state = model.referencePresetState(for: display)
        return Menu {
            ForEach(state?.options ?? [], id: \.id) { preset in
                Button {
                    Task { await model.selectReferencePreset(preset.id, for: display) }
                } label: {
                    if preset.id == state?.selectedID { Label(preset.name, systemImage: "checkmark") }
                    else { Text(preset.name) }
                }
            }
        } label: {
            DisplayMenuField(title: "Пресет Apple",
                             value: state?.options.first(where: { $0.id == state?.selectedID })?.name ?? "Выбрать",
                             icon: "display", compact: true, compactHeight: fieldHeight)
        }
        .displayMenuStyle()
        .disabled(!display.isEnabled || model.isPending || model.isApplyingPreset || model.isAdvancedSettingsLoading(for: display))
        .help(model.advancedSettingsError(for: display) ??
              state?.options.first(where: { $0.id == state?.selectedID })?.name ?? "Режимы дисплея Apple")
    }

    private var arrangementControls: some View {
        Menu {
            Button {
                model.adjustingDisplayUUID = display.id
            } label: {
                Label("Коррекция изображения", systemImage: "slider.horizontal.3")
            }
            DisplayAutoBrightnessMenuItem(model: model.systemSettings, display: display,
                                          isDisabled: model.isPending || model.isApplyingPreset)
            Divider()
            Text(model.brightnessSourceLabel(for: display))
            if model.hasHardwareBrightness(for: display) {
                Button {
                    model.useSoftwareBrightness(false, for: display)
                } label: {
                    if model.isHardwareBrightness(for: display) {
                        Label("Аппаратная яркость", systemImage: "checkmark")
                    } else { Text("Аппаратная яркость") }
                }
                Button {
                    model.useSoftwareBrightness(true, for: display)
                } label: {
                    if !model.isHardwareBrightness(for: display) {
                        Label("Программное затемнение", systemImage: "checkmark")
                    } else { Text("Программное затемнение") }
                }
            }
            if model.displays.count > 1 { Divider() }
            if !display.isMain, model.displays.filter(\.isEnabled).count > 1 {
                Button {
                    model.request(.main(displayID: display.displayID), display: display)
                } label: {
                    Label("Сделать главным", systemImage: "display")
                }
                .disabled(display.mirrorMasterID != nil)
            }
            if model.displays.count > 1 { Menu {
                if display.mirrorMasterID != nil {
                    Button("Выключить зеркалирование") {
                        model.request(.mirror(displayID: display.displayID, masterID: nil), display: display)
                    }
                }
                ForEach(model.displays.filter { $0.isEnabled && $0.id != display.id && $0.mirrorMasterID == nil }) { master in
                    Button("Повторять «\(master.name)»") {
                        model.request(.mirror(displayID: display.displayID, masterID: master.displayID), display: display)
                    }
                }
            } label: { Label("Зеркалирование", systemImage: "rectangle.on.rectangle") } }
            Divider()
            if display.isEnabled && model.isKeptDisconnected(for: display) {
                Button { model.keepDisplayEnabled(display) } label: {
                    Label("Оставить включённым", systemImage: "checkmark.circle")
                }
            }
            Button { model.setDisplayEnabled(false, for: display) } label: {
                Label("Выключить дисплей", systemImage: "power")
            }
            .disabled(!model.canTogglePower(for: display))
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 28, height: 32).contentShape(Rectangle())
        }
        .displayMenuStyle()
        .accessibilityLabel("Действия: \(display.name)")
        .disabled(model.isPending)
    }

    private var colorProfileMenu: some View {
        Menu {
            ForEach(model.colorProfileOptions(for: display)) { profile in
                Button {
                    Task { await model.selectColorProfile(profile.id, for: display) }
                } label: {
                    if profile.id == model.currentColorProfileID(for: display) {
                        Label(profile.name, systemImage: "checkmark")
                    } else { Text(profile.name) }
                }
            }
        } label: {
            DisplayMenuField(title: "Цветовой профиль",
                             value: model.isColorProfileLoading(for: display) ? "Загрузка…" : model.colorProfileName(for: display),
                             icon: "circle.lefthalf.filled", compact: true, compactHeight: fieldHeight)
        }
        .displayMenuStyle()
        .disabled(!display.isEnabled || model.isPending || model.isApplyingPreset ||
                  model.isColorProfileLoading(for: display) || model.colorProfileOptions(for: display).isEmpty)
    }

    private func select(_ mode: DisplayModeOption) {
        guard mode.id != display.currentMode?.id else { return }
        model.request(.mode(displayID: display.displayID, modeID: mode.id), display: display)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate > 0 ? "\(rate.formatted(.number.precision(.fractionLength(0...2)))) Гц" : "Авто"
    }
}
