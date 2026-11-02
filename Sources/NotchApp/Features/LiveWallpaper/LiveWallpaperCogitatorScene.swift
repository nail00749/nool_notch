import AppKit
import SpriteKit

/// Tuning of the «Когитатор» shrine.
enum LiveWallpaperCogitatorRules {
    static let dwellTolerance: CGFloat = 8
    static let dwellDuration: CGFloat = 2
    static let chargeDuration: CGFloat = 1.5
    static let rearmDistance: CGFloat = 60
    static let riteCooldown: CGFloat = 12
    /// Holding the cursor this close to the cogitator's skull asks for the blessing instead of a purification.
    static let blessingRadius: CGFloat = 170
    static let relightDelay: ClosedRange<CGFloat> = 4...7

    /// Screen interference from cursor speed: none below 300 pt/s, full at 2500 pt/s.
    static func interference(speed: CGFloat) -> CGFloat {
        min(1, max(0, (speed - 300) / 2_200))
    }

    /// The cursor speed that snuffs a candle it passes; a stronger cursor puts candles out more easily.
    static func snuffSpeed(strength: Double) -> CGFloat {
        1_400 / CGFloat(0.4 + min(1, max(0, strength)))
    }

    /// Where a bionic eye looks: up to a third of its radius toward the cursor.
    static func gaze(eye: CGPoint, cursor: CGPoint?, radius: CGFloat) -> CGVector {
        guard let cursor else { return .zero }
        let dx = cursor.x - eye.x, dy = cursor.y - eye.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return .zero }
        let reach = radius * 0.35 * min(1, length / 240)
        return CGVector(dx: dx / length * reach, dy: dy / length * reach)
    }

    /// Distance from `point` to the segment the cursor swept this frame.
    static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + dx * t), point.y - (start.y + dy * t))
    }
}

/// Holding the cursor still charges a rite; it fires once and rearms only after the cursor moves away.
struct LiveWallpaperCogitatorDwell {
    private(set) var stillTime: CGFloat = 0
    private(set) var isArmed = true
    private var anchor: CGPoint?
    private var firedAt: CGPoint?

    /// Returns the charge, 0...1.
    mutating func advance(cursor: CGPoint?, dt: CGFloat, ready: Bool) -> CGFloat {
        typealias Rules = LiveWallpaperCogitatorRules
        guard let cursor else {
            anchor = nil
            stillTime = 0
            return 0
        }
        if !isArmed, let firedAt, hypot(cursor.x - firedAt.x, cursor.y - firedAt.y) > Rules.rearmDistance {
            isArmed = true
            self.firedAt = nil
        }
        if let anchor, hypot(cursor.x - anchor.x, cursor.y - anchor.y) <= Rules.dwellTolerance {
            stillTime += dt
        } else {
            anchor = cursor
            stillTime = 0
        }
        guard isArmed, ready else { return 0 }
        return min(1, max(0, (stillTime - Rules.dwellDuration) / Rules.chargeDuration))
    }

    mutating func fire() {
        isArmed = false
        firedAt = anchor
        stillTime = 0
    }
}

/// «Когитатор»: a gothic machine shrine with green CRT screens, candles and servitor skulls.
/// The skulls' eyes follow the cursor, a fast sweep snuffs candles and jams the screens, and a
/// cursor held still performs a rite. The cursor is read from `NSEvent.mouseLocation`, so the
/// click-through window needs no permissions.
@MainActor
final class LiveWallpaperCogitatorScene: SKScene, LiveWallpaperSpriteScene {
    enum Rite: Equatable { case blessing, purification }

    @MainActor
    private final class Candle {
        let tip: CGPoint
        let height: CGFloat
        let flame = SKSpriteNode(texture: LiveWallpaperCogitatorArt.flame)
        let glow = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
        var smoke: SKEmitterNode?
        let phase = CGFloat.random(in: 0...100)
        var isLit = true
        var relightIn: CGFloat = 0
        var light: CGFloat = 1
        var lean: CGFloat = 0

        init(tip: CGPoint, height: CGFloat) {
            self.tip = tip
            self.height = height
        }
    }

    @MainActor
    private final class Eye {
        let spec: LiveWallpaperShrineLayout.Eye
        let glow = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
        let core = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
        var heat: CGFloat = 0.6

        init(_ spec: LiveWallpaperShrineLayout.Eye) { self.spec = spec }
    }

    @MainActor
    private final class Screen {
        let kind: LiveWallpaperShrineLayout.ScreenKind
        let rect: CGRect
        let effect = SKEffectNode()
        let shader = LiveWallpaperCogitatorCRT.makeShader()
        let noise = SKSpriteNode(texture: LiveWallpaperCogitatorArt.noise[0])
        var glitch: CGFloat = 0
        var spike: CGFloat = 0
        var columns: [(sprite: SKSpriteNode, strip: SKTexture, offset: CGFloat, speed: CGFloat)] = []
        var labels: [SKLabelNode] = []
        var bars: [(node: SKSpriteNode, level: CGFloat)] = []
        let trace = SKShapeNode()
        var samples: [CGFloat] = []
        var clock: CGFloat = 0
        var beat: CGFloat = 0

        init(kind: LiveWallpaperShrineLayout.ScreenKind, rect: CGRect) {
            self.kind = kind
            self.rect = rect
        }
    }

    private typealias Rules = LiveWallpaperCogitatorRules

    private static let chatter: [() -> String] = [
        { "ПОМАЗАНИЕ СВЯЩЕННЫМ МАСЛОМ: ВЫПОЛНЕНО" }, { "ЛОГИЧЕСКИЕ ЭНГРАММЫ: СТАБИЛЬНЫ" }, { "СЕРВИТОР 7-ГАММА: НА ПОСТУ" },
        { "ВОСКУРЕНИЕ ЛАДАНА: \(Int.random(in: 80...100))%" },
        { String(format: "ОТКЛИК НООСФЕРЫ: 0x%04X", Int.random(in: 0..<0xFFFF)) }, { "КАНТ БИНАРИКА: 0110 1101 0111" },
        { "ЛИТАНИЯ ЗАПУСКА: ПРИНЯТА" }, { "ДУХ МАШИНЫ УМИРОТВОРЁН" }, { "ВВЕДИТЕ КОД ДОСТУПА: ****" },
        { let total = Int.random(in: 6...12); return "ПРОВЕРКА ПЕЧАТЕЙ ЧИСТОТЫ: \(total)/\(total)" },
        { String(format: "ВОКС-КАНАЛ %02d: ТИШИНА", Int.random(in: 1...99)) }, { "КАЛИБРОВКА АУСПЕКСА… OK" },
        { "РЕЗЕРВНЫЙ ЛОГИС-ДВИГАТЕЛЬ: ГОТОВ" }, { "СЛАВА ОМНИССИИ" }
    ]

    private(set) var completedUpdateCount: UInt64 = 0
    private(set) var riteCount = 0
    private(set) var lastRite: Rite?
    private(set) var riteCooldownRemaining: CGFloat = 0
    private(set) var interference: CGFloat = 0
    var candleCount: Int { candles.count }
    var litCandleCount: Int { candles.filter(\.isLit).count }
    var screenCount: Int { screens.count }
    var eyeCount: Int { eyes.count }
    var candleTips: [CGPoint] { candles.map(\.tip) }
    var mainSkull: CGPoint { layout.mainSkull }

    private var settings: LiveWallpaperSceneSettings
    private var screenFrame: CGRect
    private let cursorProvider: (() -> CGPoint?)?
    private var energy: CGFloat = 0
    private var targetEnergy: CGFloat = 0
    private var lastUpdate: TimeInterval?
    private var elapsed: CGFloat = 0
    private var unit: CGFloat = 1

    private let world = SKNode()
    private let content = SKNode()
    private var layout = LiveWallpaperShrineLayout()
    private var candles: [Candle] = []
    private var eyes: [Eye] = []
    private var screens: [Screen] = []
    private var lamps: [(node: SKSpriteNode, rate: CGFloat, phase: CGFloat)] = []
    private let terminal = LiveWallpaperCogitatorTerminal()
    private var contacts: [(position: CGPoint, velocity: CGVector)] = []
    private let altarGlow = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
    private let screenSpill = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
    private let dishGlow = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow)
    private let dishSweep = SKSpriteNode(texture: LiveWallpaperCogitatorArt.cone)
    private let chargeRing = SKShapeNode()
    private let chargeArc = SKShapeNode()

    private var parallax = CGVector.zero
    private var previousCursor: CGPoint?
    private var cursorSpeed: CGFloat = 0
    private var dwell = LiveWallpaperCogitatorDwell()
    private var charge: CGFloat = 0
    private var flare: CGFloat = 0
    private var chatterIn: CGFloat = 1.5
    private var sparkIn: CGFloat = 3
    private var blinkIn: CGFloat = 6
    private var blink: CGFloat = 0
    private var jamLoggedAt: CGFloat = -100

    init(size: CGSize, screenFrame: CGRect, settings: LiveWallpaperSceneSettings, cursorProvider: (() -> CGPoint?)? = nil) {
        self.settings = settings.sanitized
        self.screenFrame = screenFrame
        self.cursorProvider = cursorProvider
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .black
        addChild(world)
        world.addChild(content)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: LiveWallpaperSpriteScene

    func update(settings next: LiveWallpaperSceneSettings, screenFrame frame: CGRect) {
        let next = next.sanitized
        let needsRebuild = next.density != settings.density || frame.size != screenFrame.size
        settings = next
        screenFrame = frame
        if needsRebuild { rebuild() }
    }

    func setEnergy(_ value: Double) {
        targetEnergy = CGFloat(value.isFinite ? min(1, max(0, value)) : 0)
    }

    func resumeClock() {
        lastUpdate = nil
    }

    func snapshot(in view: SKView) -> CGImage? {
        view.texture(from: self)?.cgImage()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard oldSize != size, oldSize != .zero else { return }
        rebuild()
    }

    override func didFinishUpdate() {
        super.didFinishUpdate()
        completedUpdateCount &+= 1
    }

    // MARK: Building

    private func rebuild() {
        content.removeAllChildren()
        candles.removeAll()
        eyes.removeAll()
        screens.removeAll()
        lamps.removeAll()
        guard size.width > 1, size.height > 1 else { return }
        unit = min(size.height / 1_080, size.width / 1_728)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        world.position = center
        world.setScale(1.012)
        content.position = CGPoint(x: -center.x, y: -center.y)

        let shrine = LiveWallpaperCogitatorArt.shrine(size: size)
        layout = shrine.layout
        let background = SKSpriteNode(texture: shrine.texture, size: size)
        background.anchorPoint = .zero
        background.zPosition = 0
        content.addChild(background)

        altarGlow.size = CGSize(width: 1_200 * unit, height: 700 * unit)
        altarGlow.position = CGPoint(x: center.x, y: 430 * unit)
        altarGlow.color = NSColor(red: 1, green: 0.6, blue: 0.25, alpha: 1)
        add(altarGlow, z: 1, tinted: true)

        for spec in layout.screens { buildScreen(spec) }
        if let main = screens.first(where: { $0.kind == .main }) {
            screenSpill.size = CGSize(width: main.rect.width * 1.9, height: main.rect.height * 2.2)
            screenSpill.position = CGPoint(x: main.rect.midX, y: main.rect.midY)
            screenSpill.color = NSColor(red: 0.2, green: 1, blue: 0.45, alpha: 1)
            add(screenSpill, z: 1, tinted: true)
        }

        for lamp in layout.lamps {
            let node = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow, size: CGSize(width: 22 * unit, height: 22 * unit))
            node.position = lamp.point
            node.color = lamp.red ? NSColor(red: 1, green: 0.12, blue: 0.05, alpha: 1) : NSColor(red: 0.3, green: 1, blue: 0.4, alpha: 1)
            add(node, z: 4, tinted: true)
            lamps.append((node, .random(in: 0.4...2.2), .random(in: 0...6)))
        }

        dishGlow.size = CGSize(width: layout.dish.radius * 2.6, height: layout.dish.radius * 2.6)
        dishGlow.position = layout.dish.center
        dishGlow.color = NSColor(red: 0.25, green: 1, blue: 0.4, alpha: 1)
        add(dishGlow, z: 4, tinted: true)
        dishSweep.anchorPoint = CGPoint(x: 0, y: 0.5)
        dishSweep.size = CGSize(width: layout.dish.radius * 0.95, height: layout.dish.radius * 0.5)
        dishSweep.position = layout.dish.center
        dishSweep.color = dishGlow.color
        dishSweep.alpha = 0.7
        add(dishSweep, z: 4, tinted: true)

        for (index, spec) in layout.candles.enumerated() {
            let candle = Candle(tip: spec.tip, height: spec.height)
            candle.flame.anchorPoint = CGPoint(x: 0.5, y: 0.04)
            candle.flame.size = CGSize(width: 13 * unit, height: 32 * unit)
            candle.flame.position = spec.tip
            candle.flame.blendMode = .add
            candle.flame.zPosition = 6
            content.addChild(candle.flame)
            let reach = (110 + spec.height / unit) * unit
            candle.glow.size = CGSize(width: reach * 2, height: reach * 2)
            candle.glow.position = CGPoint(x: spec.tip.x, y: spec.tip.y + 10 * unit)
            candle.glow.color = NSColor(red: 1, green: 0.62, blue: 0.28, alpha: 1)
            add(candle.glow, z: 5, tinted: true)
            if index < 2 {
                let smoke = Self.wisp(unit: unit)
                smoke.position = CGPoint(x: spec.tip.x, y: spec.tip.y + 30 * unit)
                smoke.zPosition = 9
                smoke.targetNode = content
                content.addChild(smoke)
                candle.smoke = smoke
            }
            candles.append(candle)
        }

        for spec in layout.eyes {
            let eye = Eye(spec)
            eye.glow.size = CGSize(width: spec.radius * 7, height: spec.radius * 7)
            eye.glow.color = NSColor(red: 1, green: 0.08, blue: 0.03, alpha: 1)
            eye.glow.position = spec.center
            add(eye.glow, z: 7, tinted: true)
            eye.core.size = CGSize(width: spec.radius * 1.5, height: spec.radius * 1.5)
            eye.core.color = NSColor(red: 1, green: 0.45, blue: 0.3, alpha: 1)
            eye.core.position = spec.center
            add(eye.core, z: 8, tinted: true)
            eyes.append(eye)
        }

        let dust = Self.dust(size: size, unit: unit, density: CGFloat(settings.density))
        dust.position = center
        dust.zPosition = 10
        dust.targetNode = content
        content.addChild(dust)
        dust.advanceSimulationTime(12)

        chargeRing.path = Self.cogPath(radius: 34 * unit)
        chargeRing.strokeColor = NSColor(red: 0.95, green: 0.75, blue: 0.35, alpha: 1)
        chargeRing.lineWidth = 2.5 * unit
        chargeRing.glowWidth = 3 * unit
        chargeRing.zPosition = 12
        chargeRing.alpha = 0
        chargeArc.strokeColor = NSColor(red: 0.35, green: 1, blue: 0.5, alpha: 1)
        chargeArc.lineWidth = 3 * unit
        chargeArc.lineCap = .round
        chargeArc.zPosition = 12
        for node in [chargeRing, chargeArc] {
            node.removeFromParent()
            content.addChild(node)
        }

        contacts = (0..<max(2, Int((4 * settings.density).rounded()))).map { _ in
            (CGPoint(x: .random(in: -0.8...0.8), y: .random(in: -0.8...0.8)),
             CGVector(dx: .random(in: -0.06...0.06), dy: .random(in: -0.06...0.06)))
        }
        for line in ["++ ПРОБУЖДЕНИЕ ДУХА МАШИНЫ ++", "ЛИТАНИЯ АКТИВАЦИИ… ПРИНЯТА", "ВВЕДИТЕ КОД ДОСТУПА: ****"] {
            terminal.log(line)
        }
        previousCursor = nil
        dwell = LiveWallpaperCogitatorDwell()
    }

    private func add(_ sprite: SKSpriteNode, z: CGFloat, tinted: Bool) {
        sprite.removeFromParent()
        sprite.zPosition = z
        if tinted {
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
        }
        content.addChild(sprite)
    }

    private func buildScreen(_ spec: LiveWallpaperShrineLayout.Screen) {
        let screen = Screen(kind: spec.kind, rect: spec.rect)
        let size = spec.rect.size
        screen.effect.position = spec.rect.origin
        screen.effect.zPosition = 2
        screen.effect.shader = screen.shader
        screen.effect.shouldEnableEffects = true
        screen.effect.shouldRasterize = false
        screen.shader.uniformNamed(LiveWallpaperCogitatorCRT.resolutionName)?.vectorFloat2Value =
            SIMD2(Float(size.width), Float(size.height))
        // The backdrop pins the effect node's bounds to the screen, so the shader maps 0...1 onto it.
        let backdrop = SKSpriteNode(color: NSColor(white: 0.03, alpha: 1), size: size)
        backdrop.anchorPoint = .zero
        screen.effect.addChild(backdrop)

        let textScale = unit * 0.8
        switch spec.kind {
        case .main:
            terminal.removeFromParent()
            terminal.layout(size: size, scale: unit * 0.78)
            screen.effect.addChild(terminal)
        case .glyphRain:
            let width = 15 * unit
            let count = max(1, Int(size.width / width))
            let gap = (size.width - CGFloat(count) * width) / 2
            for index in 0..<count {
                let strip = LiveWallpaperCogitatorArt.glyphStrips[index % LiveWallpaperCogitatorArt.glyphStrips.count]
                let sprite = SKSpriteNode(texture: strip, size: CGSize(width: width, height: size.height))
                sprite.anchorPoint = .zero
                sprite.position = CGPoint(x: gap + CGFloat(index) * width, y: 0)
                sprite.alpha = .random(in: 0.5...1)
                screen.effect.addChild(sprite)
                screen.columns.append((sprite, strip, .random(in: 0...0.5), .random(in: 0.04...0.12)))
            }
        case .log:
            let count = max(2, Int((size.height - 10 * unit) / (14 * unit)))
            for index in 0..<count {
                let label = Self.label(size: 11, scale: textScale)
                label.position = CGPoint(x: 8 * unit, y: size.height - (16 + CGFloat(index) * 14) * unit)
                label.text = Self.hexLine()
                screen.effect.addChild(label)
                screen.labels.append(label)
            }
        case .spectrum:
            let count = 14
            let barWidth = (size.width - 16 * unit) / CGFloat(count)
            for index in 0..<count {
                let bar = SKSpriteNode(color: .white, size: CGSize(width: barWidth - 3 * unit, height: 1))
                bar.anchorPoint = .zero
                bar.position = CGPoint(x: 8 * unit + CGFloat(index) * barWidth, y: 18 * unit)
                screen.effect.addChild(bar)
                screen.bars.append((bar, 0))
            }
            let label = Self.label(size: 10, scale: textScale)
            label.position = CGPoint(x: 8 * unit, y: 5 * unit)
            label.text = "ЭФИР · ВОКС-СПЕКТР"
            screen.effect.addChild(label)
        case .wave, .vitals:
            screen.trace.strokeColor = .white
            screen.trace.lineWidth = 1.6 * unit
            screen.trace.isAntialiased = true
            screen.effect.addChild(screen.trace)
            let axis = SKShapeNode()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 4 * unit, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 4 * unit, y: size.height / 2))
            axis.path = path
            axis.strokeColor = NSColor(white: 1, alpha: 0.2)
            axis.lineWidth = 1
            screen.effect.addChild(axis)
            screen.samples = Array(repeating: 0, count: spec.kind == .wave ? 48 : 70)
            let label = Self.label(size: 10, scale: textScale)
            label.position = CGPoint(x: 6 * unit, y: size.height - 13 * unit)
            screen.labels.append(label)
            screen.effect.addChild(label)
        }

        screen.noise.anchorPoint = .zero
        screen.noise.size = size
        screen.noise.alpha = 0
        screen.effect.addChild(screen.noise)
        content.addChild(screen.effect)

        let glare = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glare, size: size)
        glare.anchorPoint = .zero
        glare.position = spec.rect.origin
        glare.zPosition = 3
        glare.blendMode = .add
        content.addChild(glare)
        screens.append(screen)
    }

    // MARK: Frame

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(min(1.0 / 15, max(0, currentTime - (lastUpdate ?? currentTime))))
        lastUpdate = currentTime
        guard !screens.isEmpty else { return }
        elapsed += dt
        energy += (targetEnergy - energy) * (1 - exp(-dt * 1.5))
        riteCooldownRemaining = max(0, riteCooldownRemaining - dt)
        flare = max(0, flare - dt * 0.45)

        let cursor = settings.cursorMode == .off ? nil : localCursor()
        updateParallax(cursor: cursor, dt: dt)
        let point = cursor.map(worldPoint)
        let previous = previousCursor
        if let point, let previous, dt > 0 {
            let speed = hypot(point.x - previous.x, point.y - previous.y) / dt
            cursorSpeed += (speed - cursorSpeed) * (1 - exp(-dt * 12))
        } else {
            cursorSpeed *= exp(-dt * 6)
        }
        previousCursor = point
        interference = Rules.interference(speed: cursorSpeed)
        if interference > 0.6, elapsed - jamLoggedAt > 6 {
            jamLoggedAt = elapsed
            terminal.log("!! ПОМЕХИ В НООСФЕРЕ · СИГНАЛ \(Int(100 - interference * 60))% !!")
        }

        updateRite(cursor: point, dt: dt)
        updateCandles(cursor: point, previous: previous, dt: dt)
        updateEyes(cursor: point, dt: dt)
        updateLights(dt: dt)
        updateScreens(cursor: point, dt: dt)
        updateAmbience(dt: dt)
    }

    private func updateParallax(cursor: CGPoint?, dt: CGFloat) {
        var target = CGVector.zero
        if let cursor {
            let amount = CGFloat(settings.parallax) * 8 * unit
            target = CGVector(dx: -(cursor.x / size.width - 0.5) * 2 * amount, dy: -(cursor.y / size.height - 0.5) * 2 * amount)
        }
        let smoothing = 1 - exp(-dt * 3)
        parallax.dx += (target.dx - parallax.dx) * smoothing
        parallax.dy += (target.dy - parallax.dy) * smoothing
        world.position = CGPoint(x: size.width / 2 + parallax.dx, y: size.height / 2 + parallax.dy)
    }

    /// A scene point mapped into the shrine, which is shifted and slightly scaled for parallax.
    private func worldPoint(_ point: CGPoint) -> CGPoint {
        let scale = world.xScale
        return CGPoint(x: (point.x - world.position.x) / scale + size.width / 2,
                       y: (point.y - world.position.y) / scale + size.height / 2)
    }

    private func updateRite(cursor: CGPoint?, dt: CGFloat) {
        charge = dwell.advance(cursor: cursor, dt: dt, ready: riteCooldownRemaining == 0)
        if let cursor, charge > 0 {
            chargeRing.position = cursor
            chargeArc.position = cursor
            chargeRing.alpha = min(1, charge * 1.5)
            chargeRing.setScale(0.7 + charge * 0.3)
            chargeRing.zRotation -= dt * (1 + charge * 4)
            let arc = CGMutablePath()
            arc.addArc(center: .zero, radius: 44 * unit, startAngle: .pi / 2, endAngle: .pi / 2 - charge * 2 * .pi, clockwise: true)
            chargeArc.path = arc
            chargeArc.alpha = 1
        } else {
            chargeRing.alpha = max(0, chargeRing.alpha - dt * 3)
            chargeArc.alpha = max(0, chargeArc.alpha - dt * 3)
        }
        guard let cursor, charge >= 1 else { return }
        dwell.fire()
        riteCount += 1
        riteCooldownRemaining = Rules.riteCooldown
        flare = 1
        let skull = layout.mainSkull
        if hypot(cursor.x - skull.x, cursor.y - skull.y) < Rules.blessingRadius * unit {
            lastRite = .blessing
            for candle in candles where !candle.isLit { relight(candle) }
            for screen in screens { screen.spike = 1 }
            terminal.log("++ ОМНИССИЯ ВНЕМЛЕТ ++")
            terminal.log("01001111 01001101 01001110 01001001")
            terminal.log("БЛАГОСЛОВЕНИЕ ДАРОВАНО · ДУХ МАШИНЫ ДОВОЛЕН")
        } else {
            lastRite = .purification
            for screen in screens where screen.rect.insetBy(dx: -200 * unit, dy: -200 * unit).contains(cursor) {
                screen.spike = max(screen.spike, 0.8)
            }
            terminal.log("ОБРЯД ОЧИЩЕНИЯ · СЕКТОР \(Int(cursor.x / unit)):\(Int(cursor.y / unit))")
            terminal.log("СКВЕРНА НЕ ОБНАРУЖЕНА · ПЕЧАТИ ЦЕЛЫ")
        }
        pulse(at: cursor)
        burstSparks(at: cursor, count: 40)
    }

    private func updateCandles(cursor: CGPoint?, previous: CGPoint?, dt: CGFloat) {
        let strength = CGFloat(settings.cursorStrength)
        let snuffSpeed = Rules.snuffSpeed(strength: settings.cursorStrength)
        let velocity: CGVector = {
            guard let cursor, let previous, dt > 0 else { return .zero }
            return CGVector(dx: (cursor.x - previous.x) / dt, dy: (cursor.y - previous.y) / dt)
        }()
        for candle in candles {
            if !candle.isLit {
                candle.relightIn -= dt
                if candle.relightIn <= 0 { relight(candle) }
            }
            var wind: CGFloat = 0
            var near: CGFloat = 0
            if let cursor {
                let distance = hypot(cursor.x - candle.tip.x, cursor.y - candle.tip.y)
                let falloff = max(0, 1 - distance / (180 * unit))
                near = max(0, 1 - distance / (70 * unit))
                switch settings.cursorMode {
                case .repel: wind = max(-1, min(1, velocity.dx / 900)) * falloff * strength
                case .attract: wind = (cursor.x > candle.tip.x ? -1 : 1) * falloff * strength * 0.5
                case .off: break
                }
                if candle.isLit, cursorSpeed > snuffSpeed, let previous,
                   Rules.distance(from: candle.tip, toSegment: previous, cursor) < 26 * unit {
                    snuff(candle)
                }
            }
            candle.lean += (wind - candle.lean) * (1 - exp(-dt * 6))
            let target: CGFloat = candle.isLit ? 1 : 0
            candle.light += (target - candle.light) * (1 - exp(-dt * (candle.isLit ? 3 : 14)))
            let t = elapsed * 9 + candle.phase
            let flicker = 0.86 + 0.08 * sin(t) + 0.06 * sin(t * 2.3 + 1.7) + 0.04 * sin(t * 5.1)
            let boost = 1 + near * 0.25 + flare * 0.7
            candle.flame.alpha = candle.light * min(1, flicker + 0.1)
            candle.flame.xScale = candle.light * (0.9 + 0.12 * sin(t * 1.3)) * (1 + flare * 0.3)
            candle.flame.yScale = candle.light * flicker * boost
            candle.flame.zRotation = -candle.lean * 0.7 + sin(t * 0.7) * 0.05
            candle.glow.alpha = candle.light * (0.2 + 0.16 * flicker) * boost
            candle.glow.position.x = candle.tip.x - candle.lean * 8 * unit
            candle.smoke?.particleBirthRate = candle.isLit ? 3 : 0
        }
    }

    private func snuff(_ candle: Candle) {
        candle.isLit = false
        candle.relightIn = .random(in: Rules.relightDelay)
        let puff = Self.puff(unit: unit)
        puff.position = candle.tip
        puff.zPosition = 9
        puff.targetNode = content
        content.addChild(puff)
        puff.run(.sequence([.wait(forDuration: 3.5), .removeFromParent()]))
        if litCandleCount == candles.count - 1 { terminal.log("СВЕЧА ПОГАСЛА · ЧИТАЮ ЛИТАНИЮ ЗАЖИГАНИЯ") }
    }

    private func relight(_ candle: Candle) {
        candle.isLit = true
        candle.relightIn = 0
    }

    private func updateEyes(cursor: CGPoint?, dt: CGFloat) {
        blinkIn -= dt
        if blinkIn <= 0 {
            blink = 0.18
            blinkIn = .random(in: 5...14)
        }
        blink = max(0, blink - dt)
        let shutter: CGFloat = blink > 0 ? 0.12 : 1
        let skull = layout.mainSkull
        let watched = cursor.map { hypot($0.x - skull.x, $0.y - skull.y) < Rules.blessingRadius * unit } ?? false
        for eye in eyes {
            var heat: CGFloat = 0.55 + energy * 0.2
            if let cursor {
                let distance = hypot(cursor.x - eye.spec.center.x, cursor.y - eye.spec.center.y)
                heat += max(0, 1 - distance / (260 * unit)) * 0.35
            }
            if eye.spec.isMain { heat += charge * 0.5 + (watched ? 0.15 : 0) }
            heat += flare * 0.8
            eye.heat += (heat - eye.heat) * (1 - exp(-dt * 5))
            let flicker = 0.92 + 0.08 * sin(elapsed * 23 + eye.spec.center.x)
            let gaze = Rules.gaze(eye: eye.spec.center, cursor: cursor, radius: eye.spec.radius)
            eye.core.position = CGPoint(x: eye.spec.center.x + gaze.dx, y: eye.spec.center.y + gaze.dy)
            eye.core.alpha = min(1, eye.heat * 1.3) * shutter
            eye.core.setScale(0.9 + eye.heat * 0.3)
            eye.glow.position = eye.core.position
            eye.glow.alpha = min(1, eye.heat * 0.75 * flicker) * shutter
            eye.glow.setScale(0.8 + eye.heat * 0.5)
        }
    }

    private func updateLights(dt: CGFloat) {
        for lamp in lamps {
            let wave = sin(elapsed * lamp.rate * (1 + energy * 2) + lamp.phase)
            lamp.node.alpha = wave > -0.2 ? 0.5 + 0.35 * wave : 0.08
        }
        dishSweep.zRotation -= dt * (1.6 + energy * 2.4)
        dishGlow.alpha = 0.35 + 0.15 * sin(elapsed * 2.2) + energy * 0.2 + flare * 0.4
        sparkIn -= dt
        if sparkIn <= 0, let point = layout.sparks.randomElement() {
            sparkIn = .random(in: 3...9) / (1 + energy)
            burstSparks(at: point, count: 14)
        }
    }

    private func updateAmbience(dt: CGFloat) {
        let light = candles.isEmpty ? 0 : candles.reduce(0) { $0 + $1.light } / CGFloat(candles.count)
        altarGlow.alpha = 0.1 + 0.08 * light + flare * 0.15 + 0.01 * sin(elapsed * 7)
        let glitch = screens.first(where: { $0.kind == .main })?.glitch ?? 0
        screenSpill.alpha = 0.11 + 0.04 * sin(elapsed * 1.3) + glitch * 0.08 * CGFloat.random(in: 0...1) + flare * 0.15
    }

    // MARK: Screens

    private func updateScreens(cursor: CGPoint?, dt: CGFloat) {
        chatterIn -= dt
        if chatterIn <= 0 {
            chatterIn = .random(in: 2.5...5.5) / (1 + energy)
            terminal.log(Self.chatter.randomElement()?() ?? "")
        }
        for screen in screens {
            if Double.random(in: 0...1) < Double(dt) / 7 { screen.spike = max(screen.spike, .random(in: 0.35...0.85)) }
            screen.spike = max(0, screen.spike - dt * 0.9)
            let hovered = cursor.map { screen.rect.insetBy(dx: -12 * unit, dy: -12 * unit).contains($0) } ?? false
            let target = min(1, interference * 0.9 + screen.spike + (hovered ? 0.3 : 0) + energy * 0.08)
            screen.glitch += (target - screen.glitch) * (1 - exp(-dt * 10))
            screen.shader.uniformNamed(LiveWallpaperCogitatorCRT.glitchName)?.floatValue = Float(screen.glitch)
            screen.noise.alpha = max(0, screen.glitch - 0.2) * 0.45
            if screen.noise.alpha > 0 {
                screen.noise.texture = LiveWallpaperCogitatorArt.noise[Int(elapsed * 30) % LiveWallpaperCogitatorArt.noise.count]
            }
            switch screen.kind {
            case .main: updateTerminal(screen, cursor: cursor, dt: dt)
            case .glyphRain: updateGlyphs(screen, dt: dt)
            case .log: updateHex(screen, dt: dt)
            case .spectrum: updateSpectrum(screen, dt: dt)
            case .wave: updateWave(screen, dt: dt)
            case .vitals: updateVitals(screen, cursor: cursor, dt: dt)
            }
        }
    }

    private func updateTerminal(_ screen: Screen, cursor: CGPoint?, dt: CGFloat) {
        let status: String
        if charge > 0 {
            let cells = Int((charge * 10).rounded())
            status = "ОБРЯД: " + String(repeating: "▮", count: cells) + String(repeating: "▯", count: 10 - cells)
        } else if riteCooldownRemaining > 0 {
            status = "ОБРЯД ЗАВЕРШЁН · ОЖИДАНИЕ \(Int(riteCooldownRemaining.rounded(.up))) С"
        } else {
            let mood = energy < 0.3 ? "СПОКОЕН" : energy < 0.7 ? "БДИТ" : "ГНЕВЕН"
            status = "ДУХ МАШИНЫ: \(mood) · НАГРУЗКА \(Int((energy * 100).rounded()))%"
        }
        for index in contacts.indices {
            var contact = contacts[index]
            contact.position.x += contact.velocity.dx * dt
            contact.position.y += contact.velocity.dy * dt
            if abs(contact.position.x) > 0.9 { contact.velocity.dx = -contact.velocity.dx }
            if abs(contact.position.y) > 0.9 { contact.velocity.dy = -contact.velocity.dy }
            contacts[index] = contact
        }
        var shown = contacts.map { LiveWallpaperCogitatorContact(position: $0.position, isLocked: false) }
        if let cursor {
            // The operator shows up on the auspex relative to the shrine's center.
            let position = CGPoint(x: max(-1, min(1, (cursor.x / size.width - 0.5) * 2)),
                                   y: max(-1, min(1, (cursor.y / size.height - 0.5) * 2)))
            shown.append(LiveWallpaperCogitatorContact(position: position, isLocked: charge > 0))
        }
        terminal.update(dt: dt, status: status, contacts: shown)
    }

    private func updateGlyphs(_ screen: Screen, dt: CGFloat) {
        let window = min(0.5, screen.rect.height / unit / CGFloat(LiveWallpaperCogitatorArt.glyphStripPeriod * 2))
        for index in screen.columns.indices {
            var column = screen.columns[index]
            column.offset = (column.offset + column.speed * dt * (1 + energy * 2.5)).truncatingRemainder(dividingBy: 0.5)
            // Glyphs move in whole rows, like a character display.
            let row = 1 / CGFloat(LiveWallpaperCogitatorArt.glyphStripPeriod / 8)
            let snapped = (column.offset / row).rounded(.down) * row
            column.sprite.texture = SKTexture(rect: CGRect(x: 0, y: snapped, width: 1, height: window), in: column.strip)
            screen.columns[index] = column
        }
    }

    private func updateHex(_ screen: Screen, dt: CGFloat) {
        screen.clock += dt * (1 + energy * 3)
        guard screen.clock > 0.35 else { return }
        screen.clock = 0
        for index in screen.labels.indices.dropLast() {
            screen.labels[index].text = screen.labels[index + 1].text
        }
        screen.labels.last?.text = Self.hexLine()
    }

    private func updateSpectrum(_ screen: Screen, dt: CGFloat) {
        let top = screen.rect.height - 26 * unit
        for index in screen.bars.indices {
            var bar = screen.bars[index]
            let x = CGFloat(index)
            let base = 0.25 + 0.2 * sin(elapsed * 1.7 + x * 0.6) + 0.15 * sin(elapsed * 4.1 - x * 1.3)
            let target = min(1, max(0.04, base * (0.5 + energy) + CGFloat.random(in: 0...0.2) + screen.glitch * 0.3))
            bar.level += (target - bar.level) * (1 - exp(-dt * 9))
            bar.node.size.height = max(1, bar.level * top)
            screen.bars[index] = bar
        }
    }

    private func updateWave(_ screen: Screen, dt: CGFloat) {
        let size = screen.rect.size
        let amplitude = size.height * (0.12 + 0.24 * energy) + screen.glitch * size.height * 0.1
        let path = CGMutablePath()
        let count = screen.samples.count
        for index in 0..<count {
            let x = CGFloat(index) / CGFloat(count - 1)
            let y = sin(x * 14 + elapsed * 3) * 0.6 + sin(x * 37 - elapsed * 7) * 0.3 + .random(in: -0.15...0.15)
            let point = CGPoint(x: 4 * unit + x * (size.width - 8 * unit), y: size.height / 2 + y * amplitude)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        screen.trace.path = path
        screen.labels.first?.text = String(format: "НООСФЕРА %.1f ТГЦ", 3.2 + energy * 4 + screen.glitch)
    }

    private func updateVitals(_ screen: Screen, cursor: CGPoint?, dt: CGFloat) {
        let servitor = layout.servitorSkull
        let startled = cursor.map { max(0, 1 - hypot($0.x - servitor.x, $0.y - servitor.y) / (240 * unit)) } ?? 0
        let rate = (48 + energy * 60 + startled * 50) / 60
        screen.beat = (screen.beat + dt * rate).truncatingRemainder(dividingBy: 1)
        screen.clock += dt * 40
        while screen.clock >= 1 {
            screen.clock -= 1
            let phase = screen.beat
            var value: CGFloat = .random(in: -0.03...0.03)
            if phase < 0.08 { value += sin(phase / 0.08 * .pi) * 0.15 }
            if phase > 0.16, phase < 0.19 { value -= 0.2 }
            if phase >= 0.19, phase < 0.23 { value += 1 }
            if phase >= 0.23, phase < 0.26 { value -= 0.35 }
            if phase > 0.4, phase < 0.56 { value += sin((phase - 0.4) / 0.16 * .pi) * 0.25 }
            screen.samples.removeFirst()
            screen.samples.append(value)
        }
        let size = screen.rect.size
        let path = CGMutablePath()
        for (index, value) in screen.samples.enumerated() {
            let point = CGPoint(x: 4 * unit + CGFloat(index) / CGFloat(screen.samples.count - 1) * (size.width - 8 * unit),
                                y: size.height * 0.42 + value * size.height * 0.36)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        screen.trace.path = path
        screen.labels.first?.text = String(format: "СЕРВИТОР · ПУЛЬС %03d", Int(rate * 60))
    }

    // MARK: Effects

    private func pulse(at point: CGPoint) {
        let ring = SKSpriteNode(texture: LiveWallpaperCogitatorArt.ring, size: CGSize(width: 40 * unit, height: 40 * unit))
        ring.position = point
        ring.zPosition = 11
        ring.color = NSColor(red: 0.35, green: 1, blue: 0.5, alpha: 1)
        ring.colorBlendFactor = 1
        ring.blendMode = .add
        content.addChild(ring)
        let grow = SKAction.scale(to: 18, duration: 1.6)
        grow.timingMode = .easeOut
        ring.run(.sequence([.group([grow, .fadeOut(withDuration: 1.6)]), .removeFromParent()]))
    }

    private func burstSparks(at point: CGPoint, count: Int) {
        let sparks = SKEmitterNode()
        sparks.particleTexture = LiveWallpaperCogitatorArt.glow
        sparks.particleBirthRate = 400
        sparks.numParticlesToEmit = count
        sparks.particleLifetime = 0.9
        sparks.particleLifetimeRange = 0.5
        sparks.particleSpeed = 180 * unit
        sparks.particleSpeedRange = 140 * unit
        sparks.emissionAngle = .pi / 2
        sparks.emissionAngleRange = .pi * 1.4
        sparks.yAcceleration = -520 * unit
        sparks.particleScale = 0.035 * unit
        sparks.particleScaleRange = 0.02 * unit
        sparks.particleColor = NSColor(red: 1, green: 0.7, blue: 0.3, alpha: 1)
        sparks.particleColorBlendFactor = 1
        sparks.particleBlendMode = .add
        sparks.particleAlphaSpeed = -1
        sparks.position = point
        sparks.zPosition = 9
        sparks.targetNode = content
        content.addChild(sparks)
        sparks.run(.sequence([.wait(forDuration: 2), .removeFromParent()]))
    }

    private static func wisp(unit: CGFloat) -> SKEmitterNode {
        let smoke = SKEmitterNode()
        smoke.particleTexture = LiveWallpaperCogitatorArt.glow
        smoke.particleBirthRate = 3
        smoke.particleLifetime = 6
        smoke.particleSpeed = 22 * unit
        smoke.particleSpeedRange = 8 * unit
        smoke.emissionAngle = .pi / 2
        smoke.emissionAngleRange = 0.25
        smoke.xAcceleration = 3 * unit
        smoke.particleAlpha = 0.07
        smoke.particleAlphaSpeed = -0.011
        smoke.particleScale = 0.08 * unit
        smoke.particleScaleSpeed = 0.06 * unit
        smoke.particleColor = NSColor(white: 0.8, alpha: 1)
        smoke.particleColorBlendFactor = 1
        smoke.advanceSimulationTime(6)
        return smoke
    }

    private static func puff(unit: CGFloat) -> SKEmitterNode {
        let puff = wisp(unit: unit)
        puff.resetSimulation()
        puff.particleBirthRate = 120
        puff.numParticlesToEmit = 18
        puff.particleLifetime = 2.6
        puff.particleSpeed = 40 * unit
        puff.emissionAngleRange = 0.9
        puff.particleAlpha = 0.3
        puff.particleAlphaSpeed = -0.12
        puff.particleScale = 0.05 * unit
        puff.particleScaleSpeed = 0.12 * unit
        return puff
    }

    private static func dust(size: CGSize, unit: CGFloat, density: CGFloat) -> SKEmitterNode {
        let dust = SKEmitterNode()
        dust.particleTexture = LiveWallpaperCogitatorArt.glow
        dust.particleBirthRate = 5 * density * max(1, size.width / 1_728)
        dust.particleLifetime = 14
        dust.particlePositionRange = CGVector(dx: size.width, dy: size.height)
        dust.particleSpeed = 6 * unit
        dust.particleSpeedRange = 5 * unit
        dust.emissionAngleRange = .pi * 2
        dust.yAcceleration = 0.6 * unit
        dust.particleScale = 0.02 * unit
        dust.particleScaleRange = 0.014 * unit
        dust.particleColor = NSColor(red: 1, green: 0.8, blue: 0.55, alpha: 1)
        dust.particleColorBlendFactor = 1
        dust.particleBlendMode = .add
        dust.particleAlpha = 0
        dust.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 0.35, 0.35, 0].map(NSNumber.init(value:)),
                                                        times: [0, 0.2, 0.8, 1])
        return dust
    }

    private static func cogPath(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let teeth = 12
        for index in 0..<(teeth * 2) {
            let angle = CGFloat(index) / CGFloat(teeth * 2) * 2 * .pi
            let reach = index.isMultiple(of: 2) ? radius : radius * 0.84
            for offset: CGFloat in [-0.11, 0.11] {
                let point = CGPoint(x: cos(angle + offset) * reach, y: sin(angle + offset) * reach)
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: -radius * 0.45, y: -radius * 0.45, width: radius * 0.9, height: radius * 0.9))
        return path
    }

    private static func label(size: CGFloat, scale: CGFloat) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.fontSize = size
        label.fontColor = .white
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .baseline
        label.setScale(scale)
        return label
    }

    private static func hexLine() -> String {
        let bits = (0..<2).map { _ in String(Int.random(in: 0..<16), radix: 2).leftPadded(to: 4) }.joined(separator: " ")
        return String(format: "%04X ", Int.random(in: 0..<0xFFFF)) + bits + String(format: " %02X·%02X", Int.random(in: 0..<256),
                                                                                       Int.random(in: 0..<256))
    }

    private func localCursor() -> CGPoint? {
        if let cursorProvider { return cursorProvider() }
        let location = NSEvent.mouseLocation
        guard screenFrame.contains(location) else { return nil }
        return CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
