import AppKit
import QuartzCore

/// Hosts the Dock content so its layer can be warped as a whole while the window frame
/// stays put (`DockWindowCoordinator` owns the frame).
final class DockGenieContainerView: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Genie-style show and hide for the Dock: the strip funnels into the screen edge it lives on,
/// narrowing towards that edge as it slides into it. Everything runs as Core Animation on the
/// render server, so SwiftUI is not re-rendered per frame.
@MainActor
final class DockGenieAnimator {
    static let hideDuration: CFTimeInterval = 0.26
    static let showDuration: CFTimeInterval = 0.32
    private static let key = "nool.dock.genie"

    private(set) var isHiding = false
    private var generation = 0

    /// Shows from the collapsed state, or reverses a hide that is still running.
    func show(_ view: NSView?, position: DockPosition, animated: Bool) {
        generation += 1
        isHiding = false
        guard let layer = view?.layer, let view else { return }
        guard animated else { reset(layer); return }
        let from = currentProgress(layer) ?? 1
        run(layer, view: view, position: position, from: from, to: 0, duration: Self.showDuration * Double(from),
            timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)) {}
    }

    /// Collapses into the edge, then calls `completion` unless a show or reset came first.
    func hide(_ view: NSView?, position: DockPosition, animated: Bool, completion: @escaping () -> Void) {
        guard !isHiding else { return }
        generation += 1
        let token = generation
        guard animated, let view, let layer = view.layer else { completion(); return }
        isHiding = true
        let from = currentProgress(layer) ?? 0
        run(layer, view: view, position: position, from: from, to: 1, duration: Self.hideDuration * Double(1 - from),
            timing: CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.45)) { [weak self] in
            guard let self, self.generation == token else { return }
            self.isHiding = false
            completion()
            // The window is gone; leave the layer ready for an instant show.
            self.reset(layer)
        }
    }

    /// Cancels any animation, e.g. when the Dock is disabled or the Mac sleeps.
    func cancel(_ view: NSView?) {
        generation += 1
        isHiding = false
        if let layer = view?.layer { reset(layer) }
    }

    private func currentProgress(_ layer: CALayer) -> CGFloat? {
        guard layer.animation(forKey: Self.key) != nil else { return nil }
        // Approximates the in-flight value from opacity, which tracks progress linearly.
        let presented = CGFloat(layer.presentation()?.opacity ?? layer.opacity)
        return min(1, max(0, 1 - presented))
    }

    private func run(_ layer: CALayer, view: NSView, position: DockPosition, from: CGFloat, to: CGFloat,
                     duration: CFTimeInterval, timing: CAMediaTimingFunction, completion: @escaping () -> Void) {
        let size = view.bounds.size
        let anchor = CGPoint(x: layer.anchorPoint.x * size.width, y: layer.anchorPoint.y * size.height)
        let flipped = view.isFlipped
        func transform(_ value: CGFloat) -> CATransform3D {
            Self.transform(progress: value, size: size, position: position, anchor: anchor, flipped: flipped)
        }
        // Keyframes so the funnel bends in progressively instead of interpolating matrices linearly.
        let steps = 12
        let values = (0...steps).map { step -> CGFloat in from + (to - from) * CGFloat(step) / CGFloat(steps) }
        let warp = CAKeyframeAnimation(keyPath: "sublayerTransform")
        warp.values = values.map { NSValue(caTransform3D: transform($0)) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = values.map { Float(1 - $0) }
        let group = CAAnimationGroup()
        group.animations = [warp, fade]
        group.duration = max(0.05, duration)
        group.timingFunction = timing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        layer.sublayerTransform = transform(to)
        layer.opacity = Float(1 - to)
        layer.add(group, forKey: Self.key)
        CATransaction.commit()
    }

    private func reset(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.key)
        layer.sublayerTransform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    /// The warp at `progress` (0 shown, 1 collapsed) in the layer's own coordinates, where
    /// `anchor` is the layer's anchor point in points.
    nonisolated static func transform(progress: CGFloat, size: CGSize, position: DockPosition,
                                      anchor: CGPoint, flipped: Bool) -> CATransform3D {
        let t = min(1, max(0, progress))
        guard t > 0, size.width > 0, size.height > 0 else { return CATransform3DIdentity }
        // Pivot on the screen edge the Dock is attached to.
        let bottomY = flipped ? size.height : 0
        let pivot: CGPoint
        var scaleX: CGFloat = 1, scaleY: CGFloat = 1
        var slide = CGPoint.zero
        var rotation = CATransform3DIdentity
        let tilt = 1.05 * t // radians, ~60° at the end
        switch position {
        case .bottom:
            pivot = CGPoint(x: size.width / 2, y: bottomY)
            scaleX = 1 - 0.78 * t
            scaleY = 1 - 0.5 * t
            slide.y = (flipped ? 1 : -1) * size.height * 0.55 * t
            // The far side comes towards the viewer: wide at the top, narrow at the edge.
            rotation = CATransform3DMakeRotation(flipped ? -tilt : tilt, 1, 0, 0)
        case .left:
            pivot = CGPoint(x: 0, y: size.height / 2)
            scaleX = 1 - 0.5 * t
            scaleY = 1 - 0.78 * t
            slide.x = -size.width * 0.55 * t
            rotation = CATransform3DMakeRotation(-tilt, 0, 1, 0)
        case .right:
            pivot = CGPoint(x: size.width, y: size.height / 2)
            scaleX = 1 - 0.5 * t
            scaleY = 1 - 0.78 * t
            slide.x = size.width * 0.55 * t
            rotation = CATransform3DMakeRotation(tilt, 0, 1, 0)
        }
        let offset = CGPoint(x: pivot.x - anchor.x, y: pivot.y - anchor.y)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 240
        var result = CATransform3DMakeTranslation(-offset.x, -offset.y, 0)
        result = CATransform3DConcat(result, CATransform3DMakeScale(scaleX, scaleY, 1))
        result = CATransform3DConcat(result, rotation)
        result = CATransform3DConcat(result, perspective)
        result = CATransform3DConcat(result, CATransform3DMakeTranslation(offset.x + slide.x, offset.y + slide.y, 0))
        return result
    }
}
