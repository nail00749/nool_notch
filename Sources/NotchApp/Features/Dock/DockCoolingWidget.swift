import AppKit
import NoolCoolingCore
import SwiftUI

/// A presentation of the shared cooling session. Native window visibility owns
/// its telemetry subscription; hiding the Dock never releases active fan control.
struct DockCoolingWidget: View {
    @ObservedObject var store: CoolingStore
    let span: Int
    let interactionChanged: (Bool) -> Void
    let arrowEdge: Edge
    let dismissalEpoch: Int
    let openFullPanel: () -> Void
    @State private var showsDetails = false
    @StateObject private var observation: DockCoolingObservation

    init(store: CoolingStore = .shared, span: Int,
         interactionChanged: @escaping (Bool) -> Void = { _ in },
         arrowEdge: Edge = .top, dismissalEpoch: Int = 0,
         openFullPanel: @escaping () -> Void = { CoolingWindowCoordinator.shared.show() }) {
        self.store = store
        self.span = span
        self.interactionChanged = interactionChanged
        self.arrowEdge = arrowEdge
        self.dismissalEpoch = dismissalEpoch
        self.openFullPanel = openFullPanel
        _observation = StateObject(wrappedValue: DockCoolingObservation(store: store))
    }

    private var reading: DockCoolingReading { DockCoolingReading(snapshot: store.snapshot) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 2) {
                CoolingRotor(rpm: reading.fastestRPM ?? 0, fraction: reading.fastestFraction)
                    .frame(width: span > 1 ? 36 : 33, height: span > 1 ? 36 : 33)
                if span == 1 {
                    Text(reading.temperatureText).font(.system(size: 9, weight: .medium))
                        .monospacedDigit().foregroundStyle(.white.opacity(0.8))
                }
            }
            if span > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Охлаждение").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        if span > 2 {
                            Spacer(minLength: 0)
                            Text(reading.temperatureText).font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.76))
                        }
                    }
                    Text(span > 2 ? reading.fanSummary : reading.compactSummary)
                        .font(.system(size: 9)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.62))
                }
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, span > 1 ? 8 : 0)
        .dockWidgetSurface()
        .dockTapTarget("Охлаждение — обороты и температуры") { showsDetails.toggle() }
        .help(reading.accessibilitySummary)
        .background { DockCoolingVisibilityProbe(observation: observation).allowsHitTesting(false) }
        .dockPopover(isPresented: $showsDetails, arrowEdge: arrowEdge) {
            DockCoolingDetails(store: store) {
                showsDetails = false
                openFullPanel()
            }
        }
        .onChange(of: showsDetails) { _, visible in interactionChanged(visible) }
        .onChange(of: dismissalEpoch) { _, _ in showsDetails = false }
        .onChange(of: arrowEdge) { _, _ in showsDetails = false }
        .onDisappear {
            showsDetails = false
            observation.setVisible(false)
            interactionChanged(false)
        }
    }
}

struct DockCoolingReading: Equatable {
    let fastestRPM: Double?
    let fastestFraction: Double
    let temperature: Double?
    let fans: [CoolingFan]
    let hasSnapshot: Bool

    init(snapshot: CoolingSnapshot?) {
        hasSnapshot = snapshot != nil
        fans = snapshot?.fans ?? []
        let validFans = fans.filter { $0.currentRPM.isFinite && $0.currentRPM >= 0 }
        fastestRPM = validFans.map(\.currentRPM).max()
        fastestFraction = validFans.compactMap { fan -> Double? in
            guard fan.maximumRPM.isFinite, fan.maximumRPM > 0 else { return nil }
            return min(1, max(0, fan.currentRPM / fan.maximumRPM))
        }.max() ?? 0
        temperature = snapshot?.sensors.lazy.filter { $0.controlEligible && $0.celsius.isFinite }
            .map(\.celsius).max()
    }

    var temperatureText: String { temperature.map { String(format: "%.0f°", $0) } ?? "—°" }
    var compactSummary: String {
        guard let fastestRPM else { return hasSnapshot ? "Без вентиляторов" : "Собираем данные…" }
        return "\(CoolingPanel.rpm(fastestRPM)) RPM · \(temperatureText)"
    }
    var fanSummary: String {
        guard !fans.isEmpty else { return compactSummary }
        return fans.prefix(2).map { "\(CoolingPanel.fanName($0).prefix(1)) \(CoolingPanel.rpm($0.currentRPM))" }.joined(separator: " · ") + " RPM"
    }
    var accessibilitySummary: String {
        guard hasSnapshot else { return "Охлаждение · собираем данные" }
        let details = fans.map { "\(CoolingPanel.fanName($0)): \(CoolingPanel.rpm($0.currentRPM)) RPM, \(CoolingPanel.modeTitle($0.mode))" }
        return (["Охлаждение"] + details + ["CPU/GPU: \(temperatureText)"]).joined(separator: "\n")
    }
}

struct DockCoolingDetails: View {
    @ObservedObject var store: CoolingStore
    let openFullPanel: () -> Void
    @State private var manualExpanded = false
    @State private var percent = 50.0
    @State private var manualSource = UUID()
    @State private var boostDuration = 180.0

    private var targets: [CoolingFan] { DockCoolingQuickActions.targets(store.snapshot) }
    private var fanIDs: [Int] { targets.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Охлаждение").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: openFullPanel) { Image(systemName: "arrow.up.right.square").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Открыть управление вентиляторами")
                    .accessibilityLabel("Открыть управление вентиляторами")
            }
            if let snapshot = store.snapshot {
                if snapshot.fans.isEmpty {
                    Text("Вентиляторы не обнаружены").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(snapshot.fans) { fan in
                                HStack(spacing: 12) {
                                    CoolingRotor(rpm: fan.currentRPM, fraction: fan.maximumRPM > 0 ? fan.currentRPM / fan.maximumRPM : 0)
                                        .frame(width: 40, height: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(CoolingPanel.fanName(fan)).font(.system(size: 12, weight: .medium))
                                        Text(CoolingPanel.modeTitle(fan.mode)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(CoolingPanel.rpm(fan.currentRPM)).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
                                    Text("RPM").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.frame(height: min(248, CGFloat(snapshot.fans.count) * 52 - 12))
                }
                if let hottest = snapshot.sensors.filter({ $0.controlEligible }).max(by: { $0.celsius < $1.celsius }) {
                    Divider()
                    HStack {
                        Text(hottest.name).lineLimit(1)
                        Spacer()
                        Text(CoolingPanel.temperature(hottest.celsius)).monospacedDigit()
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Собираем данные…").font(.system(size: 11)) }
            }
            if !targets.isEmpty {
                Divider()
                quickActions
            }
            if let message = store.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Для всех вентиляторов").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Настройки…", action: openFullPanel)
            }.controlSize(.small)
        }
        .padding(18).frame(width: 330)
        .background(NotchPalette.surface).foregroundStyle(NotchPalette.text)
        // A popover is a second visible surface; keep its lease independent of
        // the Dock window's occlusion so opening it cannot stop telemetry.
        .onAppear {
            store.startObserving()
            percent = DockCoolingQuickActions.manualPercent(store.snapshot)
            manualExpanded = !targets.isEmpty && targets.allSatisfy { $0.mode == .manual }
        }
        .onChange(of: fanIDs) { _, _ in store.cancelPendingManual(sourceID: manualSource) }
        .onDisappear {
            store.cancelPendingManual(sourceID: manualSource)
            store.stopObserving()
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    manualExpanded = false
                    store.cancelPendingManual(sourceID: manualSource)
                    store.allAutomatic()
                } label: { Label("Авто", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                Button {
                    percent = DockCoolingQuickActions.manualPercent(store.snapshot)
                    manualExpanded = true
                    store.apply(fanIDs: fanIDs, mode: .manual, percent: percent)
                } label: { Label("Вручную", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(!store.canControl)
            HStack(spacing: 8) {
                Button {
                    manualExpanded = false
                    store.cancelPendingManual(sourceID: manualSource)
                    store.apply(fanIDs: fanIDs, mode: .boost, duration: boostDuration)
                } label: { Label("Охладить", systemImage: "snowflake").frame(maxWidth: .infinity) }
                .disabled(!store.canControl)
                Picker("Время охлаждения", selection: $boostDuration) {
                    Text("1 мин").tag(60.0)
                    Text("3 мин").tag(180.0)
                    Text("5 мин").tag(300.0)
                }.labelsHidden().frame(width: 83)
                Button("Кривая…") {
                    store.cancelPendingManual(sourceID: manualSource)
                    openFullPanel()
                }.help("Настроить датчик и температурную кривую в полном окне")
            }.buttonStyle(.bordered).controlSize(.small)
            if manualExpanded {
                HStack {
                    Text("Общая скорость").font(.system(size: 11))
                    Spacer()
                    Text("\(Int(percent.rounded()))% диапазона").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { percent }, set: { value in
                    percent = value
                    store.scheduleManual(fanIDs: fanIDs, percent: value, sourceID: manualSource)
                }), in: 0...100).tint(.teal).disabled(!store.canControl)
                    .accessibilityLabel("Общая скорость вентиляторов")
                Text("Применяется автоматически. 0% — минимальные обороты.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

enum DockCoolingQuickActions {
    static func targets(_ snapshot: CoolingSnapshot?) -> [CoolingFan] {
        (snapshot?.fans ?? []).filter { $0.controlSupported }
    }

    /// Entering manual mode must not unexpectedly slow the faster fan. Use the
    /// highest current level relative to each fan's own supported RPM range.
    static func manualPercent(_ snapshot: CoolingSnapshot?) -> Double {
        targets(snapshot).compactMap { fan -> Double? in
            guard fan.currentRPM.isFinite, fan.minimumRPM.isFinite, fan.maximumRPM.isFinite,
                  fan.maximumRPM > fan.minimumRPM else { return nil }
            return min(100, max(0, (fan.currentRPM - fan.minimumRPM) / (fan.maximumRPM - fan.minimumRPM) * 100))
        }.max() ?? 50
    }
}

@MainActor
final class DockCoolingObservation: ObservableObject {
    private let store: CoolingStore
    private(set) var isViewing = false
    init(store: CoolingStore) { self.store = store }
    func setVisible(_ visible: Bool) {
        guard isViewing != visible else { return }
        isViewing = visible
        if visible { store.startObserving() } else { store.stopObserving() }
    }
}

private struct DockCoolingVisibilityProbe: NSViewRepresentable {
    let observation: DockCoolingObservation
    func makeNSView(context: Context) -> DockCoolingVisibilityNSView { DockCoolingVisibilityNSView(observation: observation) }
    func updateNSView(_ view: DockCoolingVisibilityNSView, context: Context) { view.visibilityChanged() }
    static func dismantleNSView(_ view: DockCoolingVisibilityNSView, coordinator: ()) { view.stopAnimations() }
}

final class DockCoolingVisibilityNSView: DockMusicAnimationNSView {
    private let observation: DockCoolingObservation
    init(observation: DockCoolingObservation) { self.observation = observation; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func visibilityChanged() { observation.setVisible(animationIsVisible) }
    override func stopAnimations() { observation.setVisible(false) }
}
