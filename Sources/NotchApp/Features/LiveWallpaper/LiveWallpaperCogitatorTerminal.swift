import AppKit
import SpriteKit

/// Green phosphor CRT post-process for a screen's effect node: monochrome phosphor, scanlines, grain, a
/// rolling sync band and line tearing. `u_glitch` (0...1) drives the interference.
@MainActor
enum LiveWallpaperCogitatorCRT {
    static let glitchName = "u_glitch"
    static let resolutionName = "u_resolution"

    static func makeShader() -> SKShader {
        let shader = SKShader(source: source)
        shader.uniforms = [SKUniform(name: glitchName, float: 0),
                           SKUniform(name: resolutionName, vectorFloat2: SIMD2(1, 1))]
        return shader
    }

    private static let source = """
    float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

    void main() {
        vec2 screen = v_tex_coord;
        vec2 centered = screen - 0.5;
        vec2 uv = 0.5 + centered * (1.0 + dot(centered, centered) * 0.05);
        float rows = u_resolution.y / 3.0;
        float row = floor(uv.y * rows);
        float tear = hash(vec2(row, floor(u_time * 24.0))) - 0.5;
        float band = 1.0 - smoothstep(0.0, 0.05, abs(fract(screen.y - u_time * 0.06) - 0.5));
        uv.x += tear * 0.014 * u_glitch * u_glitch + band * 0.0025 + sin(uv.y * 30.0 + u_time * 2.0) * 0.0005;
        float slip = step(0.6, u_glitch) * (hash(vec2(floor(u_time * 8.0), 3.0)) - 0.5) * 0.1 * u_glitch;
        uv.y = fract(uv.y + slip);
        vec3 weights = vec3(0.299, 0.587, 0.114);
        float lum = dot(texture2D(u_texture, uv).rgb, weights);
        float ghost = dot(texture2D(u_texture, uv - vec2(0.0025, 0.0)).rgb, weights);
        float bleed = dot(texture2D(u_texture, uv + vec2(0.0007, 0.0)).rgb, weights);
        lum = max(lum, max(ghost * 0.22, bleed * 0.35));
        lum = pow(clamp(lum * 1.55, 0.0, 1.0), 0.85);
        float scan = 0.8 + 0.2 * sin(screen.y * u_resolution.y * 2.0944);
        float grain = hash(screen * u_resolution + fract(u_time * 7.0) * 311.0) - 0.5;
        lum = lum * scan + grain * (0.07 + 0.4 * u_glitch) + band * 0.05;
        lum *= 0.97 + 0.03 * sin(u_time * 50.0);
        lum *= mix(0.5, 1.0, smoothstep(0.8, 0.25, length(centered)));
        gl_FragColor = vec4(vec3(0.2, 1.0, 0.42) * lum + vec3(0.0, 0.025, 0.012), 1.0);
    }
    """
}

/// A contact on the auspex, in -1...1 on both axes.
struct LiveWallpaperCogitatorContact: Equatable {
    var position: CGPoint
    var isLocked: Bool
}

/// Cogitator terminal chrome over the pict-feed: frame, header with clock, status line,
/// a typewriter log and an auspex with a rotating sweep. Colors are neutral; the CRT pass tints them.
@MainActor
final class LiveWallpaperCogitatorTerminal: SKNode {
    private var logCapacity = 9
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let frameShape = SKShapeNode()
    private let header = LiveWallpaperCogitatorTerminal.label(size: 15, bold: true)
    private let clockLabel = LiveWallpaperCogitatorTerminal.label(size: 15, bold: true)
    private let status = LiveWallpaperCogitatorTerminal.label(size: 13, bold: true)
    private let radarLabel = LiveWallpaperCogitatorTerminal.label(size: 12, bold: true)
    private var logLabels: [SKLabelNode] = []
    private var logTexts: [String] = []
    private var pending: [String] = []
    private var typing: (text: String, shown: Int)?
    private var typeClock: CGFloat = 0
    private var blink: CGFloat = 0
    private var statusText = ""
    private var second = -1
    private var cycle = 0

    private let radar = SKNode()
    private let rings = SKShapeNode()
    private let sweep = SKSpriteNode(texture: LiveWallpaperCogitatorArt.cone)
    private var sweepAngle: CGFloat = 0
    private var radius: CGFloat = 80
    private var blips: [SKSpriteNode] = []

    override init() {
        super.init()
        for node in [frameShape, header, clockLabel, status, radar] { addChild(node) }
        radar.addChild(rings)
        radar.addChild(sweep)
        radar.addChild(radarLabel)
        frameShape.strokeColor = NSColor(white: 1, alpha: 0.5)
        frameShape.isAntialiased = true
        rings.strokeColor = NSColor(white: 1, alpha: 0.45)
        rings.isAntialiased = true
        sweep.anchorPoint = CGPoint(x: 0, y: 0.5)
        sweep.color = .white
        sweep.colorBlendFactor = 1
        sweep.blendMode = .add
        sweep.alpha = 0.4
        header.text = "++ КОГИТАТОР Mk.VII ++"
        clockLabel.horizontalAlignmentMode = .right
        radarLabel.horizontalAlignmentMode = .center
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the chrome out inside a screen of `size`; `scale` sizes the text.
    func layout(size: CGSize, scale: CGFloat) {
        let inset = 8 * scale
        let frame = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        let notch = 14 * scale
        let path = CGMutablePath()
        path.addLines(between: [
            CGPoint(x: frame.minX + notch, y: frame.minY), CGPoint(x: frame.maxX - notch, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY + notch), CGPoint(x: frame.maxX, y: frame.maxY - notch),
            CGPoint(x: frame.maxX - notch, y: frame.maxY), CGPoint(x: frame.minX + notch, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY - notch), CGPoint(x: frame.minX, y: frame.minY + notch)
        ])
        path.closeSubpath()
        let rule = frame.maxY - 44 * scale
        path.move(to: CGPoint(x: frame.minX + 10, y: rule))
        path.addLine(to: CGPoint(x: frame.maxX - 10, y: rule))
        frameShape.path = path
        frameShape.lineWidth = 1.5
        header.setScale(scale)
        header.position = CGPoint(x: frame.minX + 12 * scale, y: frame.maxY - 18 * scale)
        clockLabel.setScale(scale)
        clockLabel.position = CGPoint(x: frame.maxX - 12 * scale, y: frame.maxY - 18 * scale)
        status.setScale(scale)
        status.position = CGPoint(x: frame.minX + 12 * scale, y: frame.maxY - 36 * scale)

        for label in logLabels { label.removeFromParent() }
        logCapacity = max(2, Int((rule - frame.minY - 8 * scale) / (19 * scale)))
        logLabels = (0..<logCapacity).map { index in
            let label = Self.label(size: 13, bold: true)
            label.setScale(scale)
            label.position = CGPoint(x: frame.minX + 12 * scale, y: rule - (22 + CGFloat(index) * 19) * scale)
            addChild(label)
            return label
        }
        logTexts.removeAll()
        pending.removeAll()
        typing = nil

        radius = min(62 * scale, (rule - frame.minY) / 2 - 18 * scale)
        radar.position = CGPoint(x: frame.maxX - 14 * scale - radius, y: rule - 10 * scale - radius)
        let ringPath = CGMutablePath()
        for fraction: CGFloat in [1, 0.66, 0.33] {
            ringPath.addEllipse(in: CGRect(x: -radius * fraction, y: -radius * fraction,
                                           width: radius * fraction * 2, height: radius * fraction * 2))
        }
        ringPath.move(to: CGPoint(x: -radius, y: 0))
        ringPath.addLine(to: CGPoint(x: radius, y: 0))
        ringPath.move(to: CGPoint(x: 0, y: -radius))
        ringPath.addLine(to: CGPoint(x: 0, y: radius))
        rings.path = ringPath
        rings.lineWidth = 1
        sweep.size = CGSize(width: radius, height: radius * 0.42)
        radarLabel.setScale(scale)
        radarLabel.position = CGPoint(x: 0, y: -radius - 14 * scale)
        for blip in blips { blip.removeFromParent() }
        blips.removeAll()
        statusText = ""
        second = -1
    }

    /// Queues a line; lines type out one after another. Older pending lines are dropped under load.
    func log(_ line: String) {
        pending.append(line)
        if pending.count > 5 { pending.removeFirst(pending.count - 5) }
    }

    func update(dt: CGFloat, status text: String, contacts: [LiveWallpaperCogitatorContact]) {
        if text != statusText {
            statusText = text
            status.text = text
        }
        let now = Calendar.current.component(.second, from: Date())
        if now != second {
            second = now
            cycle += 1
            clockLabel.text = "ЦИКЛ \(String(format: "%05d", cycle)) · " + Self.clock.string(from: Date())
        }
        updateLog(dt: dt)
        updateRadar(dt: dt, contacts: contacts)
    }

    private func updateLog(dt: CGFloat) {
        blink += dt
        if typing == nil, !pending.isEmpty {
            typing = (pending.removeFirst(), 0)
            logTexts.append("")
            if logTexts.count > logCapacity { logTexts.removeFirst() }
        }
        if var current = typing {
            typeClock += dt * 75
            let step = Int(typeClock)
            typeClock -= CGFloat(step)
            current.shown = min(current.text.count, current.shown + step)
            let done = current.shown >= current.text.count
            logTexts[logTexts.count - 1] = String(current.text.prefix(current.shown)) + (done ? "" : "█")
            typing = done ? nil : current
        }
        let cursorOn = Int(blink * 2.5).isMultiple(of: 2)
        for (index, label) in logLabels.enumerated() {
            // Lines fill from the top; older ones dim.
            var text = index < logTexts.count ? logTexts[index] : ""
            if index == logTexts.count - 1, typing == nil, cursorOn { text += " █" }
            if label.text != text { label.text = text }
            label.alpha = 0.35 + 0.65 * CGFloat(index + 1) / CGFloat(max(1, logTexts.count))
        }
    }

    private func updateRadar(dt: CGFloat, contacts: [LiveWallpaperCogitatorContact]) {
        sweepAngle = (sweepAngle - dt * 2.2).truncatingRemainder(dividingBy: 2 * .pi)
        sweep.zRotation = sweepAngle
        while blips.count < contacts.count {
            let blip = SKSpriteNode(texture: LiveWallpaperCogitatorArt.glow, size: CGSize(width: 12, height: 12))
            blip.blendMode = .add
            radar.addChild(blip)
            blips.append(blip)
        }
        while blips.count > contacts.count { blips.removeLast().removeFromParent() }
        for (blip, contact) in zip(blips, contacts) {
            var point = CGPoint(x: contact.position.x * radius * 0.9, y: contact.position.y * radius * 0.9)
            let length = hypot(point.x, point.y)
            if length > radius * 0.95 { point = CGPoint(x: point.x / length * radius * 0.95, y: point.y / length * radius * 0.95) }
            blip.position = point
            // Blips glow as the sweep passes and fade until it comes around again.
            var behind = (atan2(point.y, point.x) - sweepAngle).truncatingRemainder(dividingBy: 2 * .pi)
            if behind < 0 { behind += 2 * .pi }
            blip.alpha = contact.isLocked ? 1 : max(0.15, 1 - behind / (2 * .pi) * 1.4)
            blip.setScale(contact.isLocked ? 1.8 : 1)
        }
        let text = "АУСПЕКС · " + String(format: "%02d", contacts.count)
        if radarLabel.text != text { radarLabel.text = text }
    }

    private static func label(size: CGFloat, bold: Bool) -> SKLabelNode {
        let label = SKLabelNode(fontNamed: bold ? "Menlo-Bold" : "Menlo-Regular")
        label.fontSize = size
        label.fontColor = .white
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .baseline
        return label
    }
}
