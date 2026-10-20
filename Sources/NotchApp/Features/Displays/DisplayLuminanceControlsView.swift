import SwiftUI

struct DisplayLuminanceControlsView: View {
    @ObservedObject var model: DisplayFeatureModel
    let display: DisplayInfo
    @ObservedObject private var systemSettings: DisplaySystemSettingsModel
    @State private var isRequesting = false

    init(model: DisplayFeatureModel, display: DisplayInfo) {
        self.model = model
        self.display = display
        systemSettings = model.systemSettings
    }

    private var isBusy: Bool {
        !display.isEnabled || model.isPending || model.isApplyingPreset || systemSettings.isBusy || isRequesting
    }

    var body: some View {
        VStack(spacing: 4) {
            chip("HDR", fullName: "HDR — расширенный динамический диапазон", state: model.hdrState(for: display)) {
                await model.requestHDR($0, for: display)
            }
            chip("Extra", fullName: "Дополнительная яркость", state: model.extraBrightnessState(for: display)) {
                await model.setExtraBrightness($0, for: display)
            }
        }
        .frame(width: 44)
    }

    private func chip(_ title: String, fullName: String, state: DisplaySystemToggleState,
                      action: @escaping (Bool) async -> Void) -> some View {
        Button {
            guard let value = state.value, !isBusy else { return }
            isRequesting = true
            Task {
                await action(!value)
                isRequesting = false
            }
        } label: {
            Text(title).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(state.value == true ? Color.black : Color.white)
                .frame(width: 44, height: 22)
                .background(state.value == true ? Color.white : DisplayControlTheme.field,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || state.value == nil)
        .help(state.unavailableReason.map { "\(fullName). \($0)" } ?? fullName)
        .accessibilityLabel("\(fullName): \(display.name)")
        .accessibilityValue(state.value.map { $0 ? "Включено" : "Выключено" } ?? "Недоступно")
    }
}
