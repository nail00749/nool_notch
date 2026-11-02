import AppKit

/// A fresh SpriteKit scene's actual geometry and textures, shared by both prototype backends.
/// This is an initial state, not an export of an already advancing scene's clocks or energy.
struct LiveWallpaperPlexusSeed {
    struct Cloud {
        let base: CGPoint
        let size: CGSize
        let depth: CGFloat
        let color: NSColor
        let alpha: CGFloat
    }

    struct Particle {
        let position: CGPoint
        let velocity: CGVector
        let drift: CGVector
        let depth: CGFloat
        let size: CGSize
        let color: NSColor
        let alpha: CGFloat
    }

    let size: CGSize
    let settings: LiveWallpaperSceneSettings
    let gradient: CGImage
    let glow: CGImage
    let backgroundSize: CGSize
    let clouds: [Cloud]
    let particles: [Particle]
}

struct LiveWallpaperPlexusFrame {
    struct Sprite {
        let center: CGPoint
        let size: CGSize
        /// Straight device RGB and opacity; the renderer multiplies the texture's alpha once.
        let color: SIMD4<Float>
    }

    let size: CGSize
    let backgroundCenter: CGPoint
    let backgroundSize: CGSize
    /// Additive sprites, in the same order as SpriteKit: all clouds, then particles.
    let sprites: [Sprite]
    let lines: [LiveWallpaperPlexusSegment]
}

/// Numerical equivalent of the Plexus branch of LiveWallpaperParticleScene.
/// The presentation view owns the clock; pausing does not discard this simulation.
@MainActor
final class LiveWallpaperPlexusSimulation {
    private struct Particle {
        var position: CGPoint
        var velocity: CGVector
        let drift: CGVector
        let depth: CGFloat
    }

    private let seed: LiveWallpaperPlexusSeed
    private var settings: LiveWallpaperSceneSettings
    private var particles: [Particle]
    private var sprites: [LiveWallpaperPlexusFrame.Sprite]
    private var colors: [SIMD4<Float>]
    private var parallax = CGVector.zero
    private var elapsed: CGFloat = 0
    private var lastUpdate: TimeInterval?
    private var targetEnergy: CGFloat = 0
    private var energy: CGFloat = 0
    private var tintedEnergy: CGFloat = 0
    private var linkClock = LiveWallpaperLinkClock()
    private var links = LiveWallpaperPlexusLinks()
    private var segments: [LiveWallpaperPlexusSegment] = []
    private(set) var frame: LiveWallpaperPlexusFrame

    init(seed: LiveWallpaperPlexusSeed) {
        self.seed = seed
        settings = seed.settings
        particles = seed.particles.map {
            Particle(position: $0.position, velocity: $0.velocity, drift: $0.drift, depth: $0.depth)
        }
        colors = seed.clouds.map { Self.rgba($0.color, opacity: $0.alpha) }
            + seed.particles.map { Self.rgba($0.color, opacity: $0.alpha) }
        sprites = zip(seed.clouds, colors).map {
            LiveWallpaperPlexusFrame.Sprite(center: Self.rendered($0.0.base), size: $0.0.size, color: $0.1)
        } + zip(seed.particles, colors.dropFirst(seed.clouds.count)).map {
            LiveWallpaperPlexusFrame.Sprite(center: Self.rendered($0.0.position), size: $0.0.size, color: $0.1)
        }
        frame = LiveWallpaperPlexusFrame(
            size: seed.size, backgroundCenter: Self.rendered(CGPoint(x: seed.size.width / 2, y: seed.size.height / 2)),
            backgroundSize: seed.backgroundSize, sprites: sprites, lines: [])
    }

    func setEnergy(_ value: Double) {
        targetEnergy = CGFloat(value.isFinite ? min(1, max(0, value)) : 0)
    }

    /// Geometry-affecting settings require a new seed. Cursor/FPS changes retain every particle.
    func update(settings: LiveWallpaperSceneSettings) {
        self.settings = settings
    }

    func resumeClock() {
        lastUpdate = nil
        linkClock.reset()
    }

    @discardableResult
    func advance(at currentTime: TimeInterval, cursor: CGPoint?) -> LiveWallpaperPlexusFrame {
        let frameTime = CGFloat(min(1.0 / 15, max(0, currentTime - (lastUpdate ?? currentTime))))
        lastUpdate = currentTime
        energy += (targetEnergy - energy) * (1 - exp(-frameTime * 1.5))
        applyEnergyTint()
        let dt = frameTime * (1 + energy * 1.8)
        elapsed += dt
        let size = seed.size
        let target = LiveWallpaperMotion.parallaxOffset(cursor: cursor, size: size, amount: settings.parallax)
        let smoothing = 1 - exp(-dt * 5)
        parallax.dx += (target.dx - parallax.dx) * smoothing
        parallax.dy += (target.dy - parallax.dy) * smoothing

        for (index, cloud) in seed.clouds.enumerated() {
            let sway = CGFloat(index + 1)
            let center = CGPoint(x: cloud.base.x + parallax.dx * cloud.depth + sin(elapsed * 0.05 * sway) * 60,
                                 y: cloud.base.y + parallax.dy * cloud.depth + cos(elapsed * 0.04 * sway) * 30)
            sprites[index] = .init(center: Self.rendered(center), size: cloud.size, color: colors[index])
        }
        let damping = exp(-dt * 2.2)
        for index in particles.indices {
            updateParticle(at: index, cursor: cursor, dt: dt, damping: damping)
        }
        if linkClock.shouldRefresh(at: currentTime) { updateLinks(cursor: cursor) }
        frame = LiveWallpaperPlexusFrame(
            size: size,
            backgroundCenter: Self.rendered(CGPoint(x: size.width / 2 + parallax.dx * 0.6,
                                                   y: size.height / 2 + parallax.dy * 0.6)),
            backgroundSize: seed.backgroundSize, sprites: sprites, lines: segments)
        return frame
    }

    private func updateParticle(at index: Int, cursor: CGPoint?, dt: CGFloat, damping: CGFloat) {
        let rendered = CGPoint(x: particles[index].position.x + parallax.dx * particles[index].depth,
                               y: particles[index].position.y + parallax.dy * particles[index].depth)
        let push = LiveWallpaperMotion.cursorAcceleration(particle: rendered, cursor: cursor,
            mode: settings.cursorMode, strength: settings.cursorStrength)
        particles[index].velocity.dx = particles[index].drift.dx
            + (particles[index].velocity.dx + push.dx * dt - particles[index].drift.dx) * damping
        particles[index].velocity.dy = particles[index].drift.dy
            + (particles[index].velocity.dy + push.dy * dt - particles[index].drift.dy) * damping
        particles[index].position.x += particles[index].velocity.dx * dt
        particles[index].position.y += particles[index].velocity.dy * dt
        let margin: CGFloat = 40
        if particles[index].position.x < -margin { particles[index].position.x = seed.size.width + margin }
        if particles[index].position.x > seed.size.width + margin { particles[index].position.x = -margin }
        if particles[index].position.y < -margin { particles[index].position.y = seed.size.height + margin }
        if particles[index].position.y > seed.size.height + margin { particles[index].position.y = -margin }
        let center = CGPoint(x: particles[index].position.x + parallax.dx * particles[index].depth,
                             y: particles[index].position.y + parallax.dy * particles[index].depth)
        let spriteIndex = seed.clouds.count + index
        sprites[spriteIndex] = .init(center: Self.rendered(center), size: seed.particles[index].size, color: colors[spriteIndex])
    }

    private func applyEnergyTint() {
        guard abs(energy - tintedEnergy) > 0.03 || (energy < 0.01 && tintedEnergy != 0) else { return }
        tintedEnergy = energy < 0.01 ? 0 : energy
        let warm = NSColor(red: 1, green: 0.45, blue: 0.25, alpha: 1)
        var tints: [NSColor: NSColor] = [:]
        func tint(_ base: NSColor) -> NSColor {
            if let cached = tints[base] { return cached }
            let color = base.blended(withFraction: tintedEnergy * 0.7, of: warm) ?? base
            tints[base] = color
            return color
        }
        for (index, cloud) in seed.clouds.enumerated() {
            colors[index] = Self.rgba(tint(cloud.color), opacity: cloud.alpha)
        }
        for (index, particle) in seed.particles.enumerated() {
            colors[seed.clouds.count + index] = Self.rgba(tint(particle.color), opacity: particle.alpha)
        }
    }

    private func updateLinks(cursor: CGPoint?) {
        segments.removeAll(keepingCapacity: true)
        links.updatePoints(count: particles.count) { sprites[seed.clouds.count + $0].center }
        links.forEachLink { start, end, bucket in
            segments.append(LiveWallpaperPlexusSegment(start: start, end: end, bucket: bucket))
        }
        if let cursor, settings.cursorMode != .off {
            let radiusSquared = LiveWallpaperMotion.cursorRadius * LiveWallpaperMotion.cursorRadius
            links.forEachPoint { point in
                let dx = point.x - cursor.x, dy = point.y - cursor.y
                if dx * dx + dy * dy < radiusSquared {
                    segments.append(LiveWallpaperPlexusSegment(start: cursor, end: point, bucket: 0))
                }
            }
        }
    }

    private static func rgba(_ color: NSColor, opacity: CGFloat) -> SIMD4<Float> {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent),
                     Float(rgb.alphaComponent * opacity))
    }

    /// SKNode stores its rendered position at Float precision, while Scene's logical motion
    /// remains CGFloat. Links also read that rendered node position, rather than logical state.
    private static func rendered(_ position: CGPoint) -> CGPoint {
        CGPoint(x: CGFloat(Float(position.x)), y: CGFloat(Float(position.y)))
    }
}
