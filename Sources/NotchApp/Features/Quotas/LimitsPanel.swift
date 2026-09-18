import SwiftUI
import NotchCore

struct LimitsPanel: View {
    @ObservedObject var model: NotchViewModel
    @StateObject private var codexResetForecast = CodexResetForecastProvider()
    @State private var showsResetForecast = false

    private let chatGPTProviderID = "chatgpt-subscription"

    private var shouldLoadCodexResetForecast: Bool {
        CodexResetForecastVisibility.shouldLoad(
            isExpanded: model.isExpanded,
            selectedPanel: model.selectedPanel,
            selectedAISection: model.selectedAISection,
            isShowingSettings: model.isShowingSettings,
            isUtilityPresented: model.activeUtility != nil,
            isChatGPTProviderVisible: model.visibleQuotaProviders.contains {
                $0.id == chatGPTProviderID
            }
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 24, alignment: .top),
                        GridItem(.flexible(), spacing: 24, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(Array(model.visibleQuotaProviders.enumerated()), id: \.element.id) { index, provider in
                        ProviderQuotaCard(
                            providerName: provider.displayName,
                            sourceURL: provider.sourceURL,
                            snapshot: model.snapshot(for: provider.id),
                            onConnect: { model.beginAuthentication(for: provider.id) }
                        )
                        .overlay(alignment: .leading) {
                            if index.isMultiple(of: 2) == false {
                                Rectangle().fill(NotchPalette.separator)
                                    .frame(width: 1)
                                    .offset(x: -12)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }

                if model.visibleQuotaProviders.contains(where: { $0.id == chatGPTProviderID }) {
                    DisclosureGroup(isExpanded: $showsResetForecast) {
                        CodexResetForecastView(provider: codexResetForecast)
                            .padding(.top, 8)
                    } label: {
                        Label("Прогноз глобального reset", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotchPalette.secondary)
                    }
                    .tint(NotchPalette.accent)
                    .padding(.top, 12)
                    .overlay(alignment: .top) {
                        Rectangle().fill(NotchPalette.separator).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .task(id: shouldLoadCodexResetForecast) {
            guard shouldLoadCodexResetForecast else { return }
            await codexResetForecast.refresh()
        }
    }
}

private struct ProviderQuotaCard: View {
    let providerName: String
    let sourceURL: URL?
    let snapshot: QuotaSnapshot?
    let onConnect: () -> Void

    private var primaryWindow: QuotaWindow? {
        snapshot?.windows.first
    }

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

            if let snapshot, snapshot.windows.isEmpty == false {
                HStack(alignment: .center, spacing: 12) {
                    if let primaryWindow {
                        QuotaSummaryRing(window: primaryWindow)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(snapshot.windows) { window in
                            QuotaWindowRow(window: window)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text(snapshot?.message ?? "Ожидаю подключение аккаунта…")
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)
                .frame(minHeight: 88, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Text(snapshot?.message ?? "Нет данных")
                    .lineLimit(1)
                    .help(snapshot?.message ?? "Нет данных")
                Spacer()
                if snapshot?.connection == .requiresAuthentication {
                    Button("Войти", action: onConnect)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchPalette.accent)
                        .frame(minWidth: 40, minHeight: 40)
                        .buttonStyle(NotchButtonStyle())
                        .accessibilityLabel("Войти в \(providerName)")
                } else if let url = snapshot?.sourceURL ?? sourceURL {
                    Link("Открыть", destination: url)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchPalette.accent)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(NotchPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct QuotaSummaryRing: View {
    let window: QuotaWindow

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(NotchPalette.track, lineWidth: 7)
                if let ratio = window.remainingRatio {
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(
                            ratio < 0.2 ? Color.signalCoral : NotchPalette.accent,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NotchPalette.text)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                        .padding(8)
                } else {
                    Text("—")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(NotchPalette.secondary)
                }
            }
            .padding(4)
            .frame(width: 82, height: 82)

            Text(window.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(NotchPalette.secondary)
                .lineLimit(1)
        }
        // The adjacent row contains the exact value, unit and reset time.
        .accessibilityHidden(true)
    }
}

private struct CodexResetForecastView: View {
    @ObservedObject var provider: CodexResetForecastProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .foregroundStyle(NotchPalette.accent)

                Text("Глобальный reset")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchPalette.text.opacity(0.85))

                Spacer(minLength: 4)

                if provider.isStale {
                    Text("STALE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(Color.signalAmber)
                }

                Link(destination: CodexResetForecastClient.sourceURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotchPalette.accent)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Открыть независимый источник codex-reset.com")
                .accessibilityLabel("Открыть источник прогноза Codex reset")
            }

            if let forecast = provider.forecast {
                Text("Прогноз сообщества, не персональный таймер")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(NotchPalette.secondary)

                HStack(spacing: 6) {
                    ForecastProbability(
                        label: "в 24 часа",
                        value: forecast.probability24Hours
                    )
                    ForecastProbability(
                        label: "в 48 часов",
                        value: forecast.probability48Hours
                    )
                }

                HStack(spacing: 5) {
                    if let lastResetAt = forecast.lastResetAt {
                        Image(systemName: "arrow.counterclockwise")
                        Text("последний")
                        Text(lastResetAt, style: .relative)
                    }

                    Spacer(minLength: 4)

                    Text(confidenceLabel(forecast.confidence))
                }
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)
                .lineLimit(1)

                if provider.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(NotchPalette.accent)
                        .accessibilityLabel("Обновление прогноза Codex reset")
                }
            } else if provider.isLoading {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(NotchPalette.accent)
                    Text("Проверяю прогноз сообщества…")
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)
            } else {
                HStack(spacing: 7) {
                    Text(provider.errorMessage ?? "Прогноз пока не загружен")
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button {
                        Task { await provider.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(NotchButtonStyle())
                    .foregroundStyle(NotchPalette.accent)
                    .accessibilityLabel("Повторить загрузку прогноза Codex reset")
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)
            }
        }
    }

    private func confidenceLabel(_ confidence: CodexResetForecastConfidence) -> String {
        switch confidence {
        case .low: "низкая уверенность"
        case .medium: "средняя уверенность"
        case .high: "высокая уверенность"
        case .unknown: "уверенность не указана"
        }
    }
}

private struct ForecastProbability: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)

            Text("\(value)%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(NotchPalette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Вероятность глобального сброса \(label): \(value) процентов")
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchPalette.text.opacity(0.85))
                    .lineLimit(1)

                Spacer(minLength: 2)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    if let remaining = window.remaining {
                        Text(formatQuotaValue(remaining))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(NotchPalette.text)

                        if window.unit == .percentage {
                            Text("%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                        } else if let limit = window.limit {
                            Text("/ \(formatQuotaValue(limit))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(NotchPalette.secondary)
                        }
                    } else {
                        Text("—")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(NotchPalette.secondary)
                    }
                }
            }

            if let ratio = window.remainingRatio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NotchPalette.track)
                        Capsule()
                            .fill(ratio < 0.2 ? Color.signalCoral : NotchPalette.accent)
                            .frame(width: proxy.size.width * ratio)
                    }
                }
                .frame(height: 4)
            }

            if let resetAt = window.resetAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("сброс")
                    Text(resetAt, style: .relative)
                }
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(NotchPalette.secondary)
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private func formatQuotaValue(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.1f", value)
}
