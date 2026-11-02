import SwiftUI

/// Optional TCP/UDP checks against a server chosen by the user.
struct IperfTestView: View {
    @ObservedObject var session: SpeedTestSession
    @ObservedObject private var store: IperfTestStore
    var didStart: () -> Void = {}
    @State private var showsConfiguration: Bool

    init(session: SpeedTestSession, didStart: @escaping () -> Void = {}) {
        self.session = session
        self.store = session.iperf
        self.didStart = didStart
        self._showsConfiguration = State(initialValue: session.iperf.configuration.host.isEmpty)
    }

    private var otherTestRunning: Bool { session.http.isRunning || session.diagnostics.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iPerf3 · TCP / UDP")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Прямой замер до вашего iPerf-сервера")
                        .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
                Spacer(minLength: 4)
                if store.isRunning {
                    Button(store.isCancelling ? "Остановка…" : "Остановить", action: session.cancel)
                        .disabled(store.isCancelling)
                } else {
                    Button("Начать") {
                        if session.startIperf() { didStart() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(otherTestRunning || store.configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            SpeedTestDial(
                value: store.isRunning ? nil : store.result?.downloadMbps,
                isRunning: store.isRunning && !store.isCancelling,
                title: store.isRunning ? store.phaseTitle : "Последнее скачивание",
                compact: true
            )

            DisclosureGroup(isExpanded: $showsConfiguration) {
                configuration.padding(.top, 10)
                    .disabled(session.isRunning)
            } label: {
                HStack {
                    Text("Сервер и параметры").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(store.configuration.host.isEmpty ? "Не настроен" : "\(store.configuration.host):\(String(store.configuration.port))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if otherTestRunning {
                Label("Сначала завершите HTTP-тест или диагностику.", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }

            if store.isRunning {
                Text(store.isCancelling ? "Завершаем тест…" : "Скорость появится после завершения обоих направлений.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = store.result {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Последний результат · \(result.transport.title)")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(result.measuredAt, style: .time)
                            .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                    }
                    Text(result.host).font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 24) {
                        reading("Скачивание", value: result.downloadMbps, unit: "Мбит/с", symbol: "arrow.down")
                        reading("Отдача", value: result.uploadMbps, unit: "Мбит/с", symbol: "arrow.up")
                    }
                    if result.transport == .udp {
                        Divider()
                        HStack(spacing: 24) {
                            optionalReading("Jitter · максимум", value: result.jitterMilliseconds, unit: "мс")
                            optionalReading("Потери · максимум", value: result.lossPercent, unit: "%")
                        }
                        Text("Максимум по принимающей стороне среди скачивания и отдачи.")
                            .font(.system(size: 9)).foregroundStyle(NotchPalette.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 12))
            } else if !store.isRunning {
                Text("Результат появится после первого завершённого теста.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Нужен доступный iPerf3-сервер по указанному адресу и порту и установленный iPerf3 на Mac. Сервер на этом Mac не запускается.")
                Text("Скачивание и отдача проверяются по очереди. TCP стремится занять доступную полосу; в UDP задаётся целевая скорость. Тест создаёт сетевой трафик, VPN и другие загрузки влияют на результат.")
            }
            .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NotchPalette.text)
        .tint(SpeedTestStyle.download)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Протокол", selection: $store.configuration.transport) {
                ForEach(IperfTestTransport.allCases) { transport in
                    Text(transport.title).tag(transport)
                }
            }.pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 5) {
                Text("Сервер").font(.system(size: 11, weight: .medium))
                HStack(spacing: 10) {
                    TextField("Адрес или IP", text: $store.configuration.host)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Адрес iPerf3-сервера")
                    TextField("Порт", value: $store.configuration.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 76)
                        .accessibilityLabel("Порт iPerf3-сервера")
                }
            }

            HStack {
                Text("На каждое направление").font(.system(size: 11))
                Spacer()
                Stepper("\(store.configuration.durationSeconds) с", value: $store.configuration.durationSeconds, in: 1...30)
                    .font(.system(size: 11)).fixedSize()
                    .accessibilityLabel("Длительность каждого направления iPerf3")
            }

            if store.configuration.transport == .udp {
                HStack {
                    Text("Целевая скорость UDP").font(.system(size: 11))
                    Spacer()
                    TextField("Мбит/с", value: $store.configuration.udpMegabitsPerSecond, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 82)
                        .accessibilityLabel("Целевая скорость UDP в мегабитах в секунду")
                    Text("Мбит/с").font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                }
            }
        }
    }

    private func reading(_ title: String, value: Double, unit: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10)).foregroundStyle(symbol == "arrow.down" ? SpeedTestStyle.download : SpeedTestStyle.upload)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 20, weight: .semibold, design: .default)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionalReading(_ title: String, value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
            Text(value.map { String(format: "%.2f %@", $0, unit) } ?? "Нет данных")
                .font(.system(size: 13, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
