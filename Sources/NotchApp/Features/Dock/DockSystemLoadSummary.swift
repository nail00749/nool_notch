import AppKit
import SwiftUI

struct DockSystemLoadSummary: View {
    let snapshot: SystemMetricsSnapshot?
    let history: [SystemMetricsSnapshot]
    @StateObject private var details: DockSystemLoadDetailState
    @ObservedObject private var processes: SystemProcessesStore
    let hoverChanged: (Bool) -> Void

    init(snapshot: SystemMetricsSnapshot?, history: [SystemMetricsSnapshot] = [],
         details: DockSystemLoadDetailState = DockSystemLoadDetailState(),
         hoverChanged: @escaping (Bool) -> Void = { _ in }) {
        self.snapshot = snapshot
        self.history = history
        _details = StateObject(wrappedValue: details)
        self.processes = details.processes
        self.hoverChanged = hoverChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Нагрузка системы").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("2 минуты").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(.cpu)
                    SystemMetricsHistoryView(samples: history, metric: .cpu, color: .blue)
                    if details.metric == .cpu { processList }
                    Divider()
                    sectionHeader(.memory)
                    HStack(spacing: 8) {
                        Text("Давление").font(.system(size: 11)).foregroundStyle(.secondary)
                        SystemMemoryPressureBadge(pressure: snapshot?.memoryDetails?.pressure)
                        Spacer(minLength: 0)
                        Text(memoryUsage).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    }
                    if details.metric == .memory {
                        SystemMemoryBreakdown(details: snapshot?.memoryDetails).padding(.leading, 16)
                    }
                    SystemMetricsHistoryView(samples: history, metric: .memory, color: .teal)
                    if details.metric == .memory { processList }
                    Divider()
                    compactMetric(.disk)
                    compactMetric(.network)
                }
                .padding(.trailing, 3)
            }
            Divider()
            Button { CoolingWindowCoordinator.shared.show() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "fanblades")
                    Text("Охлаждение и вентиляторы")
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                }.font(.system(size: 11)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(NotchPalette.accent)
            Button(action: Self.openActivityMonitor) {
                HStack {
                    Text("Открыть Мониторинг системы")
                    Spacer()
                    Image(systemName: "arrow.up.forward")
                }.font(.system(size: 11)).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360, height: 660)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .onHover(perform: hoverChanged)
        .onAppear { if details.metric == nil { details.select(.memory) } }
        .onDisappear { details.reset(); hoverChanged(false) }
    }

    private var memoryUsage: String {
        guard let memory = snapshot?.memory else { return "— / —" }
        return "\(SystemMetricReading.bytes(memory.usedBytes)) / \(SystemMetricReading.bytes(memory.totalBytes))"
    }

    private func sectionHeader(_ metric: SystemMonitorMetric) -> some View {
        let reading = SystemMetricReading(metric: metric, snapshot: snapshot)
        return Button {
            if details.metric == metric { details.dismiss() } else { details.select(metric) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: details.metric == metric ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 8)
                Text(metric == .memory ? "Память" : "CPU").font(.system(size: 12, weight: .semibold))
                if metric == .cpu {
                    GeometryReader { proxy in
                        Capsule().fill(.secondary.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.blue).frame(width: proxy.size.width * (reading.fraction ?? 0))
                            }
                    }.frame(height: 4).padding(.horizontal, 7)
                }
                Spacer(minLength: 0)
                Text(reading.value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.title): \(details.metric == metric ? "свернуть" : "раскрыть") процессы")
    }

    @ViewBuilder private var processList: some View {
        if processes.isWarmingUp {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Измеряем процессы…").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 14)
        } else if processes.groups.isEmpty {
            Text("Нет доступных показаний процессов").font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 10)
        } else {
            SystemProcessGroupList(groups: processes.groups, sort: processes.sort)
        }
        Text(processes.sort == .cpu
             ? "100% — одно ядро. Показания группы суммируются."
             : "Резидентная ОЗУ группы. Общие страницы могут учитываться несколько раз.")
            .font(.system(size: 9)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func compactMetric(_ metric: SystemMonitorMetric) -> some View {
        let reading = SystemMetricReading(metric: metric, snapshot: snapshot)
        return HStack(spacing: 8) {
            Image(systemName: metric.symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(metric.title)
            Spacer()
            Text(metric == .network ? "\(reading.value)  \(reading.detail)" : reading.detail).monospacedDigit()
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }

    private static func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
