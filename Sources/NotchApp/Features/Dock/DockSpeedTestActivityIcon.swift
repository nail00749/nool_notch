import AppKit
import SwiftUI

/// Compact Dock speedometer. Measurements set the needle; activity only adds a
/// quiet halo pulse, animated by Core Animation while the Dock is visible.
struct SpeedTestActivityIcon: View {
    var value: Double? = nil
    var isRunning = false
    var phase: SpeedTestPhase? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NativeSpeedTestActivityIcon(value: value, isRunning: isRunning,
                                   isUpload: phase == .upload, reduceMotion: reduceMotion)
            .frame(width: 35, height: 38)
            .accessibilityHidden(true)
    }
}

private struct NativeSpeedTestActivityIcon: NSViewRepresentable {
    let value: Double?
    let isRunning: Bool
    let isUpload: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> SpeedTestActivityIconNSView {
        SpeedTestActivityIconNSView()
    }

    func updateNSView(_ view: SpeedTestActivityIconNSView, context: Context) {
        view.configure(value: value, isRunning: isRunning, isUpload: isUpload,
                       reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: SpeedTestActivityIconNSView, coordinator: ()) {
        view.stopAnimations()
    }
}

private final class SpeedTestActivityIconNSView: DockMusicAnimationNSView {
    private let badge = CALayer()
    private let border = CAShapeLayer()
    private let track = CAShapeLayer()
    private let accent = CAShapeLayer()
    private let needle = CALayer()
    private let hub = CALayer()
    private let pulse = CAShapeLayer()
    private var value: Double?
    private var isRunning = false
    private var isUpload = false
    private var reduceMotion = false
    private var configured = false

    private let teal = NSColor(calibratedRed: 0.27, green: 0.82, blue: 0.81, alpha: 1).cgColor
    private let purple = NSColor(calibratedRed: 0.64, green: 0.57, blue: 0.94, alpha: 1).cgColor
    private static let pulseKey = "speedtest.activity-pulse"
    private static let needleKey = "speedtest.reading-needle"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        badge.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.11, blue: 0.13, alpha: 1).cgColor
        badge.cornerRadius = 10
        badge.masksToBounds = true
        border.fillColor = nil
        border.lineWidth = 1
        track.fillColor = nil
        track.strokeColor = NSColor.white.withAlphaComponent(0.72).cgColor
        track.lineWidth = 1.65
        track.lineCap = .round
        accent.fillColor = nil
        accent.lineWidth = 1.9
        accent.lineCap = .round
        pulse.fillColor = nil
        pulse.lineWidth = 1.2
        pulse.opacity = 0
        needle.backgroundColor = teal
        needle.cornerRadius = 1
        hub.backgroundColor = NSColor.white.cgColor
        hub.cornerRadius = 2
        [badge, pulse].forEach(layer!.addSublayer)
        [border, track, accent].forEach(badge.addSublayer)
        badge.addSublayer(needle)
        badge.addSublayer(hub)
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(value: Double?, isRunning: Bool, isUpload: Bool, reduceMotion: Bool) {
        let next = value.flatMap { $0.isFinite ? max(0, $0) : nil }
        let changedNeedle = configured && self.value != next
        let changedActivity = !configured || self.isRunning != isRunning
            || self.isUpload != isUpload || self.reduceMotion != reduceMotion
        self.value = next
        self.isRunning = isRunning
        self.isUpload = isUpload
        self.reduceMotion = reduceMotion
        configured = true
        updateDrawing(animateNeedle: changedNeedle)
        if changedActivity { updateActivity() }
    }

    override func layout() {
        super.layout()
        updateDrawing(animateNeedle: false)
    }

    override func visibilityChanged() {
        if animationIsVisible { updateActivity() }
        else { stopAnimations() }
    }
    override func stopAnimations() {
        pulse.removeAnimation(forKey: Self.pulseKey)
        pulse.removeAnimation(forKey: "speedtest.activity-fade")
        needle.removeAnimation(forKey: Self.needleKey)
    }

    private func updateDrawing(animateNeedle: Bool) {
        let bounds = CGRect(origin: .zero, size: CGSize(width: 32, height: 32))
        let previousAngle = (needle.presentation() ?? needle).value(forKeyPath: "transform.rotation.z") as? CGFloat
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = CGRect(x: 1.5, y: 3, width: 32, height: 32)
        pulse.frame = CGRect(x: 1.5, y: 3, width: 32, height: 32)
        pulse.path = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 31, height: 31),
                            cornerWidth: 10, cornerHeight: 10, transform: nil)
        pulse.strokeColor = activeColor.withAlphaComponent(0.7).cgColor
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                             cornerWidth: 10, cornerHeight: 10, transform: nil)
        border.strokeColor = activeColor.withAlphaComponent(isRunning ? 0.5 : 0.28).cgColor
        track.frame = bounds
        track.path = Self.gaugePath(in: bounds, from: 180, to: 0, inset: 5.5)
        accent.frame = bounds
        let fraction = SpeedTestGaugeScale.fraction(value)
        accent.path = Self.gaugePath(in: bounds, from: 180, to: 180 - 180 * fraction, inset: 5.5)
        accent.strokeColor = activeColor.cgColor
        needle.bounds = CGRect(x: 0, y: 0, width: 1.7, height: 9.5)
        needle.position = CGPoint(x: 16, y: 10)
        needle.anchorPoint = CGPoint(x: 0.5, y: 0)
        needle.backgroundColor = activeColor.cgColor
        needle.cornerRadius = 0.85
        let fractionAngle = (90 - 180 * fraction) * .pi / 180
        needle.setAffineTransform(CGAffineTransform(rotationAngle: fractionAngle))
        hub.bounds = CGRect(x: 0, y: 0, width: 4.4, height: 4.4)
        hub.position = CGPoint(x: 16, y: 10)
        hub.backgroundColor = NSColor.white.cgColor
        CATransaction.commit()

        if animateNeedle, animationIsVisible, !reduceMotion {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previousAngle ?? fractionAngle
            animation.toValue = fractionAngle
            animation.duration = 0.35
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            needle.add(animation, forKey: Self.needleKey)
        } else {
            needle.removeAnimation(forKey: Self.needleKey)
        }
    }

    private func updateActivity() {
        pulse.removeAnimation(forKey: Self.pulseKey)
        pulse.removeAnimation(forKey: "speedtest.activity-fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse.opacity = isRunning && reduceMotion ? 0.35 : 0
        CATransaction.commit()
        guard isRunning, !reduceMotion, animationIsVisible else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 1.2
        animation.duration = 1.1
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.autoreverses = false
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        pulse.add(animation, forKey: Self.pulseKey)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        fade.duration = 1.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.repeatCount = .infinity
        pulse.add(fade, forKey: "speedtest.activity-fade")
    }

    private var activeColor: NSColor { isUpload ? NSColor(cgColor: purple)! : NSColor(cgColor: teal)! }

    private static func gaugePath(in bounds: CGRect, from start: Double, to end: Double, inset: CGFloat) -> CGPath {
        let radius = min(bounds.width, bounds.height) / 2 - inset
        let center = CGPoint(x: bounds.midX, y: 10)
        let path = CGMutablePath()
        let segments = max(1, Int(abs(end - start).rounded(.up)))
        for index in 0...segments {
            let angle = (start + (end - start) * Double(index) / Double(segments)) * .pi / 180
            let point = CGPoint(x: center.x + cos(angle) * radius,
                                y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
