import Charts
import SwiftUI

enum SpeedTestSection: String, CaseIterable, Identifiable {
    case test, history, diagnostics
    var id: Self { self }
    var title: String {
        switch self {
        case .test: "Проверка"
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
    @ObservedObject var store: SpeedTestStore
    @ObservedObject var diagnostics: NetworkDiagnosticsStore
    @ObservedObject var navigation: SpeedTestNavigation
    @State private var period: SpeedTestHistoryPeriod = .month
    @State private var chartMetric: SpeedTestChartMetric = .download

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(navigation.section == .diagnostics ? "Диагностика соединения" : "Скорость соединения",
                          systemImage: navigation.section == .diagnostics ? "network" : "speedometer")
                        .font(.system(size: 22, weight: .bold, design: .default))
                    Text(navigation.section == .diagnostics ? "Шлюз · DNS · внешний узел · HTTPS" : "Москва и Франкфурт · два отдельных маршрута")
                        .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer()
                if navigation.section != .diagnostics, store.isRunning {
                    Button(store.isCancelling ? "Остановка…" : "Остановить", action: store.cancel)
                        .buttonStyle(.bordered).disabled(store.isCancelling)
                } else if navigation.section != .diagnostics {
                    Button("Проверить оба") { store.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(diagnostics.isRunning)
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
                    testContent
                        .disabled(diagnostics.isRunning)
                } else if navigation.section == .history {
                    historyContent
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isRunning {
                            Text("Завершите или остановите Speedtest во вкладке «Проверка», чтобы начать диагностику.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        NetworkDiagnosticsView(store: diagnostics)
                            .disabled(store.isRunning)
                    }
                }
            }
        }
        .padding(24)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
    }

    private var testContent: some View {
        VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(store.servers) { server in
                        serverCard(server, state: store.states[server.id] ?? SpeedTestServerState())
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Серверы проверяются по очереди", systemImage: "arrow.right.arrow.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Тест активно использует интернет: до 768 МиБ тестовых данных на два сервера. Задержка измеряется по HTTP. VPN и другие загрузки влияют на результат.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    Text("Закрытие окна останавливает тест. История успешных замеров хранится на этом Mac.")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
        }
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

    private func serverCard(_ server: SpeedTestServer, state: SpeedTestServerState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 21)).foregroundStyle(NotchPalette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.title).font(.system(size: 17, weight: .bold, design: .default))
                    Text(server.provider).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer()
                Button { store.start(serverID: server.id) } label: {
                    Image(systemName: "play.fill").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless).disabled(store.isRunning)
                .help("Проверить: \(server.title)")
                .accessibilityLabel("Проверить: \(server.title)")
            }
            Text(statusText(state)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchPalette.accent).lineLimit(2)
                .frame(height: 30, alignment: .leading)
            if state.status == .running, let progress = state.progress {
                ProgressView(value: min(1, max(0, progress.fraction)))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(progress.megabitsPerSecond.map(number) ?? "—")
                        .font(.system(size: 32, weight: .semibold, design: .default)).monospacedDigit()
                    Text("Мбит/с").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
                .frame(height: 44)
            }
            if let result = state.result {
                Text(state.status == .completed ? "РЕЗУЛЬТАТ" : "ПОСЛЕДНИЙ УСПЕШНЫЙ ЗАМЕР")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchPalette.secondary)
                HStack(spacing: 20) {
                    metric("Скачивание", symbol: "arrow.down", value: result.downloadMbps, unit: "Мбит/с")
                    metric("Отдача", symbol: "arrow.up", value: result.uploadMbps, unit: "Мбит/с")
                }
                Divider().overlay(NotchPalette.separator)
                HStack(spacing: 20) {
                    metric("Задержка", symbol: "waveform.path", value: result.latencyMilliseconds, unit: "мс", small: true)
                    metric("Джиттер", symbol: "waveform", value: result.jitterMilliseconds, unit: "мс", small: true)
                }
                Text(result.measuredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            } else if state.status != .running {
                VStack(alignment: .leading, spacing: 8) {
                    Text("—").font(.system(size: 40, weight: .light, design: .default))
                    Text("Пока нет измерений")
                        .font(.system(size: 12)).foregroundStyle(NotchPalette.secondary)
                }.frame(height: 128, alignment: .center)
            }
            if case .failed(let message) = state.status {
                Text(message).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(NotchPalette.separator) }
    }

    private func metric(_ title: String, symbol: String, value: Double, unit: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(number(value)).font(.system(size: small ? 19 : 27, weight: .semibold, design: .default)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }

    private func statusText(_ state: SpeedTestServerState) -> String {
        switch state.status {
        case .idle: return "Готов к проверке"
        case .queued: return "Ожидает своей очереди"
        case .running:
            switch state.progress?.phase {
            case .latency: return "Измеряем задержку…"
            case .download: return "Проверяем скачивание…"
            case .upload: return "Проверяем отдачу…"
            case nil: return "Подключаемся…"
            }
        case .cancelling: return "Останавливаем соединения…"
        case .cancelled: return "Тест остановлен"
        case .completed: return "Проверка завершена"
        case .failed: return "Не удалось завершить тест"
        }
    }
}
