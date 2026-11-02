import SwiftUI

struct SystemMetricsHistoryView: View {
    let samples: [SystemMetricsSnapshot]
    let metric: SystemMonitorMetric
    let color: Color

    private func fraction(_ sample: SystemMetricsSnapshot) -> Double? {
        let value = metric == .cpu ? sample.cpuFraction : sample.memory?.fraction
        return value.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
    }

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 6
            let bottom = size.height - 3
            var guide = Path()
            guide.move(to: .init(x: 0, y: top))
            guide.addLine(to: .init(x: size.width, y: top))
            context.stroke(guide, with: .color(.secondary.opacity(0.25)), style: .init(lineWidth: 0.7, dash: [3, 4]))
            guard let end = samples.last?.sampledAt else { return }
            let start = end.addingTimeInterval(-120)
            var segments: [[CGPoint]] = []
            var segment: [CGPoint] = []
            var previousDate: Date?
            for sample in samples {
                guard let value = fraction(sample), sample.sampledAt >= start else {
                    if !segment.isEmpty { segments.append(segment); segment = [] }
                    previousDate = nil
                    continue
                }
                if let previousDate, sample.sampledAt.timeIntervalSince(previousDate) > 10 {
                    if !segment.isEmpty { segments.append(segment); segment = [] }
                }
                let x = CGFloat(sample.sampledAt.timeIntervalSince(start) / 120) * size.width
                segment.append(CGPoint(x: x, y: bottom - CGFloat(value) * (bottom - top)))
                previousDate = sample.sampledAt
            }
            if !segment.isEmpty { segments.append(segment) }
            for points in segments {
                guard let first = points.first, let last = points.last else { continue }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: .init(x: last.x, y: bottom))
                area.addLine(to: .init(x: first.x, y: bottom))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(.init(colors: [color.opacity(0.18), color.opacity(0.015)]),
                                                        startPoint: .zero, endPoint: .init(x: 0, y: bottom)))
                context.stroke(line, with: .color(color), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if points.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(color))
                }
            }
        }
        .frame(height: 42)
        .overlay(alignment: .topLeading) {
            Text("100%") .font(.system(size: 8)).foregroundStyle(.secondary)
                .padding(.horizontal, 3).background(NotchPalette.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
        }
        .overlay {
            if samples.compactMap({ fraction($0) }).count < 2 {
                Text("Собираем историю…").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title): история за две минуты")
        .accessibilityValue(samples.last.flatMap(fraction).map { "Последнее значение \(Int(($0 * 100).rounded())) процентов" } ?? "Нет данных")
    }
}

struct SystemMemoryBreakdown: View {
    let details: SystemMemoryDetails?
    var body: some View {
        VStack(spacing: 7) {
            row("Сжатая", bytes: details?.compressedBytes,
                help: "Объём физической ОЗУ, занятый сжатыми страницами.")
            row("Файловый кэш", bytes: details?.cachedBytes,
                help: "Страницы памяти, связанные с файлами. macOS может освободить этот кэш.")
            row("Закреплённая", bytes: details?.wiredBytes,
                help: "Память, которую macOS не может выгрузить на диск.")
            row("Подкачка", bytes: details?.swapUsedBytes,
                help: "Память, выгруженная на диск. Выделено под подкачку: \(details?.swapTotalBytes.map(SystemMetricReading.bytes) ?? "нет данных").")
        }
    }
    private func row(_ label: String, bytes: UInt64?, help: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(bytes.map(SystemMetricReading.bytes) ?? "—").monospacedDigit()
        }.font(.system(size: 11)).help(help)
    }
}

struct SystemMemoryPressureBadge: View {
    let pressure: SystemMemoryPressure?
    private var color: Color {
        switch pressure { case .normal: .green; case .warning: .orange; case .critical: .red; case nil: .secondary }
    }
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(pressure == .normal ? "Норма" : pressure?.title ?? "Нет данных")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel("Давление памяти: \(pressure?.title ?? "нет данных")")
    }
}
