import AppKit
import NoolCoolingCore
import SwiftUI

/// Slider edits apply after a short pause; polling and draft selection never
/// issue hardware commands. A curve remains an explicit, validated draft.
struct CoolingPanel: View {
    @ObservedObject var store: CoolingStore
    @State private var selectedFanID: Int?
    @State private var linked = false
    @State private var mode: CoolingControlMode = .automatic
    @State private var percent = 50.0
    @State private var duration = 180.0
    @State private var sensorID = ""
    @State private var curve = Self.defaultCurve
    @State private var showSensors = false
    @State private var manualSourceID = UUID()

    static let defaultCurve: [CoolingCurvePoint] = [
        .init(temperature: 45, percent: 0), .init(temperature: 60, percent: 30),
        .init(temperature: 75, percent: 65), .init(temperature: 90, percent: 100)
    ]

    private var fans: [CoolingFan] { store.snapshot?.fans ?? [] }
    private var sensors: [CoolingSensor] { store.snapshot?.sensors ?? [] }
    private var curveSensors: [CoolingSensor] { sensors.filter(\.controlEligible) }
    private var selectedFan: CoolingFan? { fans.first { $0.id == selectedFanID } }
    private var fanIDs: [Int] { linked ? fans.filter(\.controlSupported).map(\.id) : selectedFan.map { [$0.id] } ?? [] }
    private var controllable: Bool { store.canControl && !fanIDs.isEmpty && (linked || selectedFan?.controlSupported == true) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    serviceNotice
                    if fans.isEmpty { emptyFans } else {
                        fanOverview
                        controlEditor
                    }
                    if !sensors.isEmpty { temperatures }
                }
                .padding(24)
            }
            footer
        }
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .frame(minWidth: 530, minHeight: 540)
        .onAppear { store.startObserving(); synchronizeSelection() }
        .onDisappear { store.cancelPendingManual(sourceID: manualSourceID); store.stopObserving() }
        .onChange(of: mode) { _, _ in store.cancelPendingManual(sourceID: manualSourceID) }
        .onChange(of: selectedFanID) { _, _ in store.cancelPendingManual(sourceID: manualSourceID) }
        .onChange(of: fans.map(\.id)) { _, _ in
            store.cancelPendingManual(sourceID: manualSourceID)
            synchronizeSelection()
        }
        .onChange(of: curveSensors.map(\.id)) { _, _ in
            if !curveSensors.contains(where: { $0.id == sensorID }) { sensorID = curveSensors.first?.id ?? "" }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 21, weight: .medium)).foregroundStyle(.teal)
                .frame(width: 42, height: 42)
                .background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Охлаждение").font(.system(size: 20, weight: .semibold))
                Text("Вентиляторы и температура Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { mode = .automatic; store.allAutomatic() } label: {
                Label("Всё в авто", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small).disabled(!store.canControl)
            .help("Вернуть все вентиляторы под управление macOS")
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    @ViewBuilder private var serviceNotice: some View {
        if store.status != .enabled || store.message != nil || store.snapshot?.notice != nil {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: store.status == .requiresApproval ? "lock.shield" : "info.circle")
                    .foregroundStyle(.secondary).font(.system(size: 15)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 7) {
                    Text(store.message ?? store.snapshot?.notice ?? "Для изменения оборотов включите управление охлаждением.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.status == .requiresApproval {
                        Button("Разрешить в настройках macOS") { store.openApprovalSettings() }
                            .controlSize(.small)
                    } else if store.status == .notInstalled {
                        Button("Включить управление") { store.enableControl() }
                            .controlSize(.small).disabled(store.isBusy)
                    }
                }
                Spacer(minLength: 0)
                if store.isBusy { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var fanOverview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(2, max(1, fans.count))), spacing: 12) {
            ForEach(fans) { fan in
                if linked {
                    CoolingFanOverview(fan: fan)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(Self.fanName(fan)), \(Self.rpm(fan.currentRPM)) оборотов в минуту, \(Self.modeTitle(fan.mode))")
                } else {
                    Button {
                        selectedFanID = fan.id
                        loadDraft(fan)
                    } label: {
                        CoolingFanOverview(fan: fan, selected: selectedFanID == fan.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.fanName(fan)), \(Self.rpm(fan.currentRPM)) оборотов в минуту, \(Self.modeTitle(fan.mode))")
                    .accessibilityAddTraits(selectedFanID == fan.id ? .isSelected : [])
                }
            }
        }
    }

    private var controlEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(linked ? "Общее управление" : selectedFan.map(Self.fanName) ?? "Управление")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if fans.count > 1 {
                    Toggle(isOn: linkedBinding) { Label("Связать", systemImage: "link") }
                        .toggleStyle(.checkbox).font(.system(size: 11))
                        .help("Одинаковый процент диапазона для всех доступных вентиляторов")
                }
            }
            Picker("Режим охлаждения", selection: $mode) {
                ForEach(CoolingControlMode.allCases, id: \.self) { mode in
                    Text(Self.modeTitle(mode)).tag(mode)
                }
            }.pickerStyle(.segmented).labelsHidden()

            Group {
                switch mode {
                case .automatic: automaticEditor
                case .manual: manualEditor
                case .boost: boostEditor
                case .curve: curveEditor
                }
            }
            .disabled(!controllable || (mode != .manual && store.isBusy))

            if !controllable && store.status == .enabled {
                Text("На этом устройстве изменение оборотов недоступно.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var automaticEditor: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Скорость выбирает macOS").font(.system(size: 12, weight: .medium))
                Text("Система подстраивает охлаждение под нагрузку и температуру.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            applyButton("Передать macOS")
        }.padding(.vertical, 5)
    }

    private var manualEditor: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(linked ? "Скорость в диапазоне" : "Целевые обороты").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(linked ? "\(Int(percent))%" : selectedFan.map { Self.rpm(targetRPM($0)) + " RPM" } ?? "—")
                    .font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.blue)
            }
            Slider(value: Binding(get: { percent }, set: { value in
                percent = value
                store.scheduleManual(fanIDs: fanIDs, percent: value, sourceID: manualSourceID)
            }), in: 0...100).tint(.blue)
                .accessibilityLabel("Целевая скорость вентилятора")
                .accessibilityValue("\(Int(percent)) процентов диапазона")
            HStack {
                Text(linked ? "Минимум" : selectedFan.map { Self.rpm($0.minimumRPM) } ?? "—")
                Spacer()
                Text("\(Int(percent))% диапазона")
                Spacer()
                Text(linked ? "Максимум" : selectedFan.map { Self.rpm($0.maximumRPM) } ?? "—")
            }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            HStack {
                Text(linked ? "Каждый вентилятор использует свой диапазон оборотов." : "Показания выше — фактическая скорость.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("Применяется автоматически после изменения слайдера.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var boostEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "snowflake").font(.system(size: 25, weight: .light)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Быстро охладить Mac").font(.system(size: 12, weight: .medium))
                    Text("Максимальные обороты на выбранное время, затем автоматический режим.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Picker("Время", selection: $duration) {
                    Text("1 мин").tag(60.0)
                    Text("3 мин").tag(180.0)
                    Text("5 мин").tag(300.0)
                    Text("10 мин").tag(600.0)
                }.frame(width: 175)
                Spacer()
                applyButton("Охладить")
            }
            if let endsAt = selectedFan?.boostEndsAt, endsAt > Date() {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                    Text("До возврата в авто:")
                    Text(endsAt, style: .timer).monospacedDigit()
                }.font(.system(size: 11)).foregroundStyle(.teal)
            }
        }
    }

    private var curveEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if curveSensors.isEmpty {
                Text("Для кривой нужен датчик с подтверждённым назначением. Доступные температуры можно просматривать ниже.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Picker("Датчик", selection: $sensorID) {
                    ForEach(curveSensors) { sensor in Text(sensor.name).tag(sensor.id) }
                }.font(.system(size: 11))
                CoolingCurveChart(points: curve, currentTemperature: curveSensors.first { $0.id == sensorID }?.celsius)
                    .frame(height: 105)
                HStack {
                    Text("Температура").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Скорость в диапазоне").frame(maxWidth: .infinity, alignment: .trailing)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(curve.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Stepper(value: $curve[index].temperature, in: temperatureRange(index), step: 1) {
                            Text("\(Int(curve[index].temperature)) °C").monospacedDigit().frame(width: 49, alignment: .leading)
                        }.frame(width: 108)
                        Slider(value: $curve[index].percent, in: percentRange(index))
                            .accessibilityLabel("Скорость при \(Int(curve[index].temperature)) градусах")
                        Text("\(Int(curve[index].percent))%")
                            .monospacedDigit().frame(width: 35, alignment: .trailing)
                    }.font(.system(size: 11))
                }
                HStack {
                    Text("0% — минимальные обороты.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    applyButton("Применить кривую")
                }
            }
        }
    }

    private var temperatures: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Label("Температура", systemImage: "thermometer.medium")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("2 минуты").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            CoolingTemperatureHistory(samples: store.history, sensorID: graphSensor?.id)
                .frame(height: 70)
            let visibleSensors = showSensors ? sensors : Array(sensors.prefix(4))
            ForEach(visibleSensors) { sensor in
                HStack {
                    Text(sensor.name).lineLimit(1)
                    Spacer()
                    Text(Self.temperature(sensor.celsius)).fontWeight(.medium).monospacedDigit()
                }.font(.system(size: 11))
            }
            if sensors.count > 4 {
                Button(showSensors ? "Скрыть дополнительные датчики" : "Все датчики (\(sensors.count))") { showSensors.toggle() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let sensor = graphSensor {
                Text("На графике: \(sensor.name)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private var graphSensor: CoolingSensor? { sensors.first { $0.id == sensorID } ?? sensors.first }

    private var emptyFans: some View {
        VStack(spacing: 10) {
            Image(systemName: "fanblades").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(store.snapshot == nil ? "Считываем датчики…" : "Вентиляторы не обнаружены")
                .font(.system(size: 14, weight: .medium))
            Text(store.snapshot == nil ? "Показания появятся через несколько секунд." : "На Mac без активного охлаждения доступен только мониторинг температур.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
            Text("При потере связи управление возвращается macOS.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if store.isBusy { ProgressView().controlSize(.mini) }
            Menu {
                Button("Разрешения macOS") { store.openApprovalSettings() }
                Button("Отключить управление") { store.uninstallControl() }
                    .disabled(store.status != .enabled && store.status != .requiresApproval)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Настройки управления охлаждением")
        }.padding(.horizontal, 24).padding(.vertical, 12).background(NotchPalette.raised.opacity(0.45))
    }

    private func applyButton(_ title: String) -> some View {
        Button(title) {
            store.apply(fanIDs: fanIDs, mode: mode, percent: mode == .manual ? percent : nil,
                        duration: mode == .boost ? duration : nil,
                        sensorID: mode == .curve ? sensorID : nil, curve: mode == .curve ? curve : nil)
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(fanIDs.isEmpty || (mode == .curve && !curveSensors.contains { $0.id == sensorID }))
    }

    private var linkedBinding: Binding<Bool> {
        Binding(get: { linked }, set: { enabled in
            store.cancelPendingManual(sourceID: manualSourceID)
            linked = enabled
            // This is an explicit user action. Joining an already manual fan
            // applies that same range percentage to every supported fan.
            if enabled, mode == .manual {
                store.scheduleManual(fanIDs: fans.filter(\.controlSupported).map(\.id),
                                     percent: percent, sourceID: manualSourceID)
            }
        })
    }

    private func synchronizeSelection() {
        guard selectedFan == nil, let fan = fans.first else { return }
        selectedFanID = fan.id
        loadDraft(fan)
    }

    private func loadDraft(_ fan: CoolingFan) {
        mode = fan.mode
        percent = fan.targetPercent ?? 50
        sensorID = fan.sensorID.flatMap { id in curveSensors.contains(where: { $0.id == id }) ? id : nil }
            ?? curveSensors.first?.id ?? ""
        curve = fan.curve ?? Self.defaultCurve
    }

    private func targetRPM(_ fan: CoolingFan) -> Double {
        fan.minimumRPM + (fan.maximumRPM - fan.minimumRPM) * percent / 100
    }

    private func temperatureRange(_ index: Int) -> ClosedRange<Double> {
        let lower = index == 0 ? 20 : curve[index - 1].temperature + 1
        let upper = index == curve.count - 1 ? 110 : curve[index + 1].temperature - 1
        return lower...max(lower, upper)
    }

    private func percentRange(_ index: Int) -> ClosedRange<Double> {
        let lower = index == 0 ? 0 : curve[index - 1].percent
        let upper = index == curve.count - 1 ? 100 : curve[index + 1].percent
        return lower...max(lower, upper)
    }

    static func rpm(_ value: Double) -> String { value.isFinite && value >= 0 ? String(format: "%.0f", value) : "—" }
    static func temperature(_ value: Double) -> String { value.isFinite ? String(format: "%.1f °C", value) : "—" }
    static func fanName(_ fan: CoolingFan) -> String {
        switch fan.name.lowercased() { case "left": "Левый"; case "right": "Правый"; default: fan.name }
    }
    static func modeTitle(_ mode: CoolingControlMode) -> String {
        switch mode { case .automatic: "Авто"; case .manual: "Вручную"; case .boost: "Охладить"; case .curve: "Кривая" }
    }
}

struct CoolingFanOverview: View {
    let fan: CoolingFan
    var selected = false

    private var fraction: Double {
        guard fan.currentRPM.isFinite, fan.maximumRPM.isFinite, fan.maximumRPM > 0 else { return 0 }
        return min(1, max(0, fan.currentRPM / fan.maximumRPM))
    }

    var body: some View {
        HStack(spacing: 13) {
            CoolingRotor(rpm: fan.currentRPM, fraction: fraction)
                .frame(width: 57, height: 57)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(CoolingPanel.fanName(fan)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(CoolingPanel.rpm(fan.currentRPM)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("RPM").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(CoolingPanel.modeTitle(fan.mode)).font(.system(size: 10)).foregroundStyle(fan.mode == .automatic ? Color.secondary : Color.teal)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.teal.opacity(0.075) : NotchPalette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? Color.teal.opacity(0.45) : NotchPalette.separator.opacity(0.3), lineWidth: 1) }
        .help("Фактические обороты; процент от максимальной скорости вентилятора")
    }
}

struct CoolingCurveChart: View {
    let points: [CoolingCurvePoint]
    var currentTemperature: Double?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 22, y: 16, width: max(1, size.width - 40), height: max(1, size.height - 35))
            func position(_ point: CoolingCurvePoint) -> CGPoint {
                .init(x: rect.minX + CGFloat((point.temperature - 20) / 90) * rect.width,
                      y: rect.maxY - CGFloat(point.percent / 100) * rect.height)
            }
            for percent in [0.0, 50, 100] {
                let y = rect.maxY - CGFloat(percent / 100) * rect.height
                var guide = Path(); guide.move(to: .init(x: rect.minX, y: y)); guide.addLine(to: .init(x: rect.maxX, y: y))
                context.stroke(guide, with: .color(.secondary.opacity(0.17)), style: .init(lineWidth: 0.6, dash: [3, 4]))
            }
            let positions = points.filter { $0.temperature.isFinite && $0.percent.isFinite }.map(position)
            if let first = positions.first, let last = positions.last {
                var line = Path(); line.addLines(positions)
                var area = line
                area.addLine(to: .init(x: last.x, y: rect.maxY)); area.addLine(to: .init(x: first.x, y: rect.maxY)); area.closeSubpath()
                context.fill(area, with: .color(.teal.opacity(0.09)))
                context.stroke(line, with: .color(.teal), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for point in positions {
                    context.fill(Path(ellipseIn: .init(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.teal))
                }
            }
            if let currentTemperature, currentTemperature.isFinite {
                let x = rect.minX + CGFloat(min(1, max(0, (currentTemperature - 20) / 90))) * rect.width
                var marker = Path(); marker.move(to: .init(x: x, y: rect.minY)); marker.addLine(to: .init(x: x, y: rect.maxY))
                context.stroke(marker, with: .color(.orange.opacity(0.8)), style: .init(lineWidth: 1, dash: [2, 3]))
            }
            context.draw(Text("20 °C").font(.system(size: 8)).foregroundColor(.secondary), at: .init(x: rect.minX, y: size.height - 4), anchor: .bottomLeading)
            context.draw(Text("110 °C").font(.system(size: 8)).foregroundColor(.secondary), at: .init(x: rect.maxX, y: size.height - 4), anchor: .bottomTrailing)
            context.draw(Text("100%").font(.system(size: 8)).foregroundColor(.secondary), at: .init(x: rect.maxX, y: rect.minY - 2), anchor: .bottomTrailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Температурная кривая: " + points.map { "\(Int($0.temperature)) градусов — \(Int($0.percent)) процентов" }.joined(separator: ", "))
    }
}

private struct CoolingTemperatureHistory: View {
    let samples: [CoolingSnapshot]
    let sensorID: String?

    var body: some View {
        Canvas { context, size in
            let bottom = size.height - 5
            let top: CGFloat = 7
            var guide = Path(); guide.move(to: .init(x: 0, y: top)); guide.addLine(to: .init(x: size.width, y: top))
            context.stroke(guide, with: .color(.secondary.opacity(0.2)), style: .init(lineWidth: 0.6, dash: [3, 4]))
            guard let end = samples.last?.sampledAt, let sensorID else { return }
            let start = end.addingTimeInterval(-120)
            var segments: [[CGPoint]] = []; var points: [CGPoint] = []; var previous: Date?
            for sample in samples where sample.sampledAt >= start {
                guard let value = sample.sensors.first(where: { $0.id == sensorID })?.celsius, value.isFinite else {
                    if !points.isEmpty { segments.append(points); points = [] }; previous = nil; continue
                }
                if let previous, sample.sampledAt.timeIntervalSince(previous) > 10, !points.isEmpty { segments.append(points); points = [] }
                points.append(.init(x: CGFloat(sample.sampledAt.timeIntervalSince(start) / 120) * size.width,
                                    y: bottom - CGFloat(min(1, max(0, value / 120))) * (bottom - top)))
                previous = sample.sampledAt
            }
            if !points.isEmpty { segments.append(points) }
            for points in segments {
                guard let first = points.first, let last = points.last else { continue }
                var line = Path(); line.addLines(points)
                var area = line; area.addLine(to: .init(x: last.x, y: bottom)); area.addLine(to: .init(x: first.x, y: bottom)); area.closeSubpath()
                context.fill(area, with: .linearGradient(.init(colors: [.orange.opacity(0.16), .orange.opacity(0.01)]), startPoint: .zero, endPoint: .init(x: 0, y: bottom)))
                context.stroke(line, with: .color(.orange), style: .init(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            }
        }
        .overlay(alignment: .topLeading) { Text("120 °C").font(.system(size: 8)).foregroundStyle(.secondary) }
        .overlay {
            if samples.count < 2 { Text("Собираем историю…").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .accessibilityLabel("История температуры за две минуты")
    }
}

struct CoolingRotor: NSViewRepresentable {
    let rpm: Double
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CoolingRotorNSView { CoolingRotorNSView() }
    func updateNSView(_ view: CoolingRotorNSView, context: Context) { view.configure(rpm: rpm, fraction: fraction, reduceMotion: reduceMotion) }
    static func dismantleNSView(_ view: CoolingRotorNSView, coordinator: ()) { view.stopAnimations() }
}

final class CoolingRotorNSView: DockMusicAnimationNSView {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let rotor = CAShapeLayer()
    private let hub = CAShapeLayer()
    private var rpm = 0.0
    private var fraction = 0.0
    private var reduceMotion = false
    private var animationDuration: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.fillColor = nil; track.lineWidth = 2
        progress.fillColor = nil; progress.lineWidth = 2; progress.lineCap = .round
        [track, progress, rotor, hub].forEach { layer?.addSublayer($0) }
        setAccessibilityElement(false)
    }
    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(rpm: Double, fraction: Double, reduceMotion: Bool) {
        self.rpm = rpm.isFinite ? max(0, rpm) : 0
        self.fraction = min(1, max(0, fraction))
        self.reduceMotion = reduceMotion
        needsLayout = true
        updateAnimation()
    }
    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        let circle = CGRect(x: 2, y: 2, width: max(0, side - 4), height: max(0, side - 4))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = bounds; progress.frame = bounds
        let ring = CGPath(ellipseIn: circle, transform: nil)
        track.path = ring; track.strokeColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        progress.path = ring; progress.strokeColor = NSColor.systemTeal.cgColor
        progress.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        progress.strokeEnd = fraction
        let rotorSide = side * 0.54
        rotor.bounds = CGRect(x: 0, y: 0, width: rotorSide, height: rotorSide)
        rotor.position = .init(x: side / 2, y: side / 2)
        let center = CGPoint(x: rotorSide / 2, y: rotorSide / 2)
        let blade = CGMutablePath()
        for i in 0..<4 {
            var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(i) * .pi / 2)
            let petal = CGMutablePath()
            petal.move(to: .init(x: rotorSide * 0.04, y: rotorSide * 0.04))
            petal.addCurve(to: .init(x: rotorSide * 0.16, y: rotorSide * 0.43), control1: .init(x: -rotorSide * 0.10, y: rotorSide * 0.11), control2: .init(x: -rotorSide * 0.13, y: rotorSide * 0.35))
            petal.addCurve(to: .init(x: rotorSide * 0.12, y: rotorSide * 0.11), control1: .init(x: rotorSide * 0.33, y: rotorSide * 0.47), control2: .init(x: rotorSide * 0.38, y: rotorSide * 0.15))
            petal.closeSubpath()
            if let copy = petal.copy(using: &transform) { blade.addPath(copy) }
        }
        rotor.path = blade; rotor.fillColor = NSColor.systemTeal.withAlphaComponent(0.8).cgColor
        hub.frame = bounds; hub.path = CGPath(ellipseIn: .init(x: side / 2 - 3, y: side / 2 - 3, width: 6, height: 6), transform: nil)
        hub.fillColor = NSColor.systemTeal.cgColor
        CATransaction.commit()
        updateAnimation()
    }
    override func visibilityChanged() { updateAnimation() }
    override func stopAnimations() {
        if animationDuration != nil {
            let angle = (rotor.presentation() ?? rotor).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rotor.setValue(angle, forKeyPath: "transform.rotation.z")
            rotor.removeAnimation(forKey: "cooling.rotation")
            CATransaction.commit()
        }
        animationDuration = nil
    }

    /// Visually slow the physical rotation by 100× so individual blades remain
    /// readable: doubling the measured RPM doubles the displayed angular speed.
    static func rotationDuration(rpm: Double) -> Double? {
        guard rpm.isFinite, rpm > 0 else { return nil }
        return min(6, max(0.5, 6_000 / rpm))
    }

    private func updateAnimation() {
        guard animationIsVisible, !reduceMotion,
              let duration = Self.rotationDuration(rpm: rpm) else { stopAnimations(); return }
        // Ignore sensor noise, while retaining the current angle when speed changes.
        guard animationDuration.map({ abs($0 - duration) / $0 > 0.02 }) ?? true else { return }
        let angle = (rotor.presentation() ?? rotor).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = angle; rotation.toValue = angle + 2 * Double.pi
        rotation.duration = duration; rotation.repeatCount = .infinity
        rotation.timingFunction = .init(name: .linear)
        rotor.add(rotation, forKey: "cooling.rotation")
        animationDuration = duration
    }
}
