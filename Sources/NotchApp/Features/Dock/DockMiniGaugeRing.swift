import AppKit
import QuartzCore
import SwiftUI

/// Only the ring is native: the center icon, value, layout and accessibility
/// remain in DockMiniGauge. A new sample changes strokeEnd once; Core Animation
/// interpolates the same 0.35-second ease-out without SwiftUI frame updates.
struct DockMiniGaugeRing: NSViewRepresentable {
    let fraction: Double?
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> DockMiniGaugeRingNSView { DockMiniGaugeRingNSView() }

    func updateNSView(_ view: DockMiniGaugeRingNSView, context: Context) {
        view.configure(fraction: fraction, color: color.resolve(in: context.environment).cgColor, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: DockMiniGaugeRingNSView, coordinator: ()) { view.stopAnimation() }
}

final class DockMiniGaugeRingNSView: NSView {
    static let animationDuration: CFTimeInterval = 0.35
    static let animationKey = "gauge.fraction"
    static let colorAnimationKey = "gauge.color"
    let track = CAShapeLayer()
    let fill = CAShapeLayer()
    private var fraction: Double?
    private var reduceMotion = false
    private var hasSample = false
    private var windowVisibility: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // SwiftUI's stroke is centered on the 28-point Circle path, extending
        // 1.5 points outside its frame. Preserve that outline instead of insetting.
        clipsToBounds = false
        layer?.masksToBounds = false
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineWidth = 3
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        fill.lineCap = .round
        fill.isHidden = true
        setAccessibilityElement(false)
    }

    convenience init() { self.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var animationIsVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    func configure(fraction: Double?, color: CGColor, reduceMotion: Bool) {
        let next = fraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        let changed = self.fraction != next
        let animate = hasSample && self.fraction != nil && next != nil && changed
            && animationIsVisible && !reduceMotion
        // A presentation layer can still contain its old default before the
        // first transaction commits. Consult it only for an active transition.
        let previous = fill.animation(forKey: Self.animationKey) == nil
            ? fill.strokeEnd : (fill.presentation()?.strokeEnd ?? fill.strokeEnd)
        let previousColor = fill.animation(forKey: Self.colorAnimationKey) == nil
            ? fill.strokeColor : (fill.presentation()?.strokeColor ?? fill.strokeColor)
        let colorChanged = fill.strokeColor != color
        self.fraction = next
        self.reduceMotion = reduceMotion
        hasSample = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeColor = color
        fill.isHidden = next == nil
        fill.strokeEnd = next ?? 0
        CATransaction.commit()

        if animate, let next {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = previous
            animation.toValue = next
            animation.duration = Self.animationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fill.add(animation, forKey: Self.animationKey)
            if colorChanged, let previousColor {
                let transition = CABasicAnimation(keyPath: "strokeColor")
                transition.fromValue = previousColor
                transition.toValue = color
                transition.duration = Self.animationDuration
                transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fill.add(transition, forKey: Self.colorAnimationKey)
            }
        } else if changed || reduceMotion || !animationIsVisible {
            stopAnimation()
        } else if colorChanged {
            fill.removeAnimation(forKey: Self.colorAnimationKey)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.frame = bounds
        updateContentsScale()
        track.path = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
                    radius: min(bounds.width, bounds.height) / 2,
                    startAngle: .pi / 2, endAngle: -.pi * 1.5, clockwise: true)
        fill.path = path
        CATransaction.commit()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        windowVisibility = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        stopAnimation()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if let window {
            windowVisibility = window.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                                                  name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        visibilityChanged()
    }

    override func viewDidHide() { super.viewDidHide(); visibilityChanged() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 1
        track.contentsScale = scale
        fill.contentsScale = scale
    }

    @objc private func visibilityChanged() { if !animationIsVisible { stopAnimation() } }
    func stopAnimation() {
        fill.removeAnimation(forKey: Self.animationKey)
        fill.removeAnimation(forKey: Self.colorAnimationKey)
    }
}
