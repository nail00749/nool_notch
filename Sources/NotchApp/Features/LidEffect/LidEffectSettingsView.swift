import SwiftUI

struct LidEffectSettingsView: View {
    @ObservedObject var controller: LidEffectController

    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Анимация крышки", icon: "laptopcomputer") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Размытие при закрытии", isOn: preference(\.enabled))
                        .frame(minHeight: 40)
                    Text("Экран плавно размывается и темнеет вслед за крышкой. При открытии эффект исчезает. Только на встроенном дисплее MacBook.")
                        .settingsHintStyle()
                    Text(controller.sensorStatus)
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(NotchPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "Настроить эффект", icon: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 12) {
                    slider("Угол начала", value: preference(\.startAngle), range: 35...110,
                           valueLabel: "\(Int(controller.preferences.startAngle))°")
                    slider("Размытие", value: preference(\.blurRadius), range: 0...40,
                           valueLabel: "\(Int(controller.preferences.blurRadius / 40 * 100))%")
                    slider("Затемнение", value: preference(\.dimming), range: 0...0.85,
                           valueLabel: "\(Int(controller.preferences.dimming * 100))%")
                    Button(controller.isPreviewing ? "Остановить предпросмотр" : "Предпросмотр · 3 секунды") {
                        if controller.isPreviewing { controller.cancelPreview() }
                        else { controller.preview() }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 40)
                    Text("Предпросмотр работает и без датчика крышки и завершится через 3 секунды.")
                        .settingsHintStyle()
                }
            }

            SettingsCard(title: "Доступ к экрану", icon: "display") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(controller.hasCapturePermission ? "Доступ разрешён" : "Требуется разрешение",
                          systemImage: controller.hasCapturePermission ? "checkmark.circle" : "lock")
                        .foregroundStyle(NotchPalette.accent)
                    Text("Для размытия рабочего стола нужен доступ «Запись экрана». Кадры обрабатываются на Mac в памяти, не сохраняются и не отправляются. Звук не захватывается.")
                        .settingsHintStyle()
                    if !controller.hasCapturePermission {
                        Button("Разрешить запись экрана", action: controller.requestCapturePermission)
                            .buttonStyle(.bordered).frame(minHeight: 40)
                    }
                    Button("Проверить доступ", action: controller.refreshPermission)
                        .buttonStyle(.plain).foregroundStyle(NotchPalette.accent).frame(minHeight: 32)
                }
            }
            if let message = controller.message {
                Text(message).settingsHintStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Совместимость зависит от датчика конкретного MacBook. Эффект не меняет настройки сна и не блокирует закрытие крышки.")
                .settingsHintStyle()
        }
        .font(.system(size: 12, weight: .medium, design: .default))
        .task { controller.refreshPermission() }
        .onDisappear { controller.cancelPreview() }
    }

    private func preference<T>(_ keyPath: WritableKeyPath<LidEffectPreferences, T>) -> Binding<T> {
        Binding(get: { controller.preferences[keyPath: keyPath] }, set: { value in
            var preferences = controller.preferences
            preferences[keyPath: keyPath] = value
            controller.setPreferences(preferences)
        })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueLabel: String) -> some View {
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
