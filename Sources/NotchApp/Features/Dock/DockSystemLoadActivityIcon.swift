import AppKit
import SwiftUI

/// Metric glyphs animate on Core Animation, so the four Dock gauges do not
/// need a SwiftUI timeline or recurring main-thread updates.
struct DockSystemLoadActivityIcon: NSViewRepresentable {
    let metric: SystemMonitorMetric
    let color: Color
    let hasSample: Bool
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> DockSystemLoadActivityIconNSView {
        DockSystemLoadActivityIconNSView()
    }

    func updateNSView(_ view: DockSystemLoadActivityIconNSView, context: Context) {
        let color = NSColor(cgColor: color.resolve(in: context.environment).cgColor) ?? .white
        view.configure(metric: metric, color: color, hasSample: hasSample,
                       receivedBytesPerSecond: receivedBytesPerSecond,
                       sentBytesPerSecond: sentBytesPerSecond, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: DockSystemLoadActivityIconNSView, coordinator: ()) {
        view.stopAnimations()
    }
}

final class DockSystemLoadActivityIconNSView: DockMusicAnimationNSView {
    private let glyph = NSImageView()
    private let receiveArrow = NSImageView()
    private let sendArrow = NSImageView()
    private var metric: SystemMonitorMetric?
    private var color: NSColor = .white
    private var hasSample = false
    private var receivesTraffic = false
    private var sendsTraffic = false
    private var reduceMotion = false

    private static let cpuPulse = "system-load.cpu-pulse"
    private static let memoryPulse = "system-load.memory-pulse"
    private static let diskGlow = "system-load.disk-glow"
    private static let receiveMotion = "system-load.network-receive"
    private static let sendMotion = "system-load.network-send"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for imageView in [glyph, receiveArrow, sendArrow] {
            imageView.imageScaling = .scaleProportionallyDown
            imageView.contentTintColor = .white
            imageView.wantsLayer = true
            imageView.layer?.masksToBounds = false
            addSubview(imageView)
        }
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(metric: SystemMonitorMetric, color: NSColor, hasSample: Bool,
                   receivedBytesPerSecond: Double, sentBytesPerSecond: Double,
                   reduceMotion: Bool) {
        let receives = receivedBytesPerSecond.isFinite && receivedBytesPerSecond > 0
        let sends = sentBytesPerSecond.isFinite && sentBytesPerSecond > 0
        let changed = self.metric != metric || !self.color.isEqual(color)
            || self.hasSample != hasSample || receivesTraffic != receives
            || sendsTraffic != sends || self.reduceMotion != reduceMotion
        self.metric = metric
        self.color = color
        self.hasSample = hasSample
        receivesTraffic = receives
        sendsTraffic = sends
        self.reduceMotion = reduceMotion
        updateGlyph()
        if changed { updateAnimations() }
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.frame = CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)
        receiveArrow.frame = CGRect(x: center.x - 5, y: center.y - 5, width: 7, height: 10)
        sendArrow.frame = CGRect(x: center.x - 1, y: center.y - 5, width: 7, height: 10)
    }

    override func visibilityChanged() {
        if animationIsVisible { updateAnimations() }
        else { stopAnimations() }
    }

    override func stopAnimations() {
        [Self.cpuPulse, Self.memoryPulse, Self.diskGlow].forEach { glyph.layer?.removeAnimation(forKey: $0) }
        glyph.layer?.removeAnimation(forKey: Self.cpuPulse + ".scale")
        glyph.layer?.removeAnimation(forKey: Self.memoryPulse + ".scale")
        receiveArrow.layer?.removeAnimation(forKey: Self.receiveMotion)
        sendArrow.layer?.removeAnimation(forKey: Self.sendMotion)
    }

    private func updateGlyph() {
        guard let metric else { return }
        if metric == .network {
            glyph.isHidden = true
            receiveArrow.isHidden = false
            sendArrow.isHidden = false
            receiveArrow.image = symbol("arrow.down")
            sendArrow.image = symbol("arrow.up")
            receiveArrow.contentTintColor = color
            sendArrow.contentTintColor = color
        } else {
            glyph.isHidden = false
            receiveArrow.isHidden = true
            sendArrow.isHidden = true
            glyph.image = symbol(metric.symbol)
            glyph.contentTintColor = color
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name,
                accessibilityDescription: metric?.title)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
                )
    }

    private func updateAnimations() {
        stopAnimations()
        guard hasSample, animationIsVisible, !reduceMotion, let metric else { return }
        switch metric {
        case .cpu:
            addPulse(to: glyph.layer, key: Self.cpuPulse, duration: 2.2, delay: 0)
        case .memory:
            addPulse(to: glyph.layer, key: Self.memoryPulse, duration: 2.6, delay: 0.7)
        case .disk:
            // This is capacity usage, not disk activity; illuminate gently without implying I/O.
            let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
            glow.values = [0.08, 0.38, 0.08]
            glow.duration = 2.8
            glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.repeatCount = .infinity
            glow.beginTime = CACurrentMediaTime() + 1.3
            glyph.layer?.shadowColor = color.cgColor
            glyph.layer?.shadowRadius = 3
            glyph.layer?.shadowOffset = .zero
            glyph.layer?.add(glow, forKey: Self.diskGlow)
        case .network:
            if receivesTraffic { animateArrow(receiveArrow, direction: -1, key: Self.receiveMotion) }
            if sendsTraffic { animateArrow(sendArrow, direction: 1, key: Self.sendMotion) }
        }
    }

    private func addPulse(to layer: CALayer?, key: String, duration: CFTimeInterval, delay: CFTimeInterval) {
        guard let layer else { return }
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.06, 0.48, 0.06]
        glow.duration = duration
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.repeatCount = .infinity
        glow.beginTime = CACurrentMediaTime() + delay
        layer.shadowColor = color.cgColor
        layer.shadowRadius = 3
        layer.shadowOffset = .zero
        layer.add(glow, forKey: key)

        if key == Self.cpuPulse || key == Self.memoryPulse {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = key == Self.cpuPulse ? [1, 1.1, 1] : [1, 1.055, 1]
            scale.duration = duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scale.repeatCount = .infinity
            scale.beginTime = CACurrentMediaTime() + delay
            layer.add(scale, forKey: key + ".scale")
        }
    }

    private func animateArrow(_ arrow: NSImageView, direction: CGFloat, key: String) {
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 0
        animation.toValue = direction * 1.4
        animation.duration = 0.65
        animation.autoreverses = true
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.repeatCount = .infinity
        arrow.layer?.add(animation, forKey: key)
    }
}
