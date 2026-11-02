import SwiftUI

/// One instrument follows the current endpoint; completed readings stay in the comparison rows.
struct SpeedTestHTTPDashboard: View {
    @ObservedObject var session: SpeedTestSession
    @ObservedObject private var store: SpeedTestStore
    var compact = false
    var didStart: () -> Void = {}
    @State private var selectedServerID = ""

    init(session: SpeedTestSession, compact: Bool = false, didStart: @escaping () -> Void = {}) {
        self.session = session
        self.store = session.http
        self.compact = compact
        self.didStart = didStart
    }

    private var otherTestRunning: Bool { session.iperf.isRunning || session.diagnostics.isRunning }
    private var activeServer: SpeedTestServer? {
        store.servers.first { server in
            let status = store.states[server.id]?.status
            return status == .running || status == .cancelling
        }
    }
    private var activeState: SpeedTestServerState? {
        activeServer.flatMap { store.states[$0.id] }
    }
    private var latestResult: SpeedTestMeasurement? {
        store.servers.filter { selectedServerID.isEmpty || $0.id == selectedServerID }
            .compactMap { store.states[$0.id]?.result }.max { $0.measuredAt < $1.measuredAt }
    }
    private var instrumentServer: SpeedTestServer? {
        activeServer ?? store.servers.first { $0.id == latestResult?.serverID }
    }
    private var instrumentValue: Double? {
        store.isRunning ? activeState?.progress?.megabitsPerSecond : latestResult?.downloadMbps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            controls
            if compact {
                instrument
                results
            } else {
                HStack(alignment: .center, spacing: 28) {
                    instrument.frame(maxWidth: .infinity)
                    results.frame(maxWidth: .infinity)
                }
            }
            if otherTestRunning {
                Label("Сначала завершите TCP/UDP-тест или диагностику.", systemImage: "hourglass")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
            Text("HTTP · до 768 МиБ на два сервера. VPN и другие загрузки влияют на результат.")
                .font(.system(size: compact ? 9 : 11)).foregroundStyle(NotchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(NotchPalette.text)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Сервер проверки", selection: $selectedServerID) {
                Text("Оба").tag("")
                ForEach(store.servers) { server in Text(server.title).tag(server.id) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(store.isRunning)
            Spacer(minLength: 0)
            Button {
                if store.isRunning { session.cancel() }
                else if session.startHTTP(serverID: selectedServerID.isEmpty ? nil : selectedServerID) { didStart() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text(store.isCancelling ? "Стоп…" : store.isRunning ? "Стоп" : "Начать")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 12).frame(height: 28)
                .foregroundStyle(store.isRunning ? Color.white : Color.black)
                .background(store.isRunning ? Color.white.opacity(0.12) : SpeedTestStyle.download, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.isCancelling || otherTestRunning)
            .accessibilityLabel(store.isRunning ? "Остановить HTTP-тест" : "Начать HTTP-тест")
        }
    }

    private var instrument: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if store.isRunning {
                    Circle().fill(store.isCancelling ? Color.orange : SpeedTestStyle.download).frame(width: 5, height: 5)
                }
                Text(endpointTitle)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchPalette.secondary)
                    .lineLimit(1)
            }
            .frame(height: 15)
            SpeedTestDial(value: instrumentValue,
                          phase: store.isRunning && !store.isCancelling ? activeState?.progress?.phase : nil,
                          isRunning: store.isRunning && !store.isCancelling,
                          title: store.isCancelling ? "Останавливаем…" : store.isRunning ? "Подключение" : latestResult == nil ? "Готов к проверке" : "Последнее скачивание",
                          compact: compact)
            stages
        }
    }

    private var endpointTitle: String {
        if let server = instrumentServer { return "\(server.title) · \(server.provider)" }
        if store.isRunning { return "Подключаемся к серверу…" }
        return selectedServerID.isEmpty ? "Два маршрута по очереди" : store.servers.first { $0.id == selectedServerID }?.title ?? "HTTP"
    }

    private var stages: some View {
        HStack(spacing: compact ? 14 : 18) {
            stage("Задержка", symbol: "waveform.path", phase: .latency)
            stage("Скачивание", symbol: "arrow.down", phase: .download)
            stage("Отдача", symbol: "arrow.up", phase: .upload)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, compact ? 2 : 6)
        .accessibilityElement(children: .combine)
    }

    private func stage(_ title: String, symbol: String, phase: SpeedTestPhase) -> some View {
        let active = store.isRunning && !store.isCancelling && activeState?.progress?.phase == phase
        return Label(title, systemImage: symbol)
            .font(.system(size: compact ? 9 : 10, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? (phase == .upload ? SpeedTestStyle.upload : SpeedTestStyle.download) : NotchPalette.secondary.opacity(0.65))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.servers.enumerated()), id: \.element.id) { index, server in
                resultRow(server, state: store.states[server.id] ?? SpeedTestServerState())
                if index < store.servers.count - 1 { Divider().overlay(NotchPalette.separator) }
            }
        }
    }

    private func resultRow(_ server: SpeedTestServer, state: SpeedTestServerState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(server.title).font(.system(size: compact ? 11 : 13, weight: .semibold))
                Spacer(minLength: 0)
                Text(rowStatus(state)).font(.system(size: 9))
                    .foregroundStyle(state.status == .running ? SpeedTestStyle.download : NotchPalette.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                reading(state.result?.downloadMbps, symbol: "arrow.down", color: SpeedTestStyle.download)
                reading(state.result?.uploadMbps, symbol: "arrow.up", color: SpeedTestStyle.upload)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.result.map { "Ping \($0.latencyMilliseconds.formatted(.number.precision(.fractionLength(0)))) мс" } ?? "Ping —")
                    Text(state.result.map { "Jitter \($0.jitterMilliseconds.formatted(.number.precision(.fractionLength(1)))) мс" } ?? "Jitter —")
                        .font(.system(size: 8))
                }
                .font(.system(size: compact ? 9 : 10)).monospacedDigit().foregroundStyle(NotchPalette.secondary)
            }
            if case .failed(let message) = state.status {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, compact ? 7 : 13)
    }

    private func reading(_ value: Double?, symbol: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 9, weight: .bold))
            Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                .font(.system(size: compact ? 12 : 16, weight: .medium)).monospacedDigit()
            Text("Мбит/с").font(.system(size: 8)).foregroundStyle(NotchPalette.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }

    private func rowStatus(_ state: SpeedTestServerState) -> String {
        let previous = state.result == nil ? "" : " · прошлый замер"
        switch state.status {
        case .idle: return state.result.map { "Замер \($0.measuredAt.formatted(date: .omitted, time: .shortened))" } ?? "Нет замера"
        case .queued: return "В очереди\(previous)"
        case .running: return "Измеряем\(previous)"
        case .cancelling: return "Остановка\(previous)"
        case .cancelled: return "Остановлен\(previous)"
        case .completed: return state.result.map { "Замер \($0.measuredAt.formatted(date: .omitted, time: .shortened))" } ?? "Готово"
        case .failed: return "Ошибка\(previous)"
        }
    }
}
