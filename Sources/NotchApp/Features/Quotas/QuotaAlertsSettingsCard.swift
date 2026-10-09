import SwiftUI

struct QuotaAlertsSettingsCard: View {
    @ObservedObject var controller: QuotaAlertController
    let providers: [(id: String, name: String)]

    var body: some View {
        SettingsCard(title: "Предупреждения о лимитах", icon: "bell.badge") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Получайте уведомления при низком остатке и восстановлении лимита. Каждый порог срабатывает один раз за период.")
                    .settingsHintStyle()
                ForEach(providers, id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(provider.name, isOn: Binding(
                            get: { controller.configuration(for: provider.id).enabled },
                            set: { value in Task { await controller.enable(value, for: provider.id) } }
                        ))
                        .disabled(controller.isRequesting)
                        if controller.configuration(for: provider.id).enabled {
                            HStack(spacing: 12) {
                                Toggle("20%", isOn: option(provider.id, \.atTwenty))
                                Toggle("10%", isOn: option(provider.id, \.atTen))
                            }
                            Toggle("После восстановления", isOn: option(provider.id, \.onRecovery))
                        }
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                if controller.authorization == .denied {
                    Text("Уведомления запрещены в macOS. Разрешите их для NooL App в Системных настройках → Уведомления.")
                        .settingsHintStyle()
                }
                if let message = controller.message {
                    Text(message).settingsHintStyle()
                }
                Text("NooL App проверяет включённые источники в фоне каждые 5 минут, пока приложение запущено. Устаревшие данные не вызывают уведомлений.")
                    .settingsHintStyle()
            }
        }
        .task { await controller.refreshAuthorization() }
    }

    private func option(_ id: String, _ keyPath: WritableKeyPath<QuotaAlertOptions, Bool>) -> Binding<Bool> {
        Binding(get: { controller.configuration(for: id)[keyPath: keyPath] }, set: { value in
            var options = controller.configuration(for: id)
            options[keyPath: keyPath] = value
            controller.setOptions(options, for: id)
        })
    }
}
