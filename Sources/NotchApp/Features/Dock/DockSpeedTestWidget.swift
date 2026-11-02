import SwiftUI

/// A compact entry to explicitly started network checks, sharing state with the full panel.
struct DockSpeedTestWidget: View {
    @ObservedObject var session: SpeedTestSession
    let span: Int
    let interactionChanged: (Bool) -> Void
    let arrowEdge: Edge
    let dismissalEpoch: Int
    let openFullPanel: () -> Void
    @State private var showsDetails = false

    init(session: SpeedTestSession = .shared, span: Int,
         interactionChanged: @escaping (Bool) -> Void,
         arrowEdge: Edge = .top, dismissalEpoch: Int = 0,
         openFullPanel: @escaping () -> Void = {}) {
        self.session = session
        self.span = span
        self.interactionChanged = interactionChanged
        self.arrowEdge = arrowEdge
        self.dismissalEpoch = dismissalEpoch
        self.openFullPanel = openFullPanel
    }

    private var latest: Reading? {
        let http = session.http.states.values.compactMap(\.result).max { $0.measuredAt < $1.measuredAt }
            .map { Reading(download: $0.downloadMbps, upload: $0.uploadMbps, date: $0.measuredAt, title: "HTTP") }
        let iperf = session.iperf.result.map {
            Reading(download: $0.downloadMbps, upload: $0.uploadMbps, date: $0.measuredAt, title: $0.transport.title)
        }
        return [http, iperf].compactMap { $0 }.max { $0.date < $1.date }
    }

    private var activeProgress: SpeedTestProgress? {
        session.http.servers.compactMap { server in
            let state = session.http.states[server.id]
            return state?.status == .running ? state?.progress : nil
        }.first
    }

    var body: some View {
        HStack(spacing: 8) {
            SpeedTestActivityIcon(value: session.isRunning ? activeProgress?.megabitsPerSecond : latest?.download,
                                  isRunning: session.isRunning && !session.isCancelling,
                                  phase: activeProgress?.phase)
            if span > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.isRunning ? "Проверка…" : "Speedtest")
                        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if session.isRunning, let speed = activeProgress?.megabitsPerSecond {
                        Text("\(activeProgress?.phase == .upload ? "↑" : "↓") \(compact(speed)) Мбит/с")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(activeProgress?.phase == .upload ? Color.purple : Color.cyan)
                    } else if let latest, !session.isRunning {
                        HStack(spacing: 7) {
                            Text("↓ \(compact(latest.download))")
                            if span > 2 { Text("↑ \(compact(latest.upload))") }
                        }
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    } else {
                        Text(session.isRunning ? "Замер скорости" : "Открыть и проверить")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.56)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, span > 1 ? 8 : 0)
        .dockWidgetSurface()
        .dockTapTarget("Speedtest — открыть проверку соединения") { showsDetails.toggle() }
        .help(latest.map { "Speedtest · \($0.title)\n↓ \(String(format: "%.1f", $0.download)) · ↑ \(String(format: "%.1f", $0.upload)) Мбит/с" }
              ?? "Speedtest · HTTP, TCP/UDP и диагностика соединения")
        .dockPopover(isPresented: $showsDetails, arrowEdge: arrowEdge) {
            DockSpeedTestDetails(session: session, didStart: {}, openFullPanel: {
                showsDetails = false
                openFullPanel()
            })
        }
        .onChange(of: showsDetails) { _, visible in
            interactionChanged(visible)
        }
        .onChange(of: dismissalEpoch) { _, _ in showsDetails = false }
        .onChange(of: arrowEdge) { _, _ in showsDetails = false }
        .onDisappear {
            showsDetails = false
            interactionChanged(false)
        }
    }

    private func compact(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.1fG", value / 1_000) : String(format: "%.0f", value)
    }

    private struct Reading {
        let download: Double
        let upload: Double
        let date: Date
        let title: String
    }
}

struct DockSpeedTestDetails: View {
    enum Section: String, CaseIterable, Identifiable {
        case http, iperf, diagnostics
        var id: Self { self }
        var title: String {
            switch self { case .http: "HTTP"; case .iperf: "TCP / UDP"; case .diagnostics: "Диагностика" }
        }
    }

    @ObservedObject var session: SpeedTestSession
    let didStart: () -> Void
    let openFullPanel: () -> Void
    @State private var section: Section = .http

    init(session: SpeedTestSession, initialSection: Section = .http,
         didStart: @escaping () -> Void, openFullPanel: @escaping () -> Void) {
        self.session = session
        self._section = State(initialValue: initialSection)
        self.didStart = didStart
        self.openFullPanel = openFullPanel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Speedtest")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Button(action: openFullPanel) { Image(systemName: "arrow.up.right.square").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("Открыть полную панель и историю")
                    .accessibilityLabel("Открыть полную панель Speedtest")
            }
            Picker("Тип проверки", selection: $section) {
                ForEach(Section.allCases) { item in Text(item.title).tag(item) }
            }.pickerStyle(.segmented).labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .http:
                        SpeedTestHTTPDashboard(session: session, compact: true, didStart: didStart)
                    case .iperf:
                        IperfTestView(session: session, didStart: didStart)
                    case .diagnostics:
                        DockNetworkDiagnosticsContent(session: session, didStart: didStart)
                    }
                    Text("Можно свернуть панель — проверка продолжится. Чтобы прервать её, нажмите «Стоп».")
                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 408, height: 540)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(SpeedTestStyle.download)
    }
}

private struct DockNetworkDiagnosticsContent: View {
    @ObservedObject var session: SpeedTestSession
    let didStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NetworkDiagnosticsView(store: session.diagnostics, start: {
                if session.startDiagnostics() { didStart() }
            })
                .disabled(session.http.isRunning || session.iperf.isRunning)
        }
    }
}
