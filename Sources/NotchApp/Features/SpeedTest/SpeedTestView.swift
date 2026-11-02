import Charts
import SwiftUI

enum SpeedTestSection: String, CaseIterable, Identifiable {
    case test, iperf, history, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .test: "Проверка"
        case .iperf: "TCP / UDP"
        case .history: "История"
        case .diagnostics: "Диагностика"
        }
    }
}

@MainActor
final class SpeedTestNavigation: ObservableObject {
    @Published var section: SpeedTestSection = .test
}

private enum SpeedTestChartMetric: String, CaseIterable, Identifiable {
    case download, upload, latency
    var id: Self { self }

    var title: String {
        switch self {
        case .download: "Скачивание"
        case .upload: "Отдача"
        case .latency: "Задержка"
        }
    }

    var unit: String { self == .latency ? "мс" : "Мбит/с" }

    func value(_ average: SpeedTestDailyAverage) -> Double {
        switch self {
        case .download: average.downloadMbps
        case .upload: average.uploadMbps
        case .latency: average.latencyMilliseconds
        }
    }
}

struct SpeedTestView: View {
    @ObservedObject var session: SpeedTestSession
    @ObservedObject var store: SpeedTestStore
    @ObservedObject var diagnostics: NetworkDiagnosticsStore
    @ObservedObject var navigation: SpeedTestNavigation
    @State private var period: SpeedTestHistoryPeriod = .month
    @State private var chartMetric: SpeedTestChartMetric = .download

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(navigation.section == .diagnostics ? "Диагностика соединения" : "Speedtest",
                          systemImage: navigation.section == .diagnostics ? "network" : "speedometer")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(navigation.section == .diagnostics ? "Шлюз · DNS · внешний узел · HTTPS" :
                            (navigation.section == .iperf ? "Свой iPerf3-сервер · TCP и UDP" : "Москва и Франкфурт · два отдельных маршрута"))
                        .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer()
                if session.isRunning && navigation.section != .test {
                    Button(session.isCancelling ? "Остановка…" : "Остановить", action: session.cancel)
                        .buttonStyle(.bordered).disabled(session.isCancelling)
                } else if navigation.section == .history && !session.isRunning {
                    Button("Проверить оба") { session.startHTTP() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Picker("Раздел Speedtest", selection: $navigation.section) {
                ForEach(SpeedTestSection.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Раздел Speedtest")
            if diagnostics.isRunning, navigation.section != .diagnostics {
                Label("Выполняется диагностика. Дождитесь завершения или остановите её во вкладке «Диагностика».",
                      systemImage: "network")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                if navigation.section == .test {
                    SpeedTestHTTPDashboard(session: session)
                } else if navigation.section == .iperf {
                    IperfTestView(session: session)
                } else if navigation.section == .history {
                    historyContent
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isRunning || session.iperf.isRunning {
                            Text("Завершите или остановите Speedtest во вкладке «Проверка», чтобы начать диагностику.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        NetworkDiagnosticsView(store: diagnostics, start: { session.startDiagnostics() })
                            .disabled(store.isRunning || session.iperf.isRunning)
                    }
                }
            }
        }
        .padding(24)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(SpeedTestStyle.download)
    }

    private var historyContent: some View {
        let results = SpeedTestHistory.filter(store.history, period: period)
        let averages = SpeedTestHistory.dailyAverages(results)
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("История соединения").font(.system(size: 17, weight: .semibold))
                    Text("Последние 200 успешных замеров на этом Mac")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer()
                Picker("Период", selection: $period) {
                    ForEach(SpeedTestHistoryPeriod.allCases) { item in Text(item.title).tag(item) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            if let warning = store.historyStorageWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if store.history.isEmpty {
                ContentUnavailableView("Пока нет истории", systemImage: "chart.xyaxis.line",
                                       description: Text("Запустите первую проверку скорости."))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if results.isEmpty {
                ContentUnavailableView("За этот период нет замеров", systemImage: "calendar",
                                       description: Text("Выберите другой период или запустите проверку."))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Средние значения по дням")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Picker("Показатель", selection: $chartMetric) {
                            ForEach(SpeedTestChartMetric.allCases) { item in Text(item.title).tag(item) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 310)
                    }
                    Text("Каждая точка — среднее за день для одного сервера. Значения и количество замеров приведены ниже.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    Chart {
                        ForEach(averages) { average in
                            let serverTitle = title(for: average.serverID)
                            LineMark(x: .value("День", average.day),
                                     y: .value(chartMetric.unit, chartMetric.value(average)),
                                     series: .value("Сервер", serverTitle))
                                .foregroundStyle(by: .value("Сервер", serverTitle))
                            PointMark(x: .value("День", average.day),
                                      y: .value(chartMetric.unit, chartMetric.value(average)))
                                .foregroundStyle(by: .value("Сервер", serverTitle))
                        }
                    }
                    .chartLegend(position: .bottom, alignment: .leading)
                    .frame(height: 200)
                    .accessibilityLabel("График: \(chartMetric.title), средние значения по дням")
                    Divider()
                    ForEach(averages.reversed()) { average in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(average.day.formatted(date: .abbreviated, time: .omitted))
                                .frame(width: 95, alignment: .leading)
                            Text(title(for: average.serverID)).frame(width: 100, alignment: .leading)
                            Text("Замеров: \(average.sampleCount)")
                                .foregroundStyle(NotchPalette.secondary)
                            Spacer()
                            Text("↓ \(number(average.downloadMbps)) · ↑ \(number(average.uploadMbps)) Мбит/с · \(number(average.latencyMilliseconds)) мс")
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(16)
                .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NotchPalette.separator) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Все замеры · от новых к старым").font(.system(size: 13, weight: .semibold))
                    ForEach(results.indices, id: \.self) { index in
                        let result = results[index]
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(result.measuredAt.formatted(date: .abbreviated, time: .shortened))
                                .frame(width: 150, alignment: .leading)
                            Text(title(for: result.serverID)).frame(width: 100, alignment: .leading)
                            Spacer()
                            Text("↓ \(number(result.downloadMbps)) · ↑ \(number(result.uploadMbps)) Мбит/с · \(number(result.latencyMilliseconds)) мс")
                                .monospacedDigit()
                        }
                        .font(.system(size: 11))
                        if index < results.count - 1 { Divider() }
                    }
                }
                .padding(16)
                .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(NotchPalette.separator) }
            }
        }
    }

    private func title(for serverID: String) -> String {
        store.servers.first { $0.id == serverID }?.title ?? serverID
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }

}
