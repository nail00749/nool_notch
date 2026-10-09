import SwiftUI
import NotchCore

struct LimitsPanel: View {
    @ObservedObject var model: NotchViewModel
    @StateObject private var codexResetForecast = CodexResetForecastProvider()
    @State private var expandedProviderID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let chatGPTProviderID = "chatgpt-subscription"

    private var shouldLoadCodexResetForecast: Bool {
        CodexResetForecastVisibility.shouldLoad(
            isExpanded: model.isExpanded,
            selectedPanel: model.selectedPanel,
            isForecastExpanded: true,
            isShowingSettings: model.isShowingSettings,
            isUtilityPresented: model.activeUtility != nil,
            isChatGPTProviderVisible: model.visibleQuotaProviders.contains {
                $0.id == chatGPTProviderID
            }
        )
    }

    var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10, alignment: .top),
                        GridItem(.flexible(), spacing: 10, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(model.visibleQuotaProviders, id: \.id) { provider in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                expandedProviderID = expandedProviderID == provider.id ? nil : provider.id
                            }
                        } label: {
                            CompactProviderQuota(
                                name: provider.id == chatGPTProviderID ? "Codex" : provider.displayName,
                                snapshot: model.snapshot(for: provider.id),
                                resetForecast: provider.id == chatGPTProviderID ? codexResetForecast : nil,
                                isExpanded: expandedProviderID == provider.id
                            )
                        }
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityHint("Показать или скрыть лимиты провайдера")
                    }
                }

                if let provider = model.visibleQuotaProviders.first(where: { $0.id == expandedProviderID }) {
                    ProviderQuotaCard(
                        providerName: provider.displayName,
                        sourceURL: provider.sourceURL,
                        snapshot: model.snapshot(for: provider.id),
                        resetForecast: provider.id == chatGPTProviderID ? codexResetForecast : nil,
                        onConnect: { model.beginAuthentication(for: provider.id) }
                    )
                }
            }
        .task(id: shouldLoadCodexResetForecast) {
            guard shouldLoadCodexResetForecast else { return }
            await codexResetForecast.refresh()
        }
    }
}

private struct CompactProviderQuota: View {
    let name: String
    let snapshot: QuotaSnapshot?
    let resetForecast: CodexResetForecastProvider?
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: name == "Codex" ? "chevron.left.forwardslash.chevron.right" : "sparkles")
                    .foregroundStyle(NotchPalette.accent)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchPalette.text)

            if let snapshot, !snapshot.windows.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(snapshot.windows) { window in
                        MiniQuotaRing(window: window)
                    }
                    Spacer(minLength: 0)
                    if let resetForecast {
                        CompactResetForecast(provider: resetForecast)
                    }
                }
            } else if let resetForecast {
                CompactResetForecast(provider: resetForecast)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(NotchPalette.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(isExpanded ? NotchPalette.accent.opacity(0.08) : NotchPalette.text.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusMessage: String? {
        switch snapshot?.connection {
        case .requiresAuthentication: "Нужен вход"
        case .stale: "Данные устарели"
        case .unavailable, .none: "Нет подключения"
        case .live: snapshot?.windows.isEmpty == true ? "Нет данных" : nil
        }
    }
}

private struct MiniQuotaRing: View {
    let window: QuotaWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var remainingLabel: String {
        if let ratio = window.remainingRatio { return "\(Int((ratio * 100).rounded()))%" }
        if let remaining = window.remaining { return formatQuotaValue(remaining) }
        return "—"
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(NotchPalette.track, lineWidth: 3)
                if let ratio = window.remainingRatio {
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(ratio < 0.2 ? Color.signalCoral : NotchPalette.accent,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(window.label == "5h" ? "5ч" : window.label)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(4)
            }
            .frame(width: 32, height: 32)
            .padding(2)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: window.remainingRatio)

            Text(remainingLabel)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchPalette.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), осталось \(remainingLabel)")
    }
}

private struct ProviderQuotaCard: View {
    let providerName: String
    let sourceURL: URL?
    let snapshot: QuotaSnapshot?
    let resetForecast: CodexResetForecastProvider?
    let onConnect: () -> Void

    private var connectionColor: Color {
        switch snapshot?.connection {
        case .live: NotchPalette.accent
        case .stale, .requiresAuthentication: .signalAmber
        case .unavailable, .none: NotchPalette.secondary
        }
    }

    private var connectionLabel: String {
        switch snapshot?.connection {
        case .live: "LIVE"
        case .stale: "STALE"
        case .unavailable: "OFFLINE"
        case .requiresAuthentication: "Нужен вход"
        case .none: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(providerName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchPalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if let snapshot {
                    HStack(spacing: 4) {
                        Circle().fill(connectionColor).frame(width: 4, height: 4)
                        Text(connectionLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(connectionColor)
                    }
                        .fixedSize()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(snapshot.connection.label)
                        .help(snapshot.connection.label)
                }
            }

            if let snapshot, !snapshot.windows.isEmpty {
                ForEach(snapshot.windows) { window in
                    HStack(spacing: 8) {
                        Text(window.label).fontWeight(.semibold)
                        if let remaining = window.remaining {
                            Text("\(formatQuotaValue(remaining)) \(window.unit == .percentage ? "% осталось" : window.unit.shortLabel)")
                                .monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        if let resetAt = window.resetAt {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                if resetAt > context.date {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.counterclockwise")
                                        Text(resetAt, style: .relative).monospacedDigit()
                                    }
                                } else {
                                    Text("Ожидаем обновление")
                                }
                            }
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.secondary)
                    .accessibilityElement(children: .combine)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text(snapshot?.message ?? "Ожидаю подключение аккаунта…")
                }
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(NotchPalette.secondary)
                .frame(minHeight: 88, alignment: .topLeading)
            }

            if let resetForecast {
                Link("Источник прогноза сбросов ↗", destination: CodexResetForecastClient.sourceURL)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchPalette.accent)
                    .help(resetForecast.errorMessage ?? "Независимый прогноз сообщества codex-reset.com")
            }

            HStack(spacing: 8) {
                Text(snapshot?.message ?? "Нет данных")
                    .lineLimit(1)
                    .help(snapshot?.message ?? "Нет данных")
                Spacer()
                if snapshot?.connection == .requiresAuthentication {
                    Button("Войти", action: onConnect)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(NotchPalette.accent)
                        .frame(minWidth: 40, minHeight: 40)
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel("Войти в \(providerName)")
                } else if let url = snapshot?.sourceURL ?? sourceURL {
                    Link("Открыть", destination: url)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                        .foregroundStyle(NotchPalette.accent)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .default))
            .foregroundStyle(NotchPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(NotchPalette.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct CompactResetForecast: View {
    @ObservedObject var provider: CodexResetForecastProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.isStale ? "Прогноз · устарел" : "Сброс · прогноз")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(provider.isStale ? Color.signalAmber : NotchPalette.secondary)
            if let forecast = provider.forecast {
                probability("24ч", value: forecast.probability24Hours)
                probability("48ч", value: forecast.probability48Hours)
            } else {
                Text(provider.isLoading ? "Загрузка…" : "Недоступен")
                    .font(.system(size: 9))
                    .foregroundStyle(NotchPalette.secondary)
            }
        }
        .frame(width: 76, alignment: .leading)
        .help(helpText)
        .accessibilityElement(children: .combine)
    }

    private func probability(_ label: String, value: Int) -> some View {
        HStack(spacing: 7) {
            Text(label).foregroundStyle(NotchPalette.secondary)
            Text("\(value)%").foregroundStyle(NotchPalette.text)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Вероятность глобального сброса за \(label): \(value) процентов")
    }

    private var helpText: String {
        guard let forecast = provider.forecast else {
            return provider.errorMessage ?? "Независимый прогноз сообщества, не персональный таймер"
        }
        let confidence: String
        switch forecast.confidence {
        case .low: confidence = "низкая"
        case .medium: confidence = "средняя"
        case .high: confidence = "высокая"
        case .unknown: confidence = "не указана"
        }
        var text = "Прогноз сообщества codex-reset.com, не персональный таймер. Уверенность: \(confidence)."
        if let lastReset = forecast.lastResetAt {
            text += " Последний сброс: \(lastReset.formatted(date: .abbreviated, time: .shortened))."
        }
        return text
    }
}


private func formatQuotaValue(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}
