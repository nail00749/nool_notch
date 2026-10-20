import AppKit
import NotchCore
import SwiftUI

// Mini widgets: device batteries, system load, AI limits and system toggles.
// One cell shows the single most useful value; wider cells add more gauges.
// Every data source polls only while a widget is on screen.

/// Ring gauge with an icon inside and a short value underneath.
struct DockMiniGauge<Center: View>: View {
    let fraction: Double?
    let color: Color
    let value: String
    var size: CGFloat = 28
    @ViewBuilder let center: () -> Center

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 3)
                if let fraction {
                    Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.35), value: fraction)
                }
                center().foregroundStyle(color)
            }.frame(width: size, height: size)
            Text(value)
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
    }
}

enum DockMiniWidgetLayout {
    /// How many gauges fit: one per cell, three at most.
    static func gaugeCount(span: Int, available: Int, maximum: Int = 3) -> Int {
        min(max(available, 0), min(max(span, 1), maximum))
    }

    static func levelColor(remaining fraction: Double) -> Color {
        fraction <= 0.15 ? .signalCoral : fraction <= 0.35 ? .signalAmber : .signalMint
    }

    static func loadColor(used fraction: Double) -> Color {
        fraction >= 0.9 ? .signalCoral : fraction >= 0.75 ? .signalAmber : .signalMint
    }
}

// MARK: - Batteries

struct DockBatteryWidget: View {
    let span: Int
    @ObservedObject var store: DeviceBatteryStore

    init(span: Int, store: DeviceBatteryStore = .shared) {
        self.span = span
        self.store = store
    }

    private var shown: [DeviceBattery] {
        Array(store.devices.prefix(DockMiniWidgetLayout.gaugeCount(span: span, available: store.devices.count)))
    }

    var body: some View {
        HStack(spacing: 4) {
            if shown.isEmpty {
                DockMiniGauge(fraction: nil, color: .white.opacity(0.5),
                              value: store.hasLoaded ? "нет" : "…") {
                    Image(systemName: "battery.0percent").font(.system(size: 11, weight: .medium))
                }
            } else if shown.count == 1, span > 1, let device = shown.first {
                // A lone device gets its name and details instead of empty space.
                gauge(device).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text(device.detail ?? "")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.56)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(shown) { device in gauge(device) }
            }
        }
        .padding(.horizontal, 6).dockWidgetSurface()
        .dockTapTarget("Заряд устройств") { Self.openBluetoothSettings() }
        .help(Self.tooltip(store.devices))
        .onAppear { store.beginViewing() }
        .onDisappear { store.endViewing() }
    }

    private func gauge(_ device: DeviceBattery) -> some View {
        DockMiniGauge(fraction: device.fraction,
                      color: DockMiniWidgetLayout.levelColor(remaining: device.fraction),
                      value: "\(device.percent)%") {
            ZStack(alignment: .topTrailing) {
                Image(systemName: device.kind.symbol).font(.system(size: 11, weight: .medium))
                if device.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: 6)).offset(x: 5, y: -4)
                }
            }
        }
    }

    static func tooltip(_ devices: [DeviceBattery]) -> String {
        guard devices.isEmpty == false else { return "Заряд устройств: нет данных" }
        return devices.map { device in
            "\(device.name): \(device.percent)%" + (device.detail.map { " (\($0))" } ?? "")
        }.joined(separator: "\n")
    }

    private static func openBluetoothSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - System load

@MainActor
final class DockSystemLoadStore: ObservableObject {
    static let shared = DockSystemLoadStore()

    @Published private(set) var snapshot: SystemMetricsSnapshot?

    private let sampler: any SystemMetricsSampling
    private let interval: TimeInterval
    private var viewers = 0
    private var asleep = false
    private var pollingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(sampler: any SystemMetricsSampling = SystemMetricsSampler(), interval: TimeInterval = 2) {
        self.sampler = sampler
        self.interval = interval
    }

    func beginViewing() {
        viewers += 1
        guard viewers == 1 else { return }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)
        ]
        observers = events.map { name, sleeping in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.asleep = sleeping
                    self?.reconcile()
                }
            }
        }
        reconcile()
    }

    func endViewing() {
        guard viewers > 0 else { return }
        viewers -= 1
        guard viewers == 0 else { return }
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        reconcile()
    }

    private func reconcile() {
        pollingTask?.cancel()
        pollingTask = nil
        guard viewers > 0, asleep == false else { return }
        let sampler = sampler
        let interval = interval
        pollingTask = Task { @MainActor [weak self] in
            // Rates need two samples; restart them after any pause.
            await sampler.reset()
            while Task.isCancelled == false {
                let next = await sampler.sample()
                guard Task.isCancelled == false else { return }
                self?.snapshot = next
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}

struct DockSystemLoadWidget: View {
    let span: Int
    @ObservedObject var store: DockSystemLoadStore

    init(span: Int, store: DockSystemLoadStore = .shared) {
        self.span = span
        self.store = store
    }

    static func metrics(span: Int) -> [SystemMonitorMetric] {
        switch span {
        case ...1: [.cpu]
        case 2: [.cpu, .memory]
        default: [.cpu, .memory, .disk, .network]
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.metrics(span: span)) { metric in
                let reading = SystemMetricReading(metric: metric, snapshot: store.snapshot)
                DockMiniGauge(fraction: reading.fraction,
                              color: reading.fraction.map(DockMiniWidgetLayout.loadColor) ?? .white.opacity(0.7),
                              value: metric == .network ? Self.compactRate(store.snapshot?.network) : reading.value) {
                    Image(systemName: metric.symbol).font(.system(size: 10, weight: .medium))
                }.help("\(metric.title): \(reading.value) — \(reading.detail)")
            }
        }
        .padding(.horizontal, 6).dockWidgetSurface()
        .dockTapTarget("Нагрузка системы") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
        .onAppear { store.beginViewing() }
        .onDisappear { store.endViewing() }
    }

    /// Download rate in at most four characters plus unit, e.g. "1.2M", "640K".
    static func compactRate(_ rate: SystemNetworkRate?) -> String {
        guard let value = rate?.receivedBytesPerSecond, value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "↓%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "↓%.0fK", value / 1_000) }
        return String(format: "↓%.0fB", value)
    }
}

// MARK: - AI limits

/// One provider line of the limits widget: the most constrained window wins.
struct DockQuotaSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let remaining: Double?
    let resetAt: Date?
    let windowLabel: String?
    let isConnected: Bool

    var percentText: String {
        guard isConnected else { return "—" }
        return remaining.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    static func summaries(snapshots: [String: QuotaSnapshot], order: [String],
                          hidden: Set<String>) -> [DockQuotaSummary] {
        let ordered = order + snapshots.keys.filter { !order.contains($0) }.sorted()
        return ordered.compactMap { id -> DockQuotaSummary? in
            guard hidden.contains(id) == false, let snapshot = snapshots[id] else { return nil }
            let tightest = snapshot.windows
                .filter { $0.remainingRatio != nil }
                .min { ($0.remainingRatio ?? 1) < ($1.remainingRatio ?? 1) }
            return DockQuotaSummary(
                id: id,
                name: snapshot.providerName,
                remaining: tightest?.remainingRatio,
                resetAt: tightest?.resetAt,
                windowLabel: tightest?.label,
                isConnected: snapshot.connection == .live || snapshot.connection == .stale
            )
        }
    }

    /// "2 ч", "3 д", "<1 ч" — fits under a 28 pt ring.
    static func shortReset(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60))) мин" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) ч" }
        return "\(Int(seconds / 86_400)) д"
    }
}

struct DockQuotaWidget: View {
    @ObservedObject var model: NotchViewModel
    let span: Int

    private var summaries: [DockQuotaSummary] {
        DockQuotaSummary.summaries(snapshots: model.snapshots, order: model.quotaProviderOrder,
                                   hidden: model.hiddenQuotaProviderIDs)
    }

    var body: some View {
        let all = summaries
        let shown = Array(all.prefix(DockMiniWidgetLayout.gaugeCount(span: span, available: all.count)))
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 4) {
                if shown.isEmpty {
                    DockMiniGauge(fraction: nil, color: .white.opacity(0.5), value: "нет") {
                        Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11))
                    }
                } else {
                    ForEach(shown) { summary in
                        let visuals = QuotaProviderVisuals(providerID: summary.id)
                        let reset = span > 1 ? DockQuotaSummary.shortReset(summary.resetAt, now: context.date) : nil
                        DockMiniGauge(fraction: summary.isConnected ? summary.remaining : nil,
                                      color: summary.remaining.map { $0 <= 0.15 ? Color.signalCoral : visuals.color }
                                          ?? visuals.color,
                                      value: [summary.percentText, reset].compactMap { $0 }.joined(separator: " · ")) {
                            QuotaProviderBrandIcon(providerID: summary.id, size: 13,
                                                   color: visuals.color)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6).dockWidgetSurface()
        .dockTapTarget("Лимиты AI") { model.openQuotaLimits() }
        .help(Self.tooltip(all, now: Date()))
    }

    static func tooltip(_ summaries: [DockQuotaSummary], now: Date) -> String {
        guard summaries.isEmpty == false else { return "Лимиты AI: нет подключённых провайдеров" }
        return summaries.map { summary in
            var line = "\(summary.name): осталось \(summary.percentText)"
            if let label = summary.windowLabel { line += " (\(label))" }
            if let reset = DockQuotaSummary.shortReset(summary.resetAt, now: now) { line += ", сброс через \(reset)" }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: - System toggles

enum DockSystemToggle: String, CaseIterable, Identifiable {
    case wifi, sound, darkMode, keepAwake, bluetooth
    var id: Self { self }

    var title: String {
        switch self {
        case .wifi: "Wi‑Fi"
        case .sound: "Звук"
        case .darkMode: "Тёмная тема"
        case .keepAwake: "Не засыпать"
        case .bluetooth: "Bluetooth"
        }
    }

    /// The closed tile previews these, like a folder icon previews its apps.
    static let preview: [DockSystemToggle] = [.wifi, .sound, .darkMode, .keepAwake]
    /// Tiles of the opened panel; sound gets its own slider row below them.
    static let panelTiles: [DockSystemToggle] = [.wifi, .bluetooth, .darkMode, .keepAwake]
}

/// Closed: a folder-like preview of the main toggles. A click opens a panel
/// with full controls; scrolling over the tile still changes the volume.
struct DockTogglesWidget: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var store: SystemTogglesStore
    @ObservedObject var appearance: DisplaySystemSettingsModel
    @ObservedObject var keepAwake: DisplayKeepAwakeModel
    let span: Int
    let interactionChanged: (Bool) -> Void
    @State private var showsPanel = false

    init(model: NotchViewModel, span: Int, store: SystemTogglesStore = .shared,
         interactionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.span = span
        self.store = store
        self.interactionChanged = interactionChanged
        appearance = model.displays.systemSettings
        keepAwake = model.displays.keepAwake
    }

    private var controls: DockToggleControls {
        DockToggleControls(store: store, appearance: appearance, keepAwake: keepAwake,
                           displaysEnabled: model.modules.isEnabled(.displays))
    }

    var body: some View {
        HStack(spacing: 9) {
            preview.frame(width: 42, height: 42)
            if span > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Управление").font(.system(size: 11, weight: .semibold))
                    Text(summary).font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                }.lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, span > 1 ? 8 : 0).dockWidgetSurface()
        .dockTapTarget("Управление системой") { showsPanel.toggle() }
        .background(DockScrollWheelReader { delta in
            store.adjustVolume(by: delta > 0 ? -1 : 1)
        })
        .help("Щелчок: открыть управление\nПрокрутка: громкость")
        .onAppear { store.beginViewing() }
        .onDisappear { store.endViewing() }
        .popover(isPresented: $showsPanel, arrowEdge: .top) {
            DockTogglesPanel(controls: controls)
                .onAppear { interactionChanged(true) }
                .onDisappear { interactionChanged(false) }
        }
    }

    private var preview: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { miniIcon(.wifi); miniIcon(.sound) }
            GridRow { miniIcon(.darkMode); miniIcon(.keepAwake) }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private func miniIcon(_ toggle: DockSystemToggle) -> some View {
        let state = controls.state(of: toggle)
        return ZStack {
            Circle().fill(state.isOn == true ? Color.accentColor : .white.opacity(0.12))
            Image(systemName: state.symbol).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: 16, height: 16)
        .opacity(state.isEnabled ? 1 : 0.4)
    }

    private var summary: String {
        var parts: [String] = []
        if let wifi = store.wifiOn { parts.append(wifi ? "Wi‑Fi" : "Wi‑Fi выкл.") }
        if let audio = store.audio {
            parts.append(audio.isMuted ? "без звука" : "звук \(Int((audio.volume * 100).rounded()))%")
        }
        return parts.isEmpty ? "Wi‑Fi, звук, тема" : parts.joined(separator: " · ")
    }
}

/// State and actions shared by the closed preview and the open panel.
struct DockToggleControls {
    let store: SystemTogglesStore
    let appearance: DisplaySystemSettingsModel
    let keepAwake: DisplayKeepAwakeModel
    let displaysEnabled: Bool

    struct State {
        let isOn: Bool?
        let isEnabled: Bool
        let symbol: String
        let status: String
    }

    @MainActor
    func state(of toggle: DockSystemToggle) -> State {
        switch toggle {
        case .wifi:
            let on = store.wifiOn
            return State(isOn: on, isEnabled: on != nil, symbol: on == false ? "wifi.slash" : "wifi",
                         status: on.map { $0 ? "Вкл." : "Выкл." } ?? "Нет Wi‑Fi")
        case .sound:
            let audio = store.audio
            let muted = audio?.isMuted ?? false
            let volume = audio?.volume ?? 0
            let symbol = muted || volume == 0 ? "speaker.slash.fill"
                : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            return State(isOn: audio.map { !$0.isMuted }, isEnabled: audio?.canMute == true, symbol: symbol,
                         status: audio.map { $0.isMuted ? "Без звука" : "\(Int(($0.volume * 100).rounded()))%" } ?? "Нет выхода")
        case .darkMode:
            let dark = displaysEnabled ? appearance.darkMode.value : nil
            return State(isOn: dark, isEnabled: dark != nil && !appearance.isBusy,
                         symbol: dark == true ? "moon.fill" : "sun.max.fill",
                         status: displaysEnabled ? (dark.map { $0 ? "Вкл." : "Выкл." } ?? "Проверяем…")
                                                 : "Модуль «Дисплеи» выключен")
        case .keepAwake:
            let active = keepAwake.isActive
            let until = keepAwake.expiresAt.map { "до " + $0.formatted(date: .omitted, time: .shortened) }
            return State(isOn: active, isEnabled: displaysEnabled,
                         symbol: active ? "cup.and.saucer.fill" : "cup.and.saucer",
                         status: displaysEnabled ? (active ? (until ?? "Вкл.") : "Выкл.") : "Модуль «Дисплеи» выключен")
        case .bluetooth:
            return State(isOn: nil, isEnabled: true, symbol: "dot.radiowaves.left.and.right", status: "Настройки")
        }
    }

    @MainActor
    func perform(_ toggle: DockSystemToggle) {
        switch toggle {
        case .wifi: store.toggleWiFi()
        case .sound: store.toggleMute()
        case .darkMode:
            guard let dark = appearance.darkMode.value else { return }
            Task { await appearance.setDarkMode(!dark) }
        case .keepAwake:
            if keepAwake.isActive { keepAwake.stop() } else { keepAwake.start(minutes: nil) }
        case .bluetooth:
            if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// The opened panel: Control Center-like tiles plus a volume slider.
struct DockTogglesPanel: View {
    let controls: DockToggleControls
    @ObservedObject private var store: SystemTogglesStore
    @ObservedObject private var appearance: DisplaySystemSettingsModel
    @ObservedObject private var keepAwake: DisplayKeepAwakeModel

    init(controls: DockToggleControls) {
        self.controls = controls
        store = controls.store
        appearance = controls.appearance
        keepAwake = controls.keepAwake
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(.wifi); tile(.bluetooth) }
                GridRow { tile(.darkMode); tile(.keepAwake) }
            }
            soundRow
            if let error = store.errorMessage ?? appearance.errorMessage ?? keepAwake.errorMessage {
                Text(error).font(.system(size: 10)).foregroundStyle(Color.signalAmber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(width: 330).preferredColorScheme(.dark)
        .onAppear { store.beginViewing() }
        .onDisappear { store.endViewing() }
    }

    private func tile(_ toggle: DockSystemToggle) -> some View {
        let state = controls.state(of: toggle)
        return Button { controls.perform(toggle) } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(state.isOn == true ? Color.accentColor : .white.opacity(0.12))
                    Image(systemName: state.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(toggle.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(state.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.56))
                }.lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: state.isOn)
        .accessibilityLabel("\(toggle.title): \(state.status)")
    }

    private var soundRow: some View {
        let state = controls.state(of: .sound)
        let audio = store.audio
        return HStack(spacing: 9) {
            Button { controls.perform(.sound) } label: {
                Image(systemName: state.symbol).font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.12)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain).disabled(!state.isEnabled)
            .accessibilityLabel(audio?.isMuted == true ? "Включить звук" : "Выключить звук")
            Slider(value: Binding(get: { audio?.isMuted == true ? 0 : audio?.volume ?? 0 },
                                  set: { store.setVolume($0) }), in: 0...1)
                .controlSize(.small)
                .disabled(audio?.canSetVolume != true)
                .accessibilityLabel("Громкость")
            Text(state.status).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.56))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(8)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
