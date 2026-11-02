import AppKit

/// A bounded history of real samples. Gaps start a new trace instead of inventing intermediate values.
struct ReactorTelemetryHistory {
    struct Sample {
        let date: Date
        let cpu: Double?
        let received: Double?
        let sent: Double?
    }
    private(set) var samples: [Sample] = []
    static let duration: TimeInterval = 120

    mutating func append(_ snapshot: SystemMetricsSnapshot?) {
        guard let snapshot else { samples.removeAll(keepingCapacity: true); return }
        if let last = samples.last {
            guard snapshot.sampledAt > last.date else { return }
            if snapshot.sampledAt.timeIntervalSince(last.date) > 6 { samples.removeAll(keepingCapacity: true) }
        }
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        samples.append(Sample(date: snapshot.sampledAt, cpu: valid(snapshot.cpuFraction).map { min(1, $0) },
            received: valid(snapshot.network?.receivedBytesPerSecond), sent: valid(snapshot.network?.sentBytesPerSecond)))
        let cutoff = snapshot.sampledAt.addingTimeInterval(-Self.duration)
        samples.removeAll { $0.date < cutoff }
        if samples.count > 61 { samples.removeFirst(samples.count - 61) }
    }

    var networkPeak: Double? {
        samples.flatMap { [$0.received, $0.sent].compactMap { $0 } }.max()
    }
}

/// Telemetry and clock for the ARC reactor wallpaper. The controller supplies resource readings;
/// the only local timer refreshes the clock once a minute, independently of the Metal animation.
@MainActor
final class LiveWallpaperReactorHUD: NSView {
    private var snapshot: SystemMetricsSnapshot?
    private var history = ReactorTelemetryHistory()
    private var clockTimer: Timer?
    private var clockMinute: Int?
    private var clockTime = ""
    private var clockDate = ""

    private let cyan = NSColor(calibratedRed: 0.32, green: 0.83, blue: 1, alpha: 0.86)
    private let dimCyan = NSColor(calibratedRed: 0.25, green: 0.68, blue: 0.88, alpha: 0.48)
    private let faintCyan = NSColor(calibratedRed: 0.25, green: 0.68, blue: 0.88, alpha: 0.19)
    private let inactiveCyan = NSColor(calibratedRed: 0.20, green: 0.53, blue: 0.69, alpha: 0.24)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        refreshClock()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clockTimer?.invalidate()
        clockTimer = nil
        guard window != nil else { return }
        refreshClock(force: true)
        let now = Date()
        let nextMinute = floor(now.timeIntervalSince1970 / 60) * 60 + 60
        let timer = Timer(fire: Date(timeIntervalSince1970: nextMinute), interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshClock(force: true)
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func refreshClock(force: Bool = false) {
        let now = Date()
        let minute = Int(floor(now.timeIntervalSince1970 / 60))
        guard force || clockMinute != minute else { return }
        clockMinute = minute
        let time = DateFormatter()
        time.locale = .autoupdatingCurrent
        time.timeZone = .autoupdatingCurrent
        time.setLocalizedDateFormatFromTemplate("jm")
        let date = DateFormatter()
        date.locale = .autoupdatingCurrent
        date.timeZone = .autoupdatingCurrent
        date.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        clockTime = time.string(from: now)
        clockDate = date.string(from: now)
        needsDisplay = true
    }

    func update(_ snapshot: SystemMetricsSnapshot?) {
        refreshClock()
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        history.append(snapshot)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let compact = bounds.width < 900
        let scale = min(1.12, max(0.72, bounds.width / 1800))
        let margin = compact ? 18 * scale : 52 * scale
        let columnWidth = compact
            ? min(196 * scale, max(148 * scale, bounds.width * 0.235))
            : min(440 * scale, max(290 * scale, bounds.width * 0.19))
        let leftX = margin
        let rightX = max(leftX + columnWidth + 8, bounds.width - margin - columnWidth)
        let safeTop = 64 * scale
        let safeBottom = 120 * scale
        let centerY = min(bounds.height - safeBottom - 100 * scale,
                          max(safeTop + 170 * scale, bounds.midY))
        let coreRadius = bounds.height * 0.40
        let coreLeft = bounds.midX - coreRadius
        let coreRight = bounds.midX + coreRadius

        drawHeader(scale: scale, top: min(safeTop, max(38, bounds.height * 0.055)))
        drawClock(scale: scale)

        let rows: [MetricRow] = [
            MetricRow(title: "CPU LOAD", value: cpuValue, detail: "TOTAL PROCESSOR LOAD", fraction: snapshot?.cpuFraction, valueStyle: .percentage),
            MetricRow(title: "MEMORY", value: resourceValue(snapshot?.memory), detail: resourceDetail(snapshot?.memory), fraction: snapshot?.memory?.fraction, valueStyle: .resource),
            MetricRow(title: "STORAGE", value: resourceValue(snapshot?.disk), detail: resourceDetail(snapshot?.disk), fraction: snapshot?.disk?.fraction, valueStyle: .resource)
        ]

        let rowGap = compact ? 24 * scale : 42 * scale
        let blockHeight = compact ? 84 * scale : 104 * scale
        let groupHeight = blockHeight * 2 + rowGap
        let firstY = min(bounds.height - safeBottom - groupHeight,
                         max(safeTop + 92 * scale, centerY - groupHeight / 2))

        drawMetric(rows[0], x: leftX, y: firstY, width: columnWidth, scale: scale, alignment: .left)
        drawMetric(rows[1], x: leftX, y: firstY + blockHeight + rowGap, width: columnWidth, scale: scale, alignment: .left)
        drawMetric(rows[2], x: rightX, y: firstY, width: columnWidth, scale: scale, alignment: .right)
        drawNetwork(x: rightX, y: firstY + blockHeight + rowGap, width: columnWidth, scale: scale)

        let graphY = firstY + blockHeight * 2 + rowGap + 24 * scale
        if graphY + 62 * scale < bounds.height - 65 * scale {
            drawHistory(x: leftX, y: graphY, width: columnWidth, scale: scale, network: false)
            drawHistory(x: rightX, y: graphY, width: columnWidth, scale: scale, network: true)
        }

        let leaderY = [firstY + 28 * scale,
                       firstY + blockHeight + rowGap + 28 * scale]
        for y in leaderY {
            drawLeader(from: CGPoint(x: leftX + columnWidth + 14 * scale, y: y),
                       to: CGPoint(x: coreLeft - 12 * scale, y: y), scale: scale)
            drawLeader(from: CGPoint(x: coreRight + 12 * scale, y: y),
                       to: CGPoint(x: rightX - 14 * scale, y: y), scale: scale)
        }
    }

    private var cpuValue: String? {
        guard let value = snapshot?.cpuFraction, value.isFinite else { return nil }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }

    private func drawClock(scale: CGFloat) {
        // The dark aperture is clear of particles/orbits and cannot be covered by the Dock.
        guard bounds.height >= 420 else { return }
        let timeSize = min(32 * scale, bounds.height * 0.038)
        let y = bounds.midY - (timeSize + 19 * scale) / 2
        drawText(clockTime, at: CGPoint(x: bounds.midX, y: y),
                 font: .monospacedDigitSystemFont(ofSize: timeSize, weight: .light),
                 color: cyan, alignment: .center, tracking: 2 * scale)
        drawText(clockDate, at: CGPoint(x: bounds.midX, y: y + timeSize + 9 * scale),
                 font: .systemFont(ofSize: 10 * scale, weight: .medium),
                 color: dimCyan, alignment: .center, tracking: 0.6 * scale)
    }

    private func drawHistory(x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat, network: Bool) {
        let height = 44 * scale
        let graph = CGRect(x: x, y: y + 17 * scale, width: width, height: height)
        let label = network ? (width < 220 ? "NET  ↓ / ↑" : "NETWORK HISTORY  ↓ / ↑") : "CPU HISTORY  /  120 s"
        drawText(label, at: CGPoint(x: x, y: y),
                 font: .monospacedSystemFont(ofSize: 8 * scale, weight: .medium),
                 color: dimCyan, alignment: .left, tracking: 0.6 * scale)
        for fraction in [0.0, 0.5, 1.0] {
            let yy = graph.minY + height * fraction
            drawRule(from: CGPoint(x: x, y: yy), to: CGPoint(x: x + width, y: yy), color: faintCyan)
        }
        guard let last = history.samples.last else { return }
        let start = last.date.addingTimeInterval(-ReactorTelemetryHistory.duration)
        func trace(_ value: (ReactorTelemetryHistory.Sample) -> Double?, ceiling: Double, color: NSColor) {
            let path = NSBezierPath()
            path.lineWidth = 1.05 * scale
            var connected = false
            for sample in history.samples {
                guard let value = value(sample) else { connected = false; continue }
                let xx = graph.minX + graph.width * sample.date.timeIntervalSince(start) / ReactorTelemetryHistory.duration
                let yy = graph.maxY - graph.height * min(1, max(0, value / ceiling))
                let point = CGPoint(x: xx, y: yy)
                if connected { path.line(to: point) } else { path.move(to: point) }
                connected = true
            }
            color.setStroke()
            path.stroke()
        }
        if network {
            trace({ $0.received }, ceiling: max(1, history.networkPeak ?? 0), color: cyan)
            trace({ $0.sent }, ceiling: max(1, history.networkPeak ?? 0), color: dimCyan)
            drawText(history.networkPeak.map(Self.rate) ?? "—", at: CGPoint(x: graph.maxX, y: y),
                     font: .monospacedDigitSystemFont(ofSize: 8 * scale, weight: .regular),
                     color: dimCyan, alignment: .right)
        } else {
            trace({ $0.cpu }, ceiling: 1, color: cyan)
        }
    }

    private func resourceValue(_ resource: SystemResourceUsage?) -> String? {
        guard let resource else { return nil }
        return "\(Self.bytes(resource.usedBytes)) / \(Self.bytes(resource.totalBytes))"
    }

    private func resourceDetail(_ resource: SystemResourceUsage?) -> String? {
        guard let resource else { return nil }
        let fraction = resource.fraction
        return fraction.isFinite ? "\(Int((min(1, max(0, fraction)) * 100).rounded()))% OCCUPIED" : nil
    }

    private func drawHeader(scale: CGFloat, top: CGFloat) {
        let eyebrow = "NOOL  /  ARC SYSTEMS"
        let title = "ARC REACTOR   •   SYSTEM TELEMETRY"
        drawText(eyebrow, at: CGPoint(x: bounds.midX, y: top),
                 font: .monospacedSystemFont(ofSize: 10 * scale, weight: .semibold),
                 color: dimCyan, alignment: .center, tracking: 2.1 * scale)
        drawText(title, at: CGPoint(x: bounds.midX, y: top + 18 * scale),
                 font: .monospacedSystemFont(ofSize: 8 * scale, weight: .medium),
                 color: faintCyan, alignment: .center, tracking: 1.25 * scale)

        let headerY = top + 18 * scale
        drawRule(from: CGPoint(x: 0, y: headerY), to: CGPoint(x: max(0, bounds.midX - 145 * scale), y: headerY), color: faintCyan)
        drawRule(from: CGPoint(x: min(bounds.width, bounds.midX + 145 * scale), y: headerY), to: CGPoint(x: bounds.width, y: headerY), color: faintCyan)
    }

    private enum TextAlignment { case left, right, center }

    private func drawMetric(_ row: MetricRow, x: CGFloat, y: CGFloat, width: CGFloat,
                            scale: CGFloat, alignment: TextAlignment) {
        let isRight = alignment == .right
        let textX = isRight ? x + width : x
        let titleColor = dimCyan
        drawText(row.title, at: CGPoint(x: textX, y: y),
                 font: .monospacedSystemFont(ofSize: 10 * scale, weight: .semibold),
                 color: titleColor, alignment: alignment, tracking: 1.55 * scale)
        drawText(row.value ?? "—", at: CGPoint(x: textX, y: y + 21 * scale),
                 font: valueFont(row.valueStyle, width: width, scale: scale),
                 color: row.value == nil ? inactiveCyan : cyan, alignment: alignment)
        if let detail = row.detail {
            drawText(detail, at: CGPoint(x: textX, y: y + 47 * scale),
                     font: .monospacedSystemFont(ofSize: 8 * scale, weight: .regular),
                     color: dimCyan, alignment: alignment, tracking: 0.8 * scale)
        } else if row.title == "NETWORK LINK" {
            drawText("LIVE THROUGHPUT", at: CGPoint(x: textX, y: y + 47 * scale),
                     font: .monospacedSystemFont(ofSize: 8 * scale, weight: .regular),
                     color: dimCyan, alignment: alignment, tracking: 0.8 * scale)
        }
        if let fraction = row.fraction {
            drawSegments(x: x, y: y + 68 * scale, width: width, fraction: fraction, scale: scale)
        } else {
            drawRule(from: CGPoint(x: x, y: y + 68 * scale), to: CGPoint(x: x + width, y: y + 68 * scale), color: faintCyan)
        }
        drawBracket(x: x, y: y - 7 * scale, width: width, height: 82 * scale,
                    rightAligned: isRight, scale: scale)
    }

    private func drawNetwork(x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat) {
        let received = snapshot?.network.map { Self.rate($0.receivedBytesPerSecond) } ?? "—"
        let sent = snapshot?.network.map { Self.rate($0.sentBytesPerSecond) } ?? "—"
        let hasNetwork = snapshot?.network != nil
        let valueColor = hasNetwork ? cyan : inactiveCyan
        let alignment: TextAlignment = .right
        drawText("NETWORK LINK", at: CGPoint(x: x + width, y: y),
                 font: .monospacedSystemFont(ofSize: 10 * scale, weight: .semibold),
                 color: dimCyan, alignment: alignment, tracking: 1.55 * scale)
        drawText("↓  \(received)", at: CGPoint(x: x + width, y: y + 21 * scale),
                 font: .monospacedDigitSystemFont(ofSize: 15 * scale, weight: .medium),
                 color: valueColor, alignment: alignment)
        drawText("↑  \(sent)", at: CGPoint(x: x + width, y: y + 44 * scale),
                 font: .monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular),
                 color: valueColor.withAlphaComponent(hasNetwork ? 0.78 : 0.24), alignment: alignment)
        drawRule(from: CGPoint(x: x, y: y + 68 * scale), to: CGPoint(x: x + width, y: y + 68 * scale), color: faintCyan)
        drawBracket(x: x, y: y - 7 * scale, width: width, height: 82 * scale,
                    rightAligned: true, scale: scale)
    }

    private func drawSegments(x: CGFloat, y: CGFloat, width: CGFloat, fraction: Double, scale: CGFloat) {
        let count = 18
        let gap = 3 * scale
        let segmentWidth = max(1, (width - CGFloat(count - 1) * gap) / CGFloat(count))
        let normalized = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let activeCount = Int((normalized * Double(count)).rounded(.up))
        for index in 0..<count {
            let rect = CGRect(x: x + CGFloat(index) * (segmentWidth + gap), y: y,
                              width: segmentWidth, height: 3 * scale)
            (index < activeCount ? cyan : inactiveCyan).setFill()
            rect.fill()
        }
    }

    private func drawBracket(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                             rightAligned: Bool, scale: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = 0.75 * scale
        let arm = 8 * scale
        let edgeX = rightAligned ? x + width : x
        let innerX = rightAligned ? edgeX - arm : edgeX + arm
        path.move(to: CGPoint(x: edgeX, y: y))
        path.line(to: CGPoint(x: innerX, y: y))
        path.line(to: CGPoint(x: innerX, y: y + height))
        path.line(to: CGPoint(x: edgeX, y: y + height))
        faintCyan.setStroke()
        path.stroke()
    }

    private func drawLeader(from start: CGPoint, to end: CGPoint, scale: CGFloat) {
        guard end.x - start.x > 3 * scale else { return }
        let path = NSBezierPath()
        path.lineWidth = 0.65 * scale
        path.move(to: start)
        path.line(to: end)
        faintCyan.setStroke()
        path.stroke()
        let dot = CGRect(x: end.x - 1.5 * scale, y: end.y - 1.5 * scale,
                         width: 3 * scale, height: 3 * scale)
        dimCyan.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func drawRule(from start: CGPoint, to end: CGPoint, color: NSColor) {
        guard end.x > start.x else { return }
        let path = NSBezierPath()
        path.lineWidth = 0.6
        path.move(to: start)
        path.line(to: end)
        color.setStroke()
        path.stroke()
    }

    private func drawText(_ string: String, at point: CGPoint, font: NSFont,
                          color: NSColor, alignment: TextAlignment, tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .right: paragraph.alignment = .right
        case .center: paragraph.alignment = .center
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        let originX: CGFloat = switch alignment {
        case .left: point.x
        case .right: point.x - size.width
        case .center: point.x - size.width / 2
        }
        (string as NSString).draw(at: CGPoint(x: originX, y: point.y), withAttributes: attributes)
    }

    private func valueFont(_ style: MetricValueStyle, width: CGFloat, scale: CGFloat) -> NSFont {
        let baseSize: CGFloat = (style == .resource ? 13 : 18) * scale
        let font = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .medium)
        guard style == .resource else { return font }
        // Reserve decimal digits and wide unit labels once for this geometry.
        // Live values, formatting precision and missing readings must never resize the text.
        let reservedWidth = ("888.88 WWW / 888.88 WWW" as NSString).size(withAttributes: [.font: font]).width
        return .monospacedDigitSystemFont(ofSize: baseSize * min(1, width / reservedWidth), weight: .medium)
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }

    private enum MetricValueStyle { case percentage, resource }

    private struct MetricRow {
        let title: String
        let value: String?
        let detail: String?
        let fraction: Double?
        let valueStyle: MetricValueStyle
    }
}
