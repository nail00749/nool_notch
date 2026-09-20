import SwiftUI

struct QuotaWidgetSettingsCard: View {
    var body: some View {
        SettingsCard(title: "Виджет macOS", icon: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    ForEach(["chatgpt-subscription", "claude-code-subscription", "ollama-cloud"], id: \.self) { id in
                        ZStack {
                            Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                            Circle().trim(from: 0, to: 0.75)
                                .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            QuotaProviderBrandIcon(providerID: id, size: 19, color: .white.opacity(0.85))
                        }
                        .frame(width: 42, height: 42)
                        .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                Text(QuotaWidgetPublisher.isBundled
                     ? "Нажмите правой кнопкой на рабочем столе → «Изменить виджеты» → NotchApp → «Лимиты Nool». Виджет также можно добавить в Центр уведомлений."
                     : "Эта сборка не содержит системный виджет. Для него нужна сборка Nool с WidgetKit и командной подписью Apple; ad-hoc сборки его не включают.")
                    .settingsHintStyle()
                if QuotaWidgetPublisher.isBundled {
                    Text("В меню «Изменить виджет» выберите провайдера и период: 5 часов или 7 дней. Кольцо показывает остаток. Порядок и видимость источников задаются ниже.")
                        .settingsHintStyle()
                    Text("Оставьте Nool запущенным для обновления лимитов. Через 15 минут без свежих данных или после времени сброса появится отметка устаревания. Частотой обновления виджета управляет macOS.")
                        .settingsHintStyle()
                }
            }
        }
    }
}
