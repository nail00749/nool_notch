import SwiftUI

struct DisplaySystemControlsView: View {
    @ObservedObject var model: DisplaySystemSettingsModel
    let keepAwake: DisplayKeepAwakeModel
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                appearanceControl
                control("Night Shift", symbol: "sun.haze.fill", state: model.nightShift) { await model.setNightShift($0) }
                control("True Tone", symbol: "sun.max", state: model.trueTone) { await model.setTrueTone($0) }
                DisplayKeepAwakeView(model: keepAwake, compact: true)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .disabled(isDisabled || model.isBusy)
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var appearanceControl: some View {
        Button {
            Task { await model.cycleAppearanceMode() }
        } label: {
            HStack(spacing: 6) {
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.appearanceMode == .automatic ? "circle.lefthalf.filled" :
                            model.appearanceMode == .light ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 12)).frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Тема").font(.system(size: 9, weight: .semibold))
                    Text(model.appearanceMode?.title ?? "Недоступно")
                        .font(.system(size: 8)).opacity(0.6)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(model.appearanceMode == .dark ? Color.black : Color.white)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 38)
            .background(model.appearanceMode == .dark ? Color.white : DisplayControlTheme.card,
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .disabled(isDisabled || model.isBusy || model.appearanceMode == nil)
        .help(model.appearanceUnavailableReason ?? "Светлая → Тёмная → Авто по расписанию macOS. Следующая: \(model.appearanceMode?.next.title ?? "—")")
        .accessibilityLabel("Системная тема")
        .accessibilityValue(model.appearanceMode?.title ?? "Недоступно")
        .accessibilityHint("Следующий режим: \(model.appearanceMode?.next.title ?? "—")")
    }

    private func control(_ title: String, symbol: String, state: DisplaySystemToggleState,
                         action: @escaping (Bool) async -> Void) -> some View {
        Button {
            guard let value = state.value, !isDisabled, !model.isBusy else { return }
            Task { await action(!value) }
        } label: {
            HStack(spacing: 6) {
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 12))
                        .frame(width: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 9, weight: .semibold))
                    Text(state.value.map { $0 ? "Вкл" : "Выкл" } ?? "Недоступно")
                        .font(.system(size: 8)).opacity(0.6)
                }
                .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(state.value == true ? Color.black : Color.white)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 38)
            .background(state.value == true ? Color.white : DisplayControlTheme.card,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .disabled(isDisabled || model.isBusy || state.value == nil)
        .help(state.unavailableReason ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(state.value.map { $0 ? "Включено" : "Выключено" } ?? "Недоступно")
    }
}

struct DisplayAutoBrightnessMenuItem: View {
    @ObservedObject var model: DisplaySystemSettingsModel
    let display: DisplayInfo
    var isDisabled = false

    var body: some View {
        let state = model.autoBrightness(for: display)
        Toggle("Автояркость", isOn: Binding(
            get: { model.autoBrightness(for: display).value ?? false },
            set: { value in
                guard !isDisabled, !model.isBusy else { return }
                Task { await model.setAutoBrightness(value, for: display) }
            }
        ))
        .disabled(isDisabled || model.isBusy || !display.isEnabled || state.value == nil)
        .help(state.unavailableReason ?? "Автоматическая яркость: \(display.name)")
        if let reason = state.unavailableReason, state.value == nil {
            Text(reason).font(.system(size: 10)).disabled(true)
        }
    }
}
