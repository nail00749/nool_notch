import NotchCore
import SwiftUI
import AppKit
import QuartzCore

enum LiveWallpaperOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var title: String {
        switch self {
        case .topLeft: "Слева сверху"
        case .topRight: "Справа сверху"
        case .bottomLeft: "Слева снизу"
        case .bottomRight: "Справа снизу"
        case .center: "По центру"
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        case .center: .center
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .topLeft, .bottomLeft: .leading
        case .topRight, .bottomRight: .trailing
        case .center: .center
        }
    }
}

enum LiveWallpaperOverlaySize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: "Мелкий"
        case .medium: "Средний"
        case .large: "Крупный"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1
        case .large: 1.35
        }
    }
}

/// What the wallpaper draws over its scene or video: AI limits, hardware load, and whether scenes
/// speed up with CPU load.
struct LiveWallpaperOverlaySettings: Codable, Equatable, Sendable {
    var showsQuotas = false
    var hiddenQuotaProviderIDs: Set<String> = []
    var showsSystem = false
    var metrics: [SystemMonitorMetric] = [.cpu, .memory, .disk]
    var position: LiveWallpaperOverlayPosition = .bottomRight
    var size: LiveWallpaperOverlaySize = .medium
    var opacity = 0.85
    var horizontalInset = 64.0
    var verticalInset = 160.0
    static let insetRange = 0.0...320.0
    /// Only the primary display (the one with the menu bar) draws the overlay.
    var mainDisplayOnly = true
    var scenesReactToLoad = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        showsQuotas = try container.decodeIfPresent(Bool.self, forKey: .showsQuotas) ?? defaults.showsQuotas
        hiddenQuotaProviderIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenQuotaProviderIDs) ?? []
        showsSystem = try container.decodeIfPresent(Bool.self, forKey: .showsSystem) ?? defaults.showsSystem
        metrics = (try? container.decodeIfPresent([SystemMonitorMetric].self, forKey: .metrics)) ?? defaults.metrics
        position = (try? container.decodeIfPresent(LiveWallpaperOverlayPosition.self, forKey: .position)) ?? defaults.position
        size = (try? container.decodeIfPresent(LiveWallpaperOverlaySize.self, forKey: .size)) ?? defaults.size
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        horizontalInset = try container.decodeIfPresent(Double.self, forKey: .horizontalInset) ?? defaults.horizontalInset
        verticalInset = try container.decodeIfPresent(Double.self, forKey: .verticalInset) ?? defaults.verticalInset
        mainDisplayOnly = try container.decodeIfPresent(Bool.self, forKey: .mainDisplayOnly) ?? defaults.mainDisplayOnly
        scenesReactToLoad = try container.decodeIfPresent(Bool.self, forKey: .scenesReactToLoad) ?? defaults.scenesReactToLoad
    }

    var isVisible: Bool { showsQuotas || (showsSystem && !metrics.isEmpty) }

    /// Hardware sampling runs only when something shows or uses it.
    var needsSystemMetrics: Bool { (showsSystem && !metrics.isEmpty) || scenesReactToLoad }

    var sanitized: Self {
        var copy = self
        copy.metrics = SystemMonitorMetric.allCases.filter { metrics.contains($0) }
        copy.opacity = opacity.isFinite ? min(1, max(0.3, opacity)) : 0.85
        copy.horizontalInset = horizontalInset.isFinite ? min(Self.insetRange.upperBound, max(0, horizontalInset)) : Self().horizontalInset
        copy.verticalInset = verticalInset.isFinite ? min(Self.insetRange.upperBound, max(0, verticalInset)) : Self().verticalInset
        return copy
    }
}

/// Values the overlay draws; refreshed independently of the render configuration.
struct LiveWallpaperOverlayData: Equatable, Sendable {
    var quotas: [QuotaWidgetProvider] = []
    var system: SystemMetricsSnapshot?
}

/// Shared by every overlay view, so new readings update all displays without rebuilding windows.
@MainActor
final class LiveWallpaperOverlayModel: ObservableObject {
    @Published var settings = LiveWallpaperOverlaySettings()
    @Published var data = LiveWallpaperOverlayData()
}

/// Thin, translucent typography meant to sit in the wallpaper rather than float above it like a widget.
struct LiveWallpaperOverlayView: View {
    @ObservedObject var model: LiveWallpaperOverlayModel

    var body: some View {
        let settings = model.settings
        let scale = settings.size.scale
        VStack(alignment: settings.position.horizontalAlignment, spacing: 22 * scale) {
            if settings.showsSystem, !settings.metrics.isEmpty {
                LiveWallpaperSystemGauges(metrics: settings.metrics, snapshot: model.data.system, scale: scale)
            }
            if settings.showsQuotas {
                LiveWallpaperQuotaBlock(providers: model.data.quotas.filter {
                    !settings.hiddenQuotaProviderIDs.contains($0.id)
                }, scale: scale)
            }
        }
        .foregroundStyle(.white)
        // One shadow for the flattened overlay: without the group SwiftUI keeps a
        // per-leaf NSView shadow and re-applies it on every animated ring frame.
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 10 * scale, y: 2)
        .opacity(settings.opacity)
        .padding(.horizontal, settings.position == .center ? 0 : settings.horizontalInset)
        .padding(.vertical, settings.position == .center ? 0 : settings.verticalInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: settings.position.alignment)
        .allowsHitTesting(false)
    }
}

private struct LiveWallpaperSystemGauges: View {
    let metrics: [SystemMonitorMetric]
    let snapshot: SystemMetricsSnapshot?
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 28 * scale) {
            ForEach(metrics) { metric in
                if metric == .network {
                    networkColumn
                } else {
                    LiveWallpaperRing(fraction: fraction(for: metric), title: metric.title, scale: scale)
                }
            }
        }
    }

    private func fraction(for metric: SystemMonitorMetric) -> Double? {
        switch metric {
        case .cpu: snapshot?.cpuFraction
        case .memory: snapshot?.memory?.fraction
        case .disk: snapshot?.disk?.fraction
        case .network: nil
        }
    }

    private var networkColumn: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text(rateText(snapshot?.network?.receivedBytesPerSecond, arrow: "↓"))
            Text(rateText(snapshot?.network?.sentBytesPerSecond, arrow: "↑"))
            Text("СЕТЬ")
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(1.6)
                .opacity(0.6)
        }
        .font(.system(size: 17 * scale, weight: .light, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        // A fixed column, so "↓ 2 MB/с" turning into "↓ 11,4 KB/с" never shifts the rings beside it.
        .frame(width: 118 * scale, height: 92 * scale, alignment: .leading)
    }

    private func rateText(_ bytesPerSecond: Double?, arrow: String) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite else { return "\(arrow) —" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(arrow) \(formatter.string(fromByteCount: Int64(bytesPerSecond)))/с"
    }
}

private struct LiveWallpaperRing: View {
    let fraction: Double?
    let title: String
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 8 * scale) {
            ZStack {
                LiveWallpaperMeter(fraction: fraction ?? 0, load: fraction ?? 0, kind: .ring, scale: scale)
                Text(fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                    .font(.system(size: 24 * scale, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .frame(width: 72 * scale, height: 72 * scale)
            Text(title.uppercased())
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(1.6)
                .opacity(0.6)
        }
    }
}

private struct LiveWallpaperQuotaBlock: View {
    let providers: [QuotaWidgetProvider]
    let scale: CGFloat

    /// Providers without a 5h or 7d window (signed out, unavailable) would only add an empty name.
    private var shownProviders: [QuotaWidgetProvider] {
        providers.filter { provider in QuotaWidgetPeriod.allCases.contains { provider.window(for: $0) != nil } }
    }

    var body: some View {
        // One fixed-width column keeps names and bars aligned in any corner.
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text("ЛИМИТЫ")
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(1.6)
                .opacity(0.6)
            if shownProviders.isEmpty {
                Text("Нет данных")
                    .font(.system(size: 15 * scale, weight: .light))
                    .opacity(0.7)
            }
            ForEach(shownProviders) { provider in
                VStack(alignment: .leading, spacing: 6 * scale) {
                    Text(provider.name)
                        .font(.system(size: 15 * scale, weight: .medium))
                    ForEach(QuotaWidgetPeriod.allCases, id: \.self) { period in
                        if let window = provider.window(for: period) {
                            LiveWallpaperQuotaBar(label: period.label, window: window, scale: scale)
                        }
                    }
                }
            }
        }
        .frame(width: 330 * scale, alignment: .leading)
    }
}

private struct LiveWallpaperQuotaBar: View {
    let label: String
    let window: QuotaWidgetWindow
    let scale: CGFloat

    var body: some View {
        let remaining = window.remainingRatio
        HStack(spacing: 10 * scale) {
            Text(label)
                .font(.system(size: 12 * scale, weight: .semibold))
                .opacity(0.65)
                .frame(width: 22 * scale, alignment: .leading)
            LiveWallpaperMeter(fraction: remaining ?? 0, load: 1 - (remaining ?? 1), kind: .bar, scale: scale)
            .frame(width: 180 * scale, height: 5 * scale)
            Text(remaining.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 15 * scale, weight: .light, design: .rounded))
                .monospacedDigit()
                .frame(width: 46 * scale, alignment: .trailing)
            if let resetAt = window.resetAt, resetAt > Date() {
                Text(resetAt, format: .dateTime.hour().minute())
                    .font(.system(size: 12 * scale, weight: .regular, design: .rounded))
                    .opacity(0.55)
            }
        }
    }
}

enum LiveWallpaperOverlayPalette {
    /// Calm white-cyan under light load, warming to amber and coral as usage climbs.
    static func load(_ fraction: Double) -> Color {
        Color(nsColor: nativeLoad(fraction))
    }

    static func nativeLoad(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.6: NSColor(srgbRed: 0.72, green: 0.92, blue: 1, alpha: 1)
        case ..<0.85: NSColor(srgbRed: 1, green: 0.78, blue: 0.4, alpha: 1)
        default: NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 1)
        }
    }
}

/// Only readings update SwiftUI. Core Animation interpolates the stroke/width between readings,
/// avoiding a full-screen hosting-view layout on each frame of the 0.8-second transition.
private struct LiveWallpaperMeter: NSViewRepresentable {
    let fraction: Double
    let load: Double
    let kind: LiveWallpaperMeterView.Kind
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LiveWallpaperMeterView { LiveWallpaperMeterView() }

    func updateNSView(_ view: LiveWallpaperMeterView, context: Context) {
        view.update(fraction: fraction, load: load, kind: kind, scale: scale, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: LiveWallpaperMeterView, coordinator: ()) { view.stopAnimations() }
}

@MainActor
final class LiveWallpaperMeterView: NSView {
    enum Kind: Equatable { case ring, bar }
    static let animationDuration = 0.8
    private(set) var kind: Kind = .ring
    private(set) var scale: CGFloat = 1
    private(set) var fraction: Double = 0
    private var load: Double = 0
    private var configured = false
    private var geometryBounds: CGRect?
    let trackLayer = CAShapeLayer()
    let valueLayer = CAShapeLayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(valueLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(fraction: Double, load: Double, kind: Kind, scale: CGFloat, reduceMotion: Bool) {
        let fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let load = load.isFinite ? min(1, max(0, load)) : 0
        let geometryChanged = !configured || self.kind != kind || self.scale != scale
        let valueChanged = self.fraction != fraction || self.load != load
        if reduceMotion { stopAnimations() }
        guard geometryChanged || valueChanged else { return }
        let animate = configured && !geometryChanged && !reduceMotion && window != nil
        let previousValue = valueLayer.presentation() ?? valueLayer
        let previousEnd = previousValue.strokeEnd
        let previousBounds = previousValue.bounds
        let previousColor = kind == .ring ? previousValue.strokeColor : previousValue.backgroundColor
        self.kind = kind
        self.scale = scale
        self.fraction = fraction
        self.load = load
        configured = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if geometryChanged {
            stopAnimations()
            geometryBounds = nil
            updateGeometry()
        }
        let color = LiveWallpaperOverlayPalette.nativeLoad(load).cgColor
        switch kind {
        case .ring:
            valueLayer.strokeEnd = fraction
            valueLayer.strokeColor = color
        case .bar:
            valueLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
            valueLayer.backgroundColor = color
        }
        CATransaction.commit()
        if animate {
            if kind == .ring {
                addAnimation("strokeEnd", from: previousEnd, to: fraction)
                addAnimation("strokeColor", from: previousColor, to: color)
            } else {
                addAnimation("bounds", from: NSValue(rect: previousBounds), to: NSValue(rect: valueLayer.bounds))
                addAnimation("backgroundColor", from: previousColor, to: color)
            }
        }
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAnimations() }
    }

    func stopAnimations() {
        trackLayer.removeAllAnimations()
        valueLayer.removeAllAnimations()
    }

    private func updateGeometry() {
        guard geometryBounds != bounds else { return }
        geometryBounds = bounds
        stopAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        valueLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        valueLayer.frame = bounds
        trackLayer.fillColor = nil
        valueLayer.fillColor = nil
        trackLayer.strokeColor = nil
        valueLayer.strokeColor = nil
        trackLayer.backgroundColor = nil
        valueLayer.backgroundColor = nil
        switch kind {
        case .ring:
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2,
                        startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
            trackLayer.path = path
            valueLayer.path = path
            trackLayer.lineWidth = 5 * scale
            valueLayer.lineWidth = 5 * scale
            valueLayer.lineCap = .round
            valueLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            trackLayer.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
            valueLayer.strokeColor = LiveWallpaperOverlayPalette.nativeLoad(load).cgColor
            valueLayer.strokeEnd = fraction
        case .bar:
            trackLayer.path = nil
            valueLayer.path = nil
            trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
            valueLayer.backgroundColor = LiveWallpaperOverlayPalette.nativeLoad(load).cgColor
            trackLayer.cornerRadius = bounds.height / 2
            valueLayer.cornerRadius = bounds.height / 2
            valueLayer.anchorPoint = .zero
            valueLayer.position = .zero
            valueLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        }
        CATransaction.commit()
    }

    private func addAnimation(_ keyPath: String, from: Any?, to: Any?) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.animationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        valueLayer.add(animation, forKey: keyPath)
    }
}
