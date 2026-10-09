import SwiftUI

struct SystemMetricReading {
    let metric: SystemMonitorMetric
    let value: String
    let detail: String
    let fraction: Double?

    init(metric: SystemMonitorMetric, snapshot: SystemMetricsSnapshot?) {
        self.metric = metric
        switch metric {
        case .cpu:
            fraction = snapshot?.cpuFraction
            value = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            detail = fraction == nil ? "Ожидаем замер" : "Загрузка всех ядер"
        case .memory, .disk:
            let usage = metric == .memory ? snapshot?.memory : snapshot?.disk
            fraction = usage?.fraction
            value = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
            detail = usage.map { "\(Self.bytes($0.usedBytes)) из \(Self.bytes($0.totalBytes))" } ?? "Нет данных"
        case .network:
            fraction = nil
            value = snapshot?.network.map { "↓ \(Self.rate($0.receivedBytesPerSecond))" } ?? "—"
            detail = snapshot?.network.map { "↑ \(Self.rate($0.sentBytesPerSecond))" } ?? "Ожидаем замер"
        }
    }

    var color: Color {
        guard let fraction else { return metric == .network ? .accentColor : .secondary }
        return fraction >= 0.9 ? .signalCoral : fraction >= 0.75 ? .signalAmber : .signalMint
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }
}

struct SystemMetricRing: View {
    let reading: SystemMetricReading
    var size: CGFloat = 36
    var showsGlow = true
    var body: some View {
        ZStack {
            Circle().stroke(NotchPalette.track, lineWidth: QuotaProviderRingStyle.trackLineWidth)
            if let fraction = reading.fraction {
                Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(reading.color, style: StrokeStyle(
                        lineWidth: QuotaProviderRingStyle.activeLineWidth,
                        lineCap: .round
                    ))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: reading.color.opacity(showsGlow ? QuotaProviderRingStyle.glowOpacity : 0),
                            radius: QuotaProviderRingStyle.glowRadius)
            }
            Image(systemName: reading.metric.symbol)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(reading.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SystemMonitorTriggerView: View {
    let style: SystemMonitorStyle
    let position: SystemMonitorPosition
    let onHover: (Bool) -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: indicatorAlignment) {
                Color.clear
                Capsule(style: .continuous)
                    .fill(NotchPalette.accent)
                    .frame(width: indicatorWidth, height: indicatorHeight)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityLabel("Показать мониторинг системы")
    }

    private var indicatorAlignment: Alignment {
        if style == .sidebar { return position.isLeft ? .leading : .trailing }
        return switch (position.isLeft, position.isTop) {
        case (true, true): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }

    private var indicatorWidth: CGFloat {
        style == .sidebar ? QuotaEdgePanelLayout.triggerIndicatorWidth
            : QuotaCornerStackLayout.triggerIndicatorWidth
    }

    private var indicatorHeight: CGFloat {
        style == .sidebar ? QuotaEdgePanelLayout.triggerIndicatorHeight
            : QuotaCornerStackLayout.triggerIndicatorHeight
    }
}

struct SystemMonitorSidebarView: View {
    @ObservedObject var store: SystemMonitorStore
    let edge: QuotaPanelEdge
    let onHover: (Bool) -> Void
    let onMetricHover: (SystemMonitorMetric?) -> Void
    let onOpenMetric: (SystemMonitorMetric) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.preferences.metrics) { metric in
                metricButton(metric)
            }
        }
        .padding(.vertical, QuotaEdgePanelLayout.verticalPadding)
        .frame(
            width: QuotaEdgePanelLayout.railWidth,
            height: QuotaEdgePanelLayout.railSize(providerCount: store.preferences.metrics.count).height
        )
        .background {
            ZStack {
                NativePanelBackground(material: .popover)
                QuotaEdgeWaveShape(edge: edge)
                    .fill(NotchPalette.surface.opacity(0.78))
            }
            .clipShape(QuotaEdgeWaveShape(edge: edge))
            .shadow(color: .black.opacity(0.34), radius: 12, x: edge == .left ? 5 : -5, y: 4)
        }
        .overlay {
            QuotaEdgeWaveShape(edge: edge)
                .stroke(NotchPalette.separator, lineWidth: 0.5)
        }
        .onHover(perform: onHover)
        .onDisappear {
            onHover(false)
            onMetricHover(nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Мониторинг системы")
    }

    private func metricButton(_ metric: SystemMonitorMetric) -> some View {
        let reading = SystemMetricReading(metric: metric, snapshot: store.snapshot)
        return Button { onOpenMetric(metric) } label: {
            VStack(spacing: 3) {
                SystemMetricRing(reading: reading, size: 34)
                    .contentShape(Circle())
                    .onHover { onMetricHover($0 ? metric : nil) }
                Text(reading.value)
                    .font(.system(size: metric == .network ? 8 : 10, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(NotchPalette.text.opacity(reading.value == "—" ? 0.38 : 0.82))
                    .frame(maxWidth: 58)
            }
            .frame(width: 58, height: QuotaEdgePanelLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: QuotaEdgePanelLayout.railWidth,
               height: QuotaEdgePanelLayout.rowHeight,
               alignment: edge == .left ? .trailing : .leading)
        .accessibilityLabel("\(metric.title): \(reading.value), \(reading.detail)")
        .accessibilityHint(metric == .cpu || metric == .memory ? "Показывает самые ресурсоёмкие процессы" : "Открывает настройки мониторинга")
    }
}

struct SystemMonitorStackItemView: View {
    @ObservedObject var store: SystemMonitorStore
    let metric: SystemMonitorMetric
    let corner: QuotaStackCorner
    let index: Int
    let onHover: (Bool) -> Void
    let onOpenMetric: (SystemMonitorMetric) -> Void

    @State private var isHovered = false

    private var reading: SystemMetricReading {
        SystemMetricReading(metric: metric, snapshot: store.snapshot)
    }

    var body: some View {
        Button { onOpenMetric(metric) } label: {
            HStack(spacing: -10) {
                if corner.edge == .left {
                    metricRing.zIndex(1)
                    metricLabel
                } else {
                    metricLabel
                    metricRing.zIndex(1)
                }
            }
            .frame(width: QuotaCornerStackLayout.itemWidth - QuotaCornerStackLayout.contentPadding * 2,
                   height: QuotaCornerStackLayout.itemHeight - QuotaCornerStackLayout.contentPadding * 2,
                   alignment: cornerAlignment)
            .rotationEffect(.degrees(QuotaCornerStackLayout.restingRotation(index: index, corner: corner)))
            .scaleEffect(isHovered ? 1.025 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .padding(QuotaCornerStackLayout.contentPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            onHover(hovering)
        }
        .onDisappear { onHover(false) }
        .accessibilityLabel("\(metric.title): \(reading.value), \(reading.detail)")
        .accessibilityHint(metric == .cpu || metric == .memory ? "Показывает самые ресурсоёмкие процессы" : "Открывает настройки мониторинга")
    }

    private var cornerAlignment: Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private var metricRing: some View {
        ZStack {
            Circle()
                .fill(NotchPalette.surface.opacity(0.96))
            SystemMetricRing(reading: reading, size: QuotaCornerStackLayout.ringSize - 6, showsGlow: false)
            Circle().stroke(NotchPalette.separator, lineWidth: 0.75)
        }
        .frame(width: QuotaCornerStackLayout.ringSize, height: QuotaCornerStackLayout.ringSize)
    }

    private var metricLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchPalette.text.opacity(0.94))
                Text(metric == .network ? reading.detail.replacingOccurrences(of: " ", with: "") : reading.detail)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(NotchPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            Text(metric == .network ? reading.value.replacingOccurrences(of: " ", with: "") : reading.value)
                .font(.system(size: metric == .network ? 10 : 15, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(NotchPalette.text.opacity(reading.value == "—" ? 0.38 : 0.92))
        }
        .padding(.leading, corner.edge == .left ? 18 : 14)
        .padding(.trailing, corner.edge == .right ? 18 : 14)
        .frame(width: QuotaCornerStackLayout.labelWidth, height: 48)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(NotchPalette.surface.opacity(0.96))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(NotchPalette.separator.opacity(isHovered ? 1.4 : 0.75), lineWidth: 0.75)
        }
    }
}

struct SystemMonitorDetailView: View {
    @ObservedObject var store: SystemMonitorStore
    let metric: SystemMonitorMetric

    private var reading: SystemMetricReading {
        SystemMetricReading(metric: metric, snapshot: store.snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: metric.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(reading.color)
                Text(metric.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(reading.value)
                    .font(.system(size: metric == .network ? 10 : 13, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(reading.color)
            }
            Text(reading.detail)
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .monospacedDigit()
        .padding(14)
        .frame(width: 220, height: 86, alignment: .topLeading)
        .background { NativePanelBackground(material: .popover) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(NotchPalette.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
        .padding(12)
        .frame(width: 244, height: 110)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title): \(reading.value), \(reading.detail)")
    }
}

struct SystemMonitorSettingsView: View {
    @ObservedObject var store: SystemMonitorStore
    var body: some View {
        VStack(spacing: 12) {
            SettingsCard(title: "Мониторинг системы", icon: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Показывать мониторинг", isOn: preference(\.enabled)).frame(minHeight: 40)
                    Text("В покое виден только тонкий маркер у края или в углу экрана. Наведите указатель, чтобы открыть показатели; они скроются после ухода указателя.")
                        .settingsHintStyle()
                    Text("Нажмите на CPU или ОЗУ, чтобы увидеть пять самых ресурсоёмких процессов.")
                        .settingsHintStyle()
                }
            }
            SettingsCard(title: "Размещение", icon: "rectangle.inset.filled") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Вид", selection: preference(\.style)) {
                        ForEach(SystemMonitorStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker("Положение", selection: preference(\.position)) {
                        ForEach(positions, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Обновление", selection: preference(\.interval)) {
                        Text("1 секунда").tag(1.0)
                        Text("2 секунды").tag(2.0)
                        Text("5 секунд").tag(5.0)
                    }
                    Text("Экран выбирается в разделе «Дисплеи». Стек привязан к углу экрана без отступа от Dock. Положение учитывает панели лимитов.")
                        .settingsHintStyle()
                }
            }
            SettingsCard(title: "Показатели", icon: "gauge.with.dots.needle.67percent") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SystemMonitorMetric.allCases) { metric in
                        Toggle(isOn: Binding(get: { store.preferences.metrics.contains(metric) }, set: { enabled in
                            var value = store.preferences
                            if enabled { value.metrics.append(metric) } else { value.metrics.removeAll { $0 == metric } }
                            store.setPreferences(value)
                        })) { Label(metric.title, systemImage: metric.symbol) }
                        .frame(minHeight: 32)
                        .disabled(store.preferences.metrics == [metric])
                    }
                    Text("CPU — общая загрузка всех ядер. ОЗУ — оценка занятой памяти без файлового кэша. Диск — занятое место на системном томе. Сеть — текущий трафик Wi‑Fi/Ethernet, а не Speedtest.")
                        .settingsHintStyle().padding(.top, 8)
                }
            }
            Text("Данные обрабатываются локально и не сохраняются. Во время сна и при выключенном мониторинге сбор остановлен.")
                .settingsHintStyle()
        }
        .font(.system(size: 12))
    }

    private var positions: [SystemMonitorPosition] {
        store.preferences.style == .sidebar ? [.left, .right] : [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    private func preference<T>(_ keyPath: WritableKeyPath<SystemMonitorPreferences, T>) -> Binding<T> {
        Binding(get: { store.preferences[keyPath: keyPath] }, set: { newValue in
            var value = store.preferences
            value[keyPath: keyPath] = newValue
            store.setPreferences(value)
        })
    }
}
