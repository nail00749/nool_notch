import SwiftUI
import WidgetKit

enum NoolQuotaWidgetPalette {
    static let background = LinearGradient(
        colors: [
            Color(red: 16 / 255, green: 26 / 255, blue: 40 / 255),
            Color(red: 10 / 255, green: 17 / 255, blue: 28 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let text = Color(red: 237 / 255, green: 244 / 255, blue: 252 / 255)
    static let secondary = Color(red: 137 / 255, green: 154 / 255, blue: 175 / 255)
    static let track = text.opacity(0.13)
    static let healthy = Color(red: 49 / 255, green: 222 / 255, blue: 113 / 255)
    static let warning = Color(red: 1, green: 196 / 255, blue: 71 / 255)
    static let critical = Color(red: 1, green: 82 / 255, blue: 82 / 255)
}

private struct QuotaRingPresentation: Identifiable {
    let id: String
    let name: String
    let assetName: String?
    let percentage: Int?
    let isStale: Bool
    let isEmptySlot: Bool

    static let gallery: [QuotaRingPresentation] = [
        .init(id: "gallery-chatgpt", name: "ChatGPT", assetName: "QuotaChatGPT", percentage: 80, isStale: false, isEmptySlot: false),
        .init(id: "gallery-claude", name: "Claude", assetName: "QuotaClaude", percentage: 100, isStale: false, isEmptySlot: false),
        .init(id: "gallery-ollama", name: "Ollama", assetName: "QuotaOllama", percentage: 38, isStale: false, isEmptySlot: false),
        .empty(index: 3),
    ]

    static func empty(index: Int) -> QuotaRingPresentation {
        QuotaRingPresentation(
            id: "empty-\(index)",
            name: "",
            assetName: nil,
            percentage: nil,
            isStale: false,
            isEmptySlot: true
        )
    }
}

struct NoolQuotaWidgetView: View {
    let entry: NoolQuotaWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let emptyState {
                NoolQuotaWidgetEmptyView(state: emptyState)
            } else if family == .systemSmall {
                smallContent
            } else {
                mediumContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: NoolQuotaWidgetEmptyState? {
        guard entry.isPlaceholder == false, presentations.compactMap({ $0 }).isEmpty else {
            return nil
        }
        return entry.data.providers.isEmpty ? .noData : .sourceDisabled
    }

    private var smallContent: some View {
        let presentation = presentations.compactMap { $0 }.first
            ?? QuotaRingPresentation.gallery[0]
        return VStack(spacing: 7) {
            HStack(spacing: 5) {
                Text(presentation.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(NoolQuotaWidgetPalette.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(periodDisplayLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(NoolQuotaWidgetPalette.secondary)
            }

            QuotaRingView(presentation: presentation, size: 72)

            Text(percentageText(presentation.percentage))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NoolQuotaWidgetPalette.text.opacity(presentation.percentage == nil ? 0.45 : 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var mediumContent: some View {
        VStack(spacing: 9) {
            HStack(spacing: 6) {
                Text("Осталось")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(NoolQuotaWidgetPalette.secondary)
                Spacer(minLength: 0)
                Text(periodDisplayLabel)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(NoolQuotaWidgetPalette.secondary)
            }

            HStack(spacing: 13) {
                ForEach(mediumPresentations) { presentation in
                    VStack(spacing: 9) {
                        QuotaRingView(presentation: presentation, size: 58)
                        Text(percentageText(for: presentation))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(
                                NoolQuotaWidgetPalette.text.opacity(presentation.percentage == nil ? 0.45 : 1)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var presentations: [QuotaRingPresentation?] {
        if entry.isPlaceholder {
            return QuotaRingPresentation.gallery
                .filter { entry.selection.matches(providerID: $0.id) }
                .map(Optional.some)
        }

        let selectedProviders = entry.data.providers.filter {
            entry.selection.matches(providerID: $0.id)
        }
        return selectedProviders.prefix(4).map { provider in
            let window = provider.window(for: entry.period)
            return QuotaRingPresentation(
                id: provider.id,
                name: provider.name,
                assetName: assetName(for: provider.id),
                percentage: provider.percentage(for: entry.period),
                isStale: provider.isStale(window: window, at: entry.date),
                isEmptySlot: false
            )
        }
    }

    private var mediumPresentations: [QuotaRingPresentation] {
        var result = presentations.compactMap { $0 }
        if entry.selection == .all {
            while result.count < 4 {
                result.append(.empty(index: result.count))
            }
        }
        return Array(result.prefix(4))
    }

    private func assetName(for providerID: String) -> String? {
        let normalizedID = providerID.lowercased()
        if normalizedID.contains("chatgpt") || normalizedID.contains("codex") {
            return "QuotaChatGPT"
        }
        if normalizedID.contains("claude") {
            return "QuotaClaude"
        }
        if normalizedID.contains("ollama") {
            return "QuotaOllama"
        }
        return nil
    }

    private func percentageText(_ percentage: Int?) -> String {
        percentage.map { "\($0)%" } ?? "—"
    }

    private func percentageText(for presentation: QuotaRingPresentation) -> String {
        presentation.isEmptySlot ? " " : percentageText(presentation.percentage)
    }

    private var periodDisplayLabel: String {
        switch entry.period {
        case .fiveHours: "5 ч"
        case .week: "7 д"
        }
    }
}

private struct QuotaRingView: View {
    let presentation: QuotaRingPresentation
    let size: CGFloat

    private var progress: Double {
        Double(presentation.percentage ?? 0) / 100
    }

    private var ringColor: Color {
        guard let percentage = presentation.percentage else { return NoolQuotaWidgetPalette.secondary }
        if percentage <= 10 { return NoolQuotaWidgetPalette.critical }
        if percentage <= 20 { return NoolQuotaWidgetPalette.warning }
        return NoolQuotaWidgetPalette.healthy
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(NoolQuotaWidgetPalette.track, lineWidth: 6)

            if presentation.percentage != nil {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        ringColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            providerIcon

            if presentation.isStale {
                Image(systemName: "clock.fill")
                    .font(.system(size: size * 0.17, weight: .bold))
                    .foregroundStyle(NoolQuotaWidgetPalette.warning)
                    .padding(3)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .offset(x: size * 0.34, y: -size * 0.34)
            }
        }
        .frame(width: size, height: size)
        .opacity(presentation.isStale ? 0.58 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let assetName = presentation.assetName {
            Image(assetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(NoolQuotaWidgetPalette.text.opacity(0.92))
                .frame(width: size * 0.36, height: size * 0.36)
        } else if presentation.isEmptySlot == false {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: size * 0.29, weight: .medium))
                .foregroundStyle(NoolQuotaWidgetPalette.text.opacity(0.82))
        }
    }

    private var accessibilityLabel: String {
        if presentation.isEmptySlot {
            return "Пустая ячейка лимита"
        }
        let value = presentation.percentage.map { "осталось \($0) процентов" } ?? "лимит недоступен"
        let freshness = presentation.isStale ? ", данные устарели" : ""
        return "\(presentation.name): \(value)\(freshness)"
    }
}

private enum NoolQuotaWidgetEmptyState {
    case noData
    case sourceDisabled

    var title: String {
        switch self {
        case .noData: "Откройте NooL App"
        case .sourceDisabled: "Включите источник в NooL App"
        }
    }

    var detail: String {
        switch self {
        case .noData: "Лимиты появятся после обновления"
        case .sourceDisabled: "Виджет использует включённые провайдеры"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .noData: "Откройте NooL App, чтобы обновить лимиты"
        case .sourceDisabled: "Включите выбранный источник лимитов в NooL App"
        }
    }
}

private struct NoolQuotaWidgetEmptyView: View {
    let state: NoolQuotaWidgetEmptyState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(NoolQuotaWidgetPalette.secondary)
            Text(state.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(NoolQuotaWidgetPalette.text)
            Text(state.detail)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(NoolQuotaWidgetPalette.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.accessibilityLabel)
    }
}
