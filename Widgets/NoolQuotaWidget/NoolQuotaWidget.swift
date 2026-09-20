import AppIntents
import SwiftUI
import WidgetKit

enum QuotaWidgetPeriodOption: String, AppEnum, Sendable {
    case fiveHours
    case week

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Период")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .fiveHours: "5 часов",
        .week: "7 дней",
    ]

    var period: QuotaWidgetPeriod {
        switch self {
        case .fiveHours: .fiveHours
        case .week: .week
        }
    }
}

enum QuotaWidgetProviderSelection: String, AppEnum, Sendable {
    case all
    case chatGPT
    case claude
    case ollama

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Провайдер")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .all: "Все",
        .chatGPT: "ChatGPT",
        .claude: "Claude",
        .ollama: "Ollama",
    ]

    func matches(providerID: String) -> Bool {
        let normalizedID = providerID.lowercased()
        return switch self {
        case .all: true
        case .chatGPT: normalizedID.contains("chatgpt") || normalizedID.contains("codex")
        case .claude: normalizedID.contains("claude")
        case .ollama: normalizedID.contains("ollama")
        }
    }
}

struct NoolQuotaWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Лимиты Nool"
    static let description = IntentDescription("Показывает остаток лимитов за выбранный период.")

    @Parameter(title: "Период", default: .week)
    var period: QuotaWidgetPeriodOption

    @Parameter(title: "Провайдер", default: .all)
    var provider: QuotaWidgetProviderSelection
}

struct NoolQuotaWidgetEntry: TimelineEntry {
    let date: Date
    let data: QuotaWidgetData
    let period: QuotaWidgetPeriod
    let selection: QuotaWidgetProviderSelection
    let isPlaceholder: Bool
}

struct NoolQuotaTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = NoolQuotaWidgetEntry
    typealias Intent = NoolQuotaWidgetConfiguration

    func placeholder(in context: Context) -> Entry {
        placeholderEntry(date: Date())
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        if context.isPreview {
            return placeholderEntry(
                date: Date(),
                period: configuration.period.period,
                selection: configuration.provider
            )
        }
        return Entry(
            date: Date(),
            data: await loadData(),
            period: configuration.period.period,
            selection: configuration.provider,
            isPlaceholder: false
        )
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let now = Date()
        let data = await loadData()
        let offsets = [0, 5, 10, 15, 20, 30, 60]
        let entries = offsets.compactMap { offset -> Entry? in
            guard let date = Calendar.current.date(byAdding: .minute, value: offset, to: now) else {
                return nil
            }
            return Entry(
                date: date,
                data: data,
                period: configuration.period.period,
                selection: configuration.provider,
                isPlaceholder: false
            )
        }
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 15, to: now)
            ?? now.addingTimeInterval(15 * 60)
        return Timeline(entries: entries, policy: .after(refreshDate))
    }

    private func placeholderEntry(
        date: Date,
        period: QuotaWidgetPeriod = .week,
        selection: QuotaWidgetProviderSelection = .all
    ) -> Entry {
        Entry(
            date: date,
            data: .empty,
            period: period,
            selection: selection,
            isPlaceholder: true
        )
    }

    private func loadData() async -> QuotaWidgetData {
        await Task.detached(priority: .utility) {
            QuotaWidgetStore.read(from: QuotaWidgetStore.containerFileURL())
        }.value
    }
}

struct NoolQuotaWidget: Widget {
    let kind = QuotaWidgetStore.kind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: NoolQuotaWidgetConfiguration.self,
            provider: NoolQuotaTimelineProvider()
        ) { entry in
            NoolQuotaWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    NoolQuotaWidgetPalette.background
                }
                .widgetURL(URL(string: "nool-notch://limits"))
        }
        .configurationDisplayName("Лимиты Nool")
        .description("Остаток лимитов ChatGPT, Claude и Ollama.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct NoolQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        NoolQuotaWidget()
    }
}
