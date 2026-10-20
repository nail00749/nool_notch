import SwiftUI

struct DisplaySettingsView: View {
    @ObservedObject var model: DisplayFeatureModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Затемнение по умолчанию", systemImage: "sun.max")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Программная").font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
            }
            DisplayDimmingSlider(value: $model.defaultDimming, label: "Программная яркость по умолчанию")
            Text("Поддерживаемые экраны используют аппаратную яркость. Если она недоступна, применяется программное затемнение. Способ можно выбрать в меню «…» на карточке экрана.")
                .font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
            Toggle("Предлагать сохранённый режим при подключении", isOn: $model.restoreModesOnReconnect)
                .toggleStyle(.switch).tint(.white)
                .padding(12)
                .background(DisplayControlTheme.field, in: RoundedRectangle(cornerRadius: 12))
            Text("Режимы сохраняются для каждого дисплея после подтверждения. При подключении сохранённый режим применяется на 15 секунд: его нужно подтвердить снова.")
                .font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("После отключения").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 3) {
                    policySegment("Включать при выходе", policy: .restoreOnExit)
                    policySegment("Оставлять выключенными", policy: .keepDisabled)
                }
                .padding(3)
                .background(DisplayControlTheme.field, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("После отключения дисплея")
                Text(model.disconnectPolicy == .keepDisabled
                     ? "NooL запоминает отключённые экраны и не включает их при выходе. После запуска, сна или переподключения он снова отключает их только при работающем модуле дисплеев и наличии другого доступного экрана."
                     : "При выходе NooL включает отключённые им экраны.")
                    .font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
            }
            Text("Откройте панель «Дисплеи» в чёлке, чтобы изменить режимы и расположение, выбрать главный экран, зеркалирование или отключить дисплей.")
                .font(.system(size: 11)).foregroundStyle(DisplayControlTheme.secondary)
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(18)
        .background(DisplayControlTheme.card, in: RoundedRectangle(cornerRadius: 20))
        .environment(\.colorScheme, .dark)
        .disabled(model.isApplyingPreset || model.isPending)
    }

    private func policySegment(_ title: String, policy: DisplayDisconnectPolicy) -> some View {
        Button { model.setDisconnectPolicy(policy) } label: {
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .foregroundStyle(model.disconnectPolicy == policy ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(model.disconnectPolicy == policy ? Color.white : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityValue(model.disconnectPolicy == policy ? "Выбрано" : "Не выбрано")
    }
}
