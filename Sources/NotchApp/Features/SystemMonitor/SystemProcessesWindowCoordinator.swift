import AppKit
import SwiftUI

@MainActor
final class SystemProcessesWindowCoordinator: NSObject, NSWindowDelegate {
    private let store = SystemProcessesStore()
    private var panel: UtilityPanel?

    func show(sort: SystemProcessSort) {
        store.start(sort: sort)
        if panel == nil {
            let window = UtilityPanel(title: "Что нагружает Mac", contentSize: NSSize(width: 610, height: 600),
                                      minimumSize: NSSize(width: 570, height: 560))
            window.delegate = self
            let hosting = NSHostingView(rootView: SystemProcessesView(store: store))
            hosting.sizingOptions = []
            window.contentView = hosting
            window.center()
            panel = window
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { store.stop() }

    func stop() {
        store.stop()
        panel?.close()
    }
}

struct SystemProcessesView: View {
    @ObservedObject var store: SystemProcessesStore
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Что нагружает Mac", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 22, weight: .bold))
                    Text("Пять самых ресурсоёмких процессов")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("Сортировка", selection: $store.sort) {
                ForEach(SystemProcessSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)

            if store.isWarmingUp {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Измеряем нагрузку…").font(.system(size: 13, weight: .medium))
                    Text("Для CPU нужны два замера с интервалом 2 секунды.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.topProcesses.isEmpty {
                ContentUnavailableView("Нет доступных процессов", systemImage: "chart.bar",
                                       description: Text("macOS не вернула доступные показания. Можно открыть системный «Мониторинг системы»."))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("Процесс")
                        Spacer()
                        Text("CPU").frame(width: 82, alignment: .trailing)
                        Text("Резидентная ОЗУ").frame(width: 125, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    ForEach(store.topProcesses) { process in
                        Divider()
                        HStack(spacing: 10) {
                            Image(systemName: "app.dashed").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("PID \(process.pid)").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(process.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—")
                                .frame(width: 82, alignment: .trailing)
                            Text(SystemMetricReading.bytes(process.residentMemoryBytes))
                                .frame(width: 125, alignment: .trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit()
                        .padding(.horizontal, 14).frame(height: 46)
                    }
                }
                .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("CPU: 100% — одно ядро, значение может быть выше. Резидентная ОЗУ включает общие страницы и отличается от столбца «Память» в macOS.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    if let snapshot = store.snapshot {
                        Text("Обновлено \(snapshot.sampledAt.formatted(date: .omitted, time: .standard)) · каждые 2 с")
                    } else { Text("Обновление каждые 2 секунды") }
                    Spacer()
                    if let count = store.snapshot?.skippedProcessCount, count > 0 {
                        Text("Недоступно: \(count)")
                            .help("Процессы завершились или macOS ограничила доступ к их показаниям.")
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let openError { Text(openError).font(.system(size: 11)).foregroundStyle(.red) }
                Button("Открыть Мониторинг системы", systemImage: "arrow.up.forward.app", action: openActivityMonitor)
                    .buttonStyle(.bordered).padding(.top, 3)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
    }

    private func openActivityMonitor() {
        openError = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            openError = "Не удалось найти «Мониторинг системы»."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if error != nil {
                Task { @MainActor in openError = "Не удалось открыть «Мониторинг системы»." }
            }
        }
    }
}
