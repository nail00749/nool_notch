import SwiftUI

/// One process sampler is shared between expanded CPU and RAM sections.
/// Closing the summary releases its process snapshot.
@MainActor
final class DockSystemLoadDetailState: ObservableObject {
    @Published private(set) var metric: SystemMonitorMetric?
    @Published private(set) var keepsSummaryOpen = false
    let processes: SystemProcessesStore
    private var hoveredRow: SystemMonitorMetric?
    private var insideDetail = false
    private var insideSummary = false
    private var pending: Task<Void, Never>?
    private let openDelay: Duration
    private let closeDelay: Duration

    init(processes: SystemProcessesStore = SystemProcessesStore(),
         openDelay: Duration = .milliseconds(180), closeDelay: Duration = .milliseconds(260)) {
        self.processes = processes
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    func rowHovered(_ value: SystemMonitorMetric, inside: Bool) {
        if inside {
            hoveredRow = value
            pending?.cancel()
            pending = Task { @MainActor [weak self, openDelay] in
                do { try await Task.sleep(for: openDelay) } catch { return }
                guard let self, self.hoveredRow == value else { return }
                self.select(value)
            }
        } else if hoveredRow == value {
            hoveredRow = nil
            scheduleClose()
        }
    }

    func select(_ value: SystemMonitorMetric) {
        pending?.cancel()
        metric = value
        insideDetail = false
        switch value {
        case .cpu: processes.start(sort: .cpu)
        case .memory: processes.start(sort: .memory)
        case .disk, .network: processes.stop()
        }
        updateBridge()
    }

    func detailHovered(_ value: SystemMonitorMetric, inside: Bool) {
        guard metric == value else { return }
        insideDetail = inside
        if inside { pending?.cancel() } else { scheduleClose() }
        updateBridge()
    }

    func summaryHovered(_ inside: Bool) {
        insideSummary = inside
        if !inside, hoveredRow == nil { scheduleClose() }
        updateBridge()
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        if metric != nil { metric = nil }
        hoveredRow = nil
        insideDetail = false
        if processes.isRunning || processes.snapshot != nil { processes.stop() }
        updateBridge()
    }

    func reset() {
        insideSummary = false
        dismiss()
    }

    private func updateBridge() {
        keepsSummaryOpen = insideSummary || insideDetail || metric != nil
    }

    private func scheduleClose() {
        pending?.cancel()
        guard metric != nil, hoveredRow == nil, !insideDetail else { return }
        pending = Task { @MainActor [weak self, closeDelay] in
            do { try await Task.sleep(for: closeDelay) } catch { return }
            guard let self, self.hoveredRow == nil, !self.insideDetail else { return }
            self.dismiss()
        }
    }
}

struct DockSystemLoadMetricDetails: View {
    let metric: SystemMonitorMetric
    @ObservedObject var store: SystemProcessesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: metric.symbol).font(.system(size: 13, weight: .semibold))
            if metric == .cpu || metric == .memory {
                processDetails
            } else {
                Text(metric == .disk
                     ? "Здесь показано занятое место на системном диске. Это объём файлов, а не текущая скорость чтения и записи приложений."
                     : "Здесь показана общая скорость приёма и передачи данных. Показаний сети по отдельным приложениям в этой сводке нет.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(16).frame(width: 286, height: 338, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(Color(red: 0.075, green: 0.08, blue: 0.09))
        .preferredColorScheme(.dark)
    }

    private var title: String {
        switch metric {
        case .cpu: "CPU · топ процессов"
        case .memory: "ОЗУ · топ процессов"
        case .disk: "Занятое место"
        case .network: "Скорость сети"
        }
    }

    @ViewBuilder private var processDetails: some View {
        Text("Приложения и процессы").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        if store.isWarmingUp {
            VStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(metric == .cpu ? "Измеряем CPU…" : "Читаем память…")
                if metric == .cpu { Text("Нужны два замера с интервалом 2 с") }
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.topProcesses.isEmpty {
            Text("Нет доступных показаний процессов")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 9) {
                ForEach(store.topProcesses) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("PID \(process.pid)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer(minLength: 2)
                        Text(value(process)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        Text(metric == .cpu
             ? "100% CPU — одно ядро. Процесс может использовать больше 100%."
             : "Резидентная ОЗУ включает общие страницы; её сумма может отличаться от общей памяти Mac.")
            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        if let skipped = store.snapshot?.skippedProcessCount, skipped > 0 {
            Text("Недоступно процессов: \(skipped)")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func value(_ process: MonitoredSystemProcess) -> String {
        if metric == .memory { return SystemMetricReading.bytes(process.residentMemoryBytes) }
        return process.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—"
    }
}
