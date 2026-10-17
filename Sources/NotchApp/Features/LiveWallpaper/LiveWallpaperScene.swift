import AppKit
import SpriteKit

/// Motion rules for scene wallpapers, separate from SpriteKit so they can be tested.
enum LiveWallpaperMotion {
    static let cursorRadius: CGFloat = 220
    static let maxParallaxShift: CGFloat = 36

    /// Acceleration in points per second² that the cursor applies to a particle; zero outside the radius.
    static func cursorAcceleration(particle: CGPoint, cursor: CGPoint?, mode: LiveWallpaperCursorMode,
                                   strength: Double, radius: CGFloat = cursorRadius) -> CGVector {
        guard let cursor, mode != .off, strength > 0 else { return .zero }
        let dx = particle.x - cursor.x
        let dy = particle.y - cursor.y
        let distance = hypot(dx, dy)
        guard distance > 0.5, distance < radius else { return .zero }
        let falloff = pow(1 - distance / radius, 2)
        let magnitude = CGFloat(strength) * 2_600 * falloff * (mode == .repel ? 1 : -1)
        return CGVector(dx: dx / distance * magnitude, dy: dy / distance * magnitude)
    }

    /// Layers move against the cursor; deeper layers (`depth` > 1) move more. No cursor means centered.
    static func parallaxOffset(cursor: CGPoint?, size: CGSize, amount: Double, depth: CGFloat = 1) -> CGVector {
        guard let cursor, size.width > 0, size.height > 0, amount > 0 else { return .zero }
        let nx = min(1, max(-1, (cursor.x / size.width - 0.5) * 2))
        let ny = min(1, max(-1, (cursor.y / size.height - 0.5) * 2))
        let shift = CGFloat(amount) * maxParallaxShift * depth
        return CGVector(dx: -nx * shift, dy: -ny * shift)
    }

    /// Particle count scales with screen area, so a super-ultrawide display is not denser than a laptop.
    static func particleCount(style: LiveWallpaperParticleStyle, size: CGSize, density: Double) -> Int {
        let perMegapoint: Double
        switch style {
        case .none: return 0
        case .stars: perMegapoint = 220
        case .fireflies: perMegapoint = 40
        case .plexus: perMegapoint = 50
        case .snow: perMegapoint = 120
        case .embers: perMegapoint = 60
        }
        let area = Double(max(0, size.width) * max(0, size.height)) / 1_000_000
        let limit = style == .plexus ? 160 : 900
        return min(limit, max(8, Int((perMegapoint * area * density).rounded())))
    }
}

/// One display's scene: a background (preset gradient or picture), particles and cursor interaction.
/// The cursor is read from `NSEvent.mouseLocation`, so the click-through window needs no permissions.
@MainActor
final class LiveWallpaperParticleScene: SKScene {
    private struct Particle {
        let node: SKSpriteNode
        var position: CGPoint
        var velocity: CGVector
        var drift: CGVector
        let depth: CGFloat
        let phase: CGFloat
        let baseAlpha: CGFloat
        var life: CGFloat
    }

    private let content: LiveWallpaperContent
    private var screenFrame: CGRect
    private var settings: LiveWallpaperSceneSettings
    private var background: SKSpriteNode?
    private let particleLayer = SKNode()
    private var lineNodes: [SKShapeNode] = []
    private var particles: [Particle] = []
    private var style: LiveWallpaperParticleStyle = .none
    private var parallax = CGVector.zero
    private var lastUpdate: TimeInterval?
    private var lastLinkUpdate: CGFloat = -1
    private var elapsed: CGFloat = 0
    private var nextShootingStar: CGFloat = 4
    private var image: CGImage?
    private var glows: [(node: SKSpriteNode, depth: CGFloat, base: CGPoint)] = []

    init(size: CGSize, screenFrame: CGRect, content: LiveWallpaperContent, settings: LiveWallpaperSceneSettings) {
        self.content = content
        self.screenFrame = screenFrame
        self.settings = settings
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .black
        if case .image(let url) = content {
            let backing = NSScreen.screens.first { $0.frame == screenFrame }?.backingScaleFactor ?? 2
            image = LiveWallpaperMedia.image(at: url, maxPixelSize: max(size.width, size.height) * backing * 1.1)
        }
        particleLayer.zPosition = 10
        addChild(particleLayer)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(settings next: LiveWallpaperSceneSettings, screenFrame frame: CGRect) {
        let needsRebuild = next.density != settings.density || next.imageParticles != settings.imageParticles
            || next.parallax != settings.parallax || frame.size != screenFrame.size
        settings = next
        screenFrame = frame
        if needsRebuild { rebuild() }
    }

    /// Resets timing after a pause so particles do not jump.
    func resumeClock() { lastUpdate = nil }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard oldSize != size, oldSize != .zero else { return }
        rebuild()
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(1.0 / 15, max(0, currentTime - (lastUpdate ?? currentTime))))
        lastUpdate = currentTime
        elapsed += dt
        let cursor = localCursor()

        let target = LiveWallpaperMotion.parallaxOffset(cursor: cursor, size: size, amount: settings.parallax)
        let smoothing = 1 - exp(-dt * 5)
        parallax.dx += (target.dx - parallax.dx) * smoothing
        parallax.dy += (target.dy - parallax.dy) * smoothing
        background?.position = CGPoint(x: size.width / 2 + parallax.dx * 0.6, y: size.height / 2 + parallax.dy * 0.6)
        for (index, glow) in glows.enumerated() {
            let sway = CGFloat(index + 1)
            glow.node.position = CGPoint(x: glow.base.x + parallax.dx * glow.depth + sin(elapsed * 0.05 * sway) * 60,
                                         y: glow.base.y + parallax.dy * glow.depth + cos(elapsed * 0.04 * sway) * 30)
        }

        let damping = exp(-dt * 2.2)
        for index in particles.indices {
            var particle = particles[index]
            let rendered = CGPoint(x: particle.position.x + parallax.dx * particle.depth,
                                   y: particle.position.y + parallax.dy * particle.depth)
            let push = LiveWallpaperMotion.cursorAcceleration(
                particle: rendered, cursor: cursor, mode: settings.cursorMode, strength: settings.cursorStrength)
            particle.velocity.dx = particle.drift.dx + (particle.velocity.dx + push.dx * dt - particle.drift.dx) * damping
            particle.velocity.dy = particle.drift.dy + (particle.velocity.dy + push.dy * dt - particle.drift.dy) * damping
            particle.position.x += particle.velocity.dx * dt
            particle.position.y += particle.velocity.dy * dt
            animate(&particle, dt: dt)
            wrap(&particle)
            particle.node.position = CGPoint(x: particle.position.x + parallax.dx * particle.depth,
                                             y: particle.position.y + parallax.dy * particle.depth)
            particles[index] = particle
        }
        // Re-tessellating the line shapes is the costly part, so links refresh at most 30 times a second.
        if style == .plexus, elapsed - lastLinkUpdate >= 1.0 / 31 || lastLinkUpdate > elapsed {
            lastLinkUpdate = elapsed
            drawLinks()
        }
        if style == .stars, case .scene = content { updateShootingStars(dt: dt) }
    }

    // MARK: Building

    private func rebuild() {
        background?.removeFromParent()
        background = makeBackground()
        if let background { addChild(background) }
        style = {
            switch content {
            case .scene(let preset): preset.particles
            case .image: settings.imageParticles
            case .video: .none
            }
        }()
        for glow in glows { glow.node.removeFromParent() }
        glows = makeGlows()
        for glow in glows { addChild(glow.node) }
        particleLayer.removeAllChildren()
        lineNodes = []
        particles = (0..<LiveWallpaperMotion.particleCount(style: style, size: size, density: settings.density))
            .map { _ in makeParticle(spawnAnywhere: true) }
        for particle in particles { particleLayer.addChild(particle.node) }
        if style == .plexus {
            lineNodes = [0.22, 0.14, 0.07].map { alpha in
                let node = SKShapeNode()
                node.strokeColor = NSColor(red: 0.45, green: 0.85, blue: 1, alpha: alpha)
                node.lineWidth = 1
                node.isAntialiased = true
                node.zPosition = 5
                particleLayer.addChild(node)
                return node
            }
        }
    }

    private func makeBackground() -> SKSpriteNode? {
        guard size.width > 0, size.height > 0 else { return nil }
        let margin = CGFloat(settings.parallax) * LiveWallpaperMotion.maxParallaxShift * 2 + 4
        let node: SKSpriteNode
        switch content {
        case .image:
            guard let image else { return nil }
            let texture = SKTexture(cgImage: image)
            let imageSize = CGSize(width: image.width, height: image.height)
            let scale = max((size.width + margin) / imageSize.width, (size.height + margin) / imageSize.height)
            node = SKSpriteNode(texture: texture, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
        case .scene(let preset):
            node = SKSpriteNode(texture: Self.gradientTexture(preset),
                                size: CGSize(width: size.width + margin, height: size.height + margin))
        case .video:
            return nil
        }
        node.position = CGPoint(x: size.width / 2, y: size.height / 2)
        node.zPosition = 0
        return node
    }

    /// Large faint color clouds behind the particles of built-in scenes; they give the gradient depth.
    private func makeGlows() -> [(node: SKSpriteNode, depth: CGFloat, base: CGPoint)] {
        guard case .scene(let preset) = content, size.width > 0 else { return [] }
        let tints: [NSColor]
        switch preset {
        case .starfield: tints = [NSColor(red: 0.45, green: 0.25, blue: 0.9, alpha: 1), NSColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 1)]
        case .fireflies: tints = [NSColor(red: 0.3, green: 0.75, blue: 0.35, alpha: 1), NSColor(red: 0.6, green: 0.8, blue: 0.2, alpha: 1)]
        case .plexus: tints = [NSColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1), NSColor(red: 0.35, green: 0.3, blue: 0.9, alpha: 1)]
        case .snow: tints = [NSColor(white: 1, alpha: 1), NSColor(red: 0.6, green: 0.75, blue: 1, alpha: 1)]
        case .embers: tints = [NSColor(red: 1, green: 0.35, blue: 0.08, alpha: 1), NSColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1)]
        }
        let count = max(3, Int(size.width / 700))
        return (0..<count).map { index in
            let node = SKSpriteNode(texture: Self.glowTexture)
            let diameter = CGFloat.random(in: 0.5...0.9) * size.height * 1.4
            node.size = CGSize(width: diameter * CGFloat.random(in: 1.2...1.8), height: diameter)
            node.color = tints[index % tints.count]
            node.colorBlendFactor = 1
            node.alpha = CGFloat.random(in: 0.10...0.18)
            node.blendMode = .add
            node.zPosition = 1
            let base = CGPoint(x: (CGFloat(index) + CGFloat.random(in: 0.2...0.8)) / CGFloat(count) * size.width,
                               y: CGFloat.random(in: 0.25...0.8) * size.height)
            node.position = base
            return (node, 0.3, base)
        }
    }

    private func makeParticle(spawnAnywhere: Bool) -> Particle {
        let depth = CGFloat.random(in: 0.35...1.6)
        let node = SKSpriteNode(texture: Self.glowTexture)
        var drift = CGVector.zero
        var diameter: CGFloat = 4
        var color = NSColor.white
        var alpha: CGFloat = 0.8
        node.blendMode = .add
        switch style {
        case .stars:
            diameter = CGFloat.random(in: 2...6) * depth
            color = NSColor(red: 0.85, green: 0.9, blue: 1, alpha: 1)
            alpha = CGFloat.random(in: 0.35...0.95)
            drift = CGVector(dx: -2 * depth, dy: 0)
        case .fireflies:
            diameter = CGFloat.random(in: 12...26) * depth
            color = NSColor(red: 0.78, green: 1, blue: 0.45, alpha: 1)
            alpha = CGFloat.random(in: 0.5...0.9)
            drift = CGVector(dx: CGFloat.random(in: -14...14), dy: CGFloat.random(in: -10...12))
        case .plexus:
            diameter = CGFloat.random(in: 5...9)
            color = NSColor(red: 0.5, green: 0.9, blue: 1, alpha: 1)
            alpha = 0.9
            drift = CGVector(dx: CGFloat.random(in: -18...18), dy: CGFloat.random(in: -18...18))
        case .snow:
            diameter = CGFloat.random(in: 3...9) * depth
            alpha = CGFloat.random(in: 0.55...0.95)
            node.blendMode = .alpha
            drift = CGVector(dx: CGFloat.random(in: -8...8), dy: -CGFloat.random(in: 25...55) * depth)
        case .embers:
            diameter = CGFloat.random(in: 5...12) * depth
            color = NSColor(red: 1, green: CGFloat.random(in: 0.35...0.6), blue: 0.12, alpha: 1)
            alpha = CGFloat.random(in: 0.6...1)
            drift = CGVector(dx: CGFloat.random(in: -10...10), dy: CGFloat.random(in: 35...90) * depth)
        case .none:
            break
        }
        node.size = CGSize(width: diameter, height: diameter)
        node.color = color
        node.colorBlendFactor = 1
        node.alpha = alpha
        let position: CGPoint
        if spawnAnywhere {
            position = CGPoint(x: CGFloat.random(in: 0...max(1, size.width)), y: CGFloat.random(in: 0...max(1, size.height)))
        } else {
            position = respawnPoint(for: drift)
        }
        node.position = position
        return Particle(node: node, position: position, velocity: drift, drift: drift, depth: depth,
                        phase: CGFloat.random(in: 0...(2 * .pi)), baseAlpha: alpha,
                        life: CGFloat.random(in: 0...1))
    }

    private func respawnPoint(for drift: CGVector) -> CGPoint {
        switch style {
        case .snow: CGPoint(x: CGFloat.random(in: 0...size.width), y: size.height + 10)
        case .embers: CGPoint(x: CGFloat.random(in: 0...size.width), y: -10)
        default: CGPoint(x: CGFloat.random(in: 0...size.width), y: CGFloat.random(in: 0...size.height))
        }
    }

    // MARK: Per-frame behavior

    private func animate(_ particle: inout Particle, dt: CGFloat) {
        switch style {
        case .stars:
            particle.node.alpha = particle.baseAlpha * (0.55 + 0.45 * sin(elapsed * 1.7 + particle.phase))
        case .fireflies:
            particle.node.alpha = particle.baseAlpha * (0.35 + 0.65 * pow(sin(elapsed * 0.9 + particle.phase) * 0.5 + 0.5, 2))
            // Wander: the resting drift slowly turns, so fireflies never move in straight lines.
            let angle = sin(elapsed * 0.3 + particle.phase) * dt * 0.8
            particle.drift = CGVector(dx: particle.drift.dx * cos(angle) - particle.drift.dy * sin(angle),
                                      dy: particle.drift.dx * sin(angle) + particle.drift.dy * cos(angle))
        case .snow:
            particle.position.x += sin(elapsed * 0.8 + particle.phase) * 12 * dt
        case .embers:
            particle.life += dt * 0.18
            particle.node.alpha = particle.baseAlpha * max(0, 1 - particle.life)
            if particle.life >= 1 {
                particle.life = 0
                particle.position = respawnPoint(for: particle.drift)
            }
        case .plexus, .none:
            break
        }
    }

    private func wrap(_ particle: inout Particle) {
        let margin: CGFloat = 40
        if particle.position.x < -margin { particle.position.x = size.width + margin }
        if particle.position.x > size.width + margin { particle.position.x = -margin }
        if particle.position.y < -margin {
            particle.position = style == .snow ? respawnPoint(for: particle.drift) : CGPoint(x: particle.position.x, y: size.height + margin)
        }
        if particle.position.y > size.height + margin {
            particle.position = style == .embers ? respawnPoint(for: particle.drift) : CGPoint(x: particle.position.x, y: -margin)
        }
    }

    /// Links between nearby particles, bucketed by distance so three shape nodes draw every line.
    /// A grid of link-sized cells limits each particle to its neighbours instead of every pair.
    private func drawLinks() {
        let maxDistance: CGFloat = 170
        let maxDistanceSquared = maxDistance * maxDistance
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        let points = particles.map(\.node.position)
        struct Cell: Hashable { let x: Int, y: Int }
        func cell(of point: CGPoint) -> Cell {
            Cell(x: Int((point.x / maxDistance).rounded(.down)), y: Int((point.y / maxDistance).rounded(.down)))
        }
        var grid: [Cell: [Int]] = [:]
        for index in points.indices { grid[cell(of: points[index]), default: []].append(index) }
        for i in points.indices {
            let home = cell(of: points[i])
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let neighbours = grid[Cell(x: home.x + dx, y: home.y + dy)] else { continue }
                    for j in neighbours where j > i {
                        let distanceSquared = (points[i].x - points[j].x) * (points[i].x - points[j].x)
                            + (points[i].y - points[j].y) * (points[i].y - points[j].y)
                        guard distanceSquared < maxDistanceSquared else { continue }
                        let bucket = min(2, Int(distanceSquared.squareRoot() / maxDistance * 3))
                        paths[bucket].move(to: points[i])
                        paths[bucket].addLine(to: points[j])
                    }
                }
            }
        }
        if let cursor = localCursor(), settings.cursorMode != .off {
            for point in points where hypot(point.x - cursor.x, point.y - cursor.y) < LiveWallpaperMotion.cursorRadius {
                paths[0].move(to: cursor)
                paths[0].addLine(to: point)
            }
        }
        for (node, path) in zip(lineNodes, paths) { node.path = path }
    }

    private func updateShootingStars(dt: CGFloat) {
        nextShootingStar -= dt
        guard nextShootingStar <= 0, size.width > 0 else { return }
        nextShootingStar = CGFloat.random(in: 5...12)
        let streak = SKSpriteNode(color: NSColor(white: 1, alpha: 0.9), size: CGSize(width: 140, height: 1.6))
        streak.blendMode = .add
        streak.zRotation = -.pi / 7
        streak.position = CGPoint(x: CGFloat.random(in: size.width * 0.2...size.width), y: size.height * CGFloat.random(in: 0.65...0.95))
        streak.alpha = 0
        streak.zPosition = 8
        particleLayer.addChild(streak)
        let travel = SKAction.moveBy(x: -size.width * 0.28, y: -size.width * 0.28 * tan(.pi / 7), duration: 1.1)
        let fade = SKAction.sequence([.fadeAlpha(to: 0.9, duration: 0.15), .wait(forDuration: 0.6), .fadeOut(withDuration: 0.35)])
        streak.run(.sequence([.group([travel, fade]), .removeFromParent()]))
    }

    private func localCursor() -> CGPoint? {
        let location = NSEvent.mouseLocation
        guard screenFrame.contains(location) else { return nil }
        return CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY)
    }

    // MARK: Textures

    private static let glowTexture: SKTexture = {
        let side = 64
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [
                  CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                  CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                  CGColor(red: 1, green: 1, blue: 1, alpha: 0)
              ] as CFArray, locations: [0, 0.35, 1]) else { return SKTexture() }
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: CGFloat(side) / 2, options: [])
        return context.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }()

    private static func gradientTexture(_ preset: LiveWallpaperScenePreset) -> SKTexture {
        let space = CGColorSpaceCreateDeviceRGB()
        let (top, bottom) = preset.gradient
        guard let context = CGContext(data: nil, width: 4, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [
                  CGColor(red: bottom.x, green: bottom.y, blue: bottom.z, alpha: 1),
                  CGColor(red: top.x, green: top.y, blue: top.z, alpha: 1)
              ] as CFArray, locations: [0, 1]) else { return SKTexture() }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        return context.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
    }
}
