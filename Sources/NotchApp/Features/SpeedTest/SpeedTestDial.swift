import SwiftUI

enum SpeedTestGaugeScale {
    // Marked ranges keep everyday connections readable and extend to 10 Gbit/s.
    static let marks: [Double] = [0, 10, 100, 1_000, 10_000]
    static func fraction(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 0 }
        for index in 0..<(marks.count - 1) where value <= marks[index + 1] {
            let local = (value - marks[index]) / (marks[index + 1] - marks[index])
            return (Double(index) + local) / Double(marks.count - 1)
        }
        return 1
    }
}

/// The needle lives above the baseline; the reading has its own space below it.
struct SpeedTestDial: View {
    let value: Double?
    var phase: SpeedTestPhase? = nil
    var isRunning = false
    var title = "Готов к проверке"
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { phase == .upload ? SpeedTestStyle.upload : SpeedTestStyle.download }
    private var reading: Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    private var displayTitle: String {
        switch phase {
        case .upload: "Отдача"
        case .download: "Скачивание"
        case .latency: "Измеряем задержку"
        case nil: title
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let radius = min((geometry.size.width - 44) / 2, compact ? 105.0 : 124.0)
            let center = CGPoint(x: geometry.size.width / 2, y: radius + 14)
            ZStack(alignment: .topLeading) {
                SpeedTestSemicircle()
                    .stroke(.white.opacity(0.07), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: radius * 2, height: radius)
                    .position(x: center.x, y: center.y - radius / 2)
                SpeedTestSemicircle().trim(from: 0, to: SpeedTestGaugeScale.fraction(reading))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .shadow(color: color.opacity(0.2), radius: 4)
                    .frame(width: radius * 2, height: radius)
                    .position(x: center.x, y: center.y - radius / 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: reading)
                Canvas { context, _ in
                    for index in 0...40 {
                        let angle = Double.pi + Double(index) / 40 * Double.pi
                        let major = index % 10 == 0
                        let outer = radius - 11
                        let inner = outer - (major ? 8.0 : 3.0)
                        var tick = Path()
                        tick.move(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                        tick.addLine(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                        context.stroke(tick, with: .color(.white.opacity(major ? 0.42 : 0.16)), lineWidth: 1)
                    }
                    let labels = ["0", "10", "100", "1k", "10k"]
                    for index in labels.indices {
                        let angle = Double.pi + Double(index) / 4 * Double.pi
                        let distance = radius - 34
                        let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                        context.draw(Text(labels[index]).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38)), at: point)
                    }
                }.accessibilityHidden(true)
                SpeedTestNeedle(fraction: SpeedTestGaugeScale.fraction(reading))
                    .fill(LinearGradient(colors: [color.opacity(0.2), color], startPoint: .bottom, endPoint: .top))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(center)
                    .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 110, damping: 20), value: reading)
                Circle().fill(color).frame(width: 7, height: 7).position(center)
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(reading.map { $0.formatted(.number.precision(.fractionLength($0 >= 1_000 ? 0 : 1))) } ?? "—")
                            .font(.system(size: compact ? 34 : 42, weight: .medium, design: .rounded))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text("Мбит/с").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        if isRunning { Circle().fill(color).frame(width: 4, height: 4) }
                        Text(displayTitle).lineLimit(1)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: geometry.size.width - 12, height: 59)
                .position(x: center.x, y: center.y + 40)
            }
        }
        .frame(height: compact ? 190 : 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayTitle)
        .accessibilityValue(reading.map { "\($0.formatted()) мегабит в секунду" } ?? (isRunning ? "Измерение" : "Нет измерений"))
    }
}

private struct SpeedTestSemicircle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: rect.width / 2,
                        startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        }
    }
}

private struct SpeedTestNeedle: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angle = Double.pi + fraction * Double.pi
        let length = rect.width * 0.34
        return Path { path in
            path.move(to: CGPoint(x: center.x + cos(angle + .pi / 2) * 2.2,
                                  y: center.y + sin(angle + .pi / 2) * 2.2))
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
            path.addLine(to: CGPoint(x: center.x + cos(angle - .pi / 2) * 2.2,
                                     y: center.y + sin(angle - .pi / 2) * 2.2))
            path.closeSubpath()
        }
    }
}

enum SpeedTestStyle {
    static let download = Color(red: 0.27, green: 0.82, blue: 0.81)
    static let upload = Color(red: 0.64, green: 0.57, blue: 0.94)
}
