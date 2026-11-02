import AppKit
import SpriteKit

/// Where the live parts of the shrine sit, in scene points.
struct LiveWallpaperShrineLayout {
    enum ScreenKind { case main, glyphRain, log, spectrum, wave, vitals }

    struct Screen {
        let kind: ScreenKind
        let rect: CGRect
    }

    struct Eye {
        let center: CGPoint
        let radius: CGFloat
        /// The skull above the main screen; holding the cursor there calls the blessing.
        let isMain: Bool
    }

    var screens: [Screen] = []
    /// Wick tips of the candles and the candle height, tallest first.
    var candles: [(tip: CGPoint, height: CGFloat)] = []
    var eyes: [Eye] = []
    var mainSkull = CGPoint.zero
    var servitorSkull = CGPoint.zero
    var lamps: [(point: CGPoint, red: Bool)] = []
    var dish = (center: CGPoint.zero, radius: CGFloat(0))
    var sparks: [CGPoint] = []
}

/// Stable noise, so the shrine looks the same after every rebuild.
struct LiveWallpaperSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Procedural art of the «Когитатор» shrine: a gothic machine altar with skulls, cables, gold trim,
/// candles and green screens. It is drawn once with Core Graphics in a 1920×1080 design space
/// centered on the screen, so the scene ships no image assets; side walls extend to any width.
@MainActor
enum LiveWallpaperCogitatorArt {
    private typealias Generator = LiveWallpaperSeededGenerator

    // MARK: Small textures

    static let glow: SKTexture = texture(size: CGSize(width: 256, height: 256), scale: 1) { c in
        guard let gradient = gradient([color(1, 1, 1), color(1, 1, 1, 0.35), color(1, 1, 1, 0)], [0, 0.35, 1]) else { return }
        let center = CGPoint(x: 128, y: 128)
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 128, options: [])
    }

    /// A candle flame, wick at the bottom.
    static let flame = texture(size: CGSize(width: 32, height: 80)) { c in
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 16, y: 2))
        path.addCurve(to: CGPoint(x: 16, y: 78), control1: CGPoint(x: 34, y: 6), control2: CGPoint(x: 22, y: 48))
        path.addCurve(to: CGPoint(x: 16, y: 2), control1: CGPoint(x: 10, y: 48), control2: CGPoint(x: -2, y: 6))
        c.addPath(path)
        c.clip()
        if let gradient = gradient([color(1, 1, 0.96), color(1, 0.88, 0.45, 0.95), color(1, 0.55, 0.12, 0.6),
                                    color(0.9, 0.25, 0.05, 0)], [0, 0.28, 0.65, 1]) {
            let center = CGPoint(x: 16, y: 18)
            c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: 62, options: [])
        }
        c.setFillColor(color(0.35, 0.5, 1, 0.45))
        c.fillEllipse(in: CGRect(x: 11, y: 1, width: 10, height: 12))
    }

    /// A radar sweep wedge with its apex on the left edge.
    static let cone = texture(size: CGSize(width: 256, height: 96), scale: 1) { c in
        c.addPath(polygon([CGPoint(x: 0, y: 48), CGPoint(x: 256, y: 0), CGPoint(x: 256, y: 96)]))
        c.clip()
        guard let gradient = gradient([color(1, 1, 1, 0.9), color(1, 1, 1, 0)], [0, 1]) else { return }
        c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 96), options: [])
    }

    static let glare = texture(size: CGSize(width: 64, height: 64), scale: 1) { c in
        guard let gradient = gradient([color(1, 1, 1, 0.12), color(1, 1, 1, 0.02), color(1, 1, 1, 0)], [0, 0.45, 1]) else { return }
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 64), end: CGPoint(x: 48, y: 0), options: [])
    }

    /// Static frames for screen interference.
    static let noise: [SKTexture] = (0..<4).map { index in
        let side = 96
        var generator = Generator(seed: 0xC0617 + UInt64(index))
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return SKTexture() }
        for pixel in 0..<(side * side) {
            let value = UInt8.random(in: 0...255, using: &generator)
            let alpha = UInt8.random(in: 60...255, using: &generator)
            let premultiplied = UInt8(Int(value) * Int(alpha) / 255)
            data[pixel * 4] = premultiplied
            data[pixel * 4 + 1] = premultiplied
            data[pixel * 4 + 2] = premultiplied
            data[pixel * 4 + 3] = alpha
        }
        let texture = context.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
        texture.filteringMode = .nearest
        return texture
    }

    /// Columns of machine glyphs for the falling-code screen. The lower half repeats in the upper
    /// half, so a window of up to half the strip can scroll through it without a seam.
    static let glyphStrips: [SKTexture] = (0..<4).map { index in
        let glyphs = Array("0123456789ABCDEFΩΔΣΨ+†‡§∴≡ЖЯФЩЭ")
        var generator = Generator(seed: 0x6171 + UInt64(index))
        let rows = (0..<(glyphStripPeriod / 16)).map { _ in
            (String(glyphs[Int.random(in: 0..<glyphs.count, using: &generator)]), CGFloat.random(in: 0.2...1, using: &generator))
        }
        return texture(size: CGSize(width: 16, height: CGFloat(glyphStripPeriod * 2))) { c in
            let font = NSFont(name: "Menlo-Bold", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            for copy in 0..<2 {
                for (row, glyph) in rows.enumerated() {
                    (glyph.0 as NSString).draw(at: CGPoint(x: 2, y: CGFloat(copy * glyphStripPeriod + row * 16)), withAttributes: [
                        .font: font, .foregroundColor: NSColor(white: 1, alpha: glyph.1)
                    ])
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let glyphStripPeriod = 512

    /// A thin ring for the noosphere pulse.
    static let ring = texture(size: CGSize(width: 128, height: 128), scale: 1) { c in
        c.setStrokeColor(color(1, 1, 1))
        c.setLineWidth(4)
        c.strokeEllipse(in: CGRect(x: 4, y: 4, width: 120, height: 120))
    }

    // MARK: The shrine

    /// The whole static shrine at screen size, plus where its live parts go.
    static func shrine(size: CGSize) -> (texture: SKTexture, layout: LiveWallpaperShrineLayout) {
        let unit = min(size.height / 1_080, size.width / 1_728)
        let halfWidth = size.width / 2 / unit
        let height = size.height / unit
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: size.width / 2 + x * unit, y: y * unit) }
        func rect(_ value: CGRect) -> CGRect {
            CGRect(origin: point(value.minX, value.minY), size: CGSize(width: value.width * unit, height: value.height * unit))
        }

        let screens: [(LiveWallpaperShrineLayout.ScreenKind, CGRect)] = [
            (.main, CGRect(x: -228, y: 512, width: 456, height: 256)),
            (.glyphRain, CGRect(x: -760, y: 560, width: 200, height: 160)),
            (.log, CGRect(x: -760, y: 372, width: 200, height: 118)),
            (.spectrum, CGRect(x: 600, y: 650, width: 170, height: 110)),
            (.wave, CGRect(x: 430, y: 604, width: 140, height: 86)),
            (.vitals, CGRect(x: 430, y: 484, width: 140, height: 86))
        ]
        let candles: [(x: CGFloat, y: CGFloat, height: CGFloat, width: CGFloat)] = [
            (-365, 414, 70, 22), (-338, 414, 96, 24), (-311, 414, 52, 20), (311, 414, 58, 20), (338, 414, 102, 24),
            (366, 414, 74, 22), (-830, 330, 62, 20), (-801, 330, 40, 18), (-472, 330, 72, 20), (-446, 330, 44, 16),
            (410, 364, 56, 20), (440, 364, 84, 22), (870, 364, 66, 20), (898, 364, 42, 16), (-745, 738, 46, 16)
        ]
        var layout = LiveWallpaperShrineLayout()
        layout.screens = screens.map { .init(kind: $0.0, rect: rect($0.1)) }
        layout.candles = candles.map { (point($0.x, $0.y + $0.height + 6), $0.height * unit) }
            .sorted { $0.height > $1.height }
        layout.lamps = [(point(-232, 452), false), (point(-206, 452), true), (point(206, 452), false),
                        (point(232, 452), true), (point(-560, 316), true), (point(690, 381), false),
                        (point(884, 350), true), (point(-520, 470), false), (point(-640, 316), false)]
        layout.dish = (point(0, 441), 30 * unit)
        layout.sparks = [point(70, 985), point(-95, 1_000), point(712, 598), point(-600, 892)]
        layout.mainSkull = point(0, 905)
        layout.servitorSkull = point(690, 512)

        let scale = min(2, 8_000 / max(1, size.width), 6_000 / max(1, size.height))
        var eyes: [LiveWallpaperShrineLayout.Eye] = []
        let texture = texture(size: size, scale: scale) { c in
            var generator = Generator(seed: 0x5A1C_7A17)
            c.translateBy(x: size.width / 2, y: 0)
            c.scaleBy(x: unit, y: unit)
            wall(c, halfWidth: halfWidth, height: height, generator: &generator)
            for cable in 0..<14 { drawCable(index: cable, c, halfWidth: halfWidth, height: height, front: false, generator: &generator) }
            centerpiece(c, height: height, generator: &generator)
            for cable in 0..<10 { drawCable(index: cable, c, halfWidth: halfWidth, height: height, front: true, generator: &generator) }
            let mainEyes = skull(c, at: CGPoint(x: 0, y: 905), size: 125, bionic: true)
            sides(c)
            let leftEyes = skull(c, at: CGPoint(x: -660, y: 802), size: 72, bionic: false)
            let rightEyes = skull(c, at: CGPoint(x: 690, y: 512), size: 78, bionic: true)
            // The servitor breathes through a tube into the desk.
            let tube = CGMutablePath()
            tube.move(to: CGPoint(x: 690, y: 468))
            tube.addCurve(to: CGPoint(x: 640, y: 364), control1: CGPoint(x: 690, y: 420), control2: CGPoint(x: 640, y: 420))
            cable(c, tube, width: 12, tone: color(0.16, 0.16, 0.17))
            for spec in candles { candle(c, base: CGPoint(x: spec.x, y: spec.y), height: spec.height, width: spec.width, generator: &generator) }
            for (x, y, length, angle) in [(-482.0, 700.0, 70.0, 0.08), (-440, 640, 54, -0.1), (880, 800, 80, 0.05), (930, 700, 60, -0.06),
                                          (395, 790, 66, 0.1), (-925, 770, 72, -0.04), (530, 870, 58, 0.07), (-283, 640, 64, 0.03),
                                          (283, 700, 50, -0.05), (-990, 420, 66, 0.06)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                seal(c, at: CGPoint(x: x, y: y), length: length, angle: angle)
            }
            grime(c, halfWidth: halfWidth, height: height, generator: &generator)
            eyes = mainEyes.map { .init(center: $0, radius: 9.5, isMain: true) }
                + (leftEyes + rightEyes).map { .init(center: $0, radius: 6.5, isMain: false) }
        }
        layout.eyes = eyes.map { .init(center: point($0.center.x, $0.center.y), radius: $0.radius * unit, isMain: $0.isMain) }
        return (texture, layout)
    }

    // MARK: Shrine parts (design space)

    private static func wall(_ c: CGContext, halfWidth: CGFloat, height: CGFloat, generator: inout Generator) {
        c.setFillColor(color(0.07, 0.07, 0.075))
        c.fill(CGRect(x: -halfWidth, y: 0, width: halfWidth * 2, height: height))
        var x = -halfWidth - CGFloat.random(in: 0...120, using: &generator)
        while x < halfWidth {
            let width = CGFloat.random(in: 140...260, using: &generator)
            var y: CGFloat = 0
            while y < height {
                let rowHeight = CGFloat.random(in: 160...360, using: &generator)
                panel(c, CGRect(x: x + 3, y: y + 3, width: width - 6, height: rowHeight - 6),
                      tone: CGFloat.random(in: 0.13...0.2, using: &generator))
                y += rowHeight
            }
            x += width
        }
        // Heavy pipes up the side walls, clear of the altar.
        var pipeX = -halfWidth + CGFloat.random(in: 40...120, using: &generator)
        while pipeX < halfWidth {
            if abs(pipeX) > 420 {
                let width = CGFloat.random(in: 26...48, using: &generator)
                pipe(c, from: CGPoint(x: pipeX, y: 0), to: CGPoint(x: pipeX, y: height), width: width)
                var flange = CGFloat.random(in: 80...200, using: &generator)
                while flange < height {
                    pipe(c, from: CGPoint(x: pipeX, y: flange), to: CGPoint(x: pipeX, y: flange + 14), width: width + 12, tone: 0.3)
                    flange += CGFloat.random(in: 220...380, using: &generator)
                }
            }
            pipeX += CGFloat.random(in: 280...520, using: &generator)
        }
        for (y, width) in [(height - 60, CGFloat(30)), (height - 112, 22)] {
            pipe(c, from: CGPoint(x: 430, y: y), to: CGPoint(x: halfWidth, y: y), width: width)
            pipe(c, from: CGPoint(x: -halfWidth, y: y), to: CGPoint(x: -430, y: y), width: width)
        }
        vent(c, CGRect(x: -940, y: 60, width: 300, height: 220))
        vent(c, CGRect(x: 560, y: 50, width: 320, height: 200))
        if halfWidth > 1_050 {
            vent(c, CGRect(x: -halfWidth + 60, y: 120, width: 220, height: 300))
            vent(c, CGRect(x: halfWidth - 280, y: 160, width: 220, height: 260))
        }
        for (x, y, radius) in [(-960.0, 520.0, 26.0), (-905, 600, 20), (-960, 640, 18), (980, 560, 24), (1_020, 640, 18),
                               (378, 905, 22), (-1_080, 760, 22)] as [(CGFloat, CGFloat, CGFloat)] {
            gauge(c, center: CGPoint(x: x, y: y), radius: radius, generator: &generator)
        }
    }

    private static func centerpiece(_ c: CGContext, height: CGFloat, generator: inout Generator) {
        // Lancet vents above the niche.
        for x: CGFloat in [-125, 0, 125] {
            let window = arch(CGRect(x: x - 47, y: 1_000, width: 94, height: 300))
            metal(c, window, tone: 0.24)
            c.saveGState()
            c.addPath(window)
            c.clip()
            c.setFillColor(color(0.05, 0.05, 0.055))
            var y: CGFloat = 1_010
            while y < 1_300 {
                c.fill(CGRect(x: x - 40, y: y, width: 80, height: 6))
                y += 13
            }
            c.restoreGState()
            c.addPath(window)
            c.setStrokeColor(color(0.62, 0.48, 0.2))
            c.setLineWidth(5)
            c.strokePath()
        }
        // Pillars and backplate around the main screen.
        metal(c, CGPath(rect: CGRect(x: -262, y: 470, width: 524, height: 330), transform: nil), tone: 0.17)
        for x: CGFloat in [-306, 262] {
            gold(c, CGPath(rect: CGRect(x: x, y: 414, width: 44, height: 470), transform: nil))
            c.setStrokeColor(color(0.3, 0.2, 0.05, 0.8))
            c.setLineWidth(2)
            for offset: CGFloat in [10, 22, 34] { line(c, [CGPoint(x: x + offset, y: 430), CGPoint(x: x + offset, y: 870)]) }
            c.strokePath()
        }
        bezel(c, CGRect(x: -228, y: 512, width: 456, height: 256), border: 22)
        // Gold hood and niche of the cogitator's skull.
        gold(c, polygon([CGPoint(x: -190, y: 990), CGPoint(x: 0, y: 1_130), CGPoint(x: 190, y: 990),
                         CGPoint(x: 160, y: 980), CGPoint(x: 0, y: 1_090), CGPoint(x: -160, y: 980)]))
        niche(c, CGRect(x: -150, y: 800, width: 300, height: 230))
        // Altar plinth: stone panel framed in gold, with an arcade, emblem and chevron.
        let plinth = CGRect(x: -330, y: 0, width: 660, height: 380)
        gold(c, CGPath(rect: plinth, transform: nil))
        fill(c, CGPath(rect: plinth.insetBy(dx: 16, dy: 16), transform: nil),
             [color(0.5, 0.5, 0.5), color(0.36, 0.36, 0.37), color(0.25, 0.25, 0.26)], [0, 0.55, 1],
             from: CGPoint(x: 0, y: 364), to: CGPoint(x: 0, y: 16))
        for _ in 0..<40 {
            let x = CGFloat.random(in: -310...300, using: &generator), y = CGFloat.random(in: 20...360, using: &generator)
            c.setFillColor(color(0, 0, 0, CGFloat.random(in: 0.03...0.1, using: &generator)))
            c.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat.random(in: 10...60, using: &generator),
                                     height: CGFloat.random(in: 6...30, using: &generator)))
        }
        gold(c, CGPath(rect: CGRect(x: -314, y: 300, width: 628, height: 50), transform: nil))
        for index in 0..<9 {
            let x = -300 + CGFloat(index) * 67
            c.addPath(arch(CGRect(x: x + 8, y: 304, width: 50, height: 40)))
            c.setFillColor(color(0.3, 0.3, 0.31))
            c.fillPath()
        }
        emblem(c, center: CGPoint(x: 0, y: 190), size: 230)
        gold(c, polygon([CGPoint(x: -150, y: 16), CGPoint(x: 0, y: 110), CGPoint(x: 150, y: 16), CGPoint(x: 112, y: 16),
                         CGPoint(x: 0, y: 84), CGPoint(x: -112, y: 16)]))
        // Desk slab and console with its round scope.
        gold(c, CGPath(rect: CGRect(x: -385, y: 380, width: 770, height: 22), transform: nil))
        metal(c, CGPath(rect: CGRect(x: -385, y: 402, width: 770, height: 12), transform: nil), tone: 0.32)
        metal(c, CGPath(rect: CGRect(x: -270, y: 414, width: 540, height: 54), transform: nil), tone: 0.22)
        for row in 0..<3 {
            var x: CGFloat = -258
            while x < 250 {
                if abs(x + 5) > 54 {
                    metal(c, CGPath(roundedRect: CGRect(x: x, y: 420 + CGFloat(row) * 14, width: 10, height: 10),
                                    cornerWidth: 2, cornerHeight: 2, transform: nil), tone: 0.36)
                }
                x += 13
            }
        }
        c.setFillColor(color(0.03, 0.03, 0.03))
        c.fillEllipse(in: CGRect(x: -40, y: 401, width: 80, height: 80))
        c.setStrokeColor(color(0.5, 0.5, 0.52))
        c.setLineWidth(5)
        c.strokeEllipse(in: CGRect(x: -38, y: 403, width: 76, height: 76))
        // Wax runs down the front of the slab.
        for x: CGFloat in [-372, -350, -330, -318, 304, 330, 346, 372] {
            let length = CGFloat.random(in: 14...70, using: &generator)
            wax(c, CGPath(roundedRect: CGRect(x: x, y: 402 - length, width: 7, height: length + 6), cornerWidth: 3.5,
                          cornerHeight: 3.5, transform: nil))
            wax(c, CGPath(ellipseIn: CGRect(x: x - 1.5, y: 398 - length, width: 10, height: 10), transform: nil))
        }
    }

    private static func sides(_ c: CGContext) {
        niche(c, CGRect(x: -722, y: 744, width: 124, height: 150))
        bezel(c, CGRect(x: -760, y: 560, width: 200, height: 160))
        bezel(c, CGRect(x: -760, y: 372, width: 200, height: 118))
        metal(c, CGPath(rect: CGRect(x: -860, y: 300, width: 420, height: 30), transform: nil), tone: 0.3)
        metal(c, CGPath(rect: CGRect(x: -850, y: 240, width: 400, height: 60), transform: nil), tone: 0.2)
        for index in 0..<8 {
            metal(c, CGPath(ellipseIn: CGRect(x: -830 + CGFloat(index) * 44, y: 258, width: 22, height: 22), transform: nil), tone: 0.4)
        }
        niche(c, CGRect(x: 622, y: 432, width: 136, height: 175))
        bezel(c, CGRect(x: 600, y: 650, width: 170, height: 110))
        bezel(c, CGRect(x: 430, y: 604, width: 140, height: 86))
        bezel(c, CGRect(x: 430, y: 484, width: 140, height: 86))
        metal(c, CGPath(rect: CGRect(x: 380, y: 330, width: 560, height: 34), transform: nil), tone: 0.3)
        metal(c, CGPath(rect: CGRect(x: 390, y: 260, width: 540, height: 70), transform: nil), tone: 0.19)
        for index in 0..<10 {
            metal(c, CGPath(rect: CGRect(x: 410 + CGFloat(index) * 50, y: 280, width: 30, height: 30), transform: nil), tone: 0.33)
        }
        c.setFillColor(color(0.05, 0.12, 0.06))
        c.fillEllipse(in: CGRect(x: 672, y: 364, width: 36, height: 30))
    }

    private static func drawCable(index: Int, _ c: CGContext, halfWidth: CGFloat, height: CGFloat, front: Bool,
                                  generator: inout Generator) {
        let palette = [color(0.06, 0.06, 0.065), color(0.06, 0.06, 0.065), color(0.08, 0.08, 0.08),
                       color(0.7, 0.68, 0.58), color(0.6, 0.58, 0.5), color(0.26, 0.26, 0.27), color(0.42, 0.07, 0.05)]
        let tone = palette[Int.random(in: 0..<palette.count, using: &generator)]
        let width = CGFloat.random(in: 6...17, using: &generator)
        let start = CGPoint(x: CGFloat.random(in: -halfWidth...halfWidth, using: &generator), y: height + 20)
        let path = CGMutablePath()
        path.move(to: start)
        if front || index.isMultiple(of: 3) {
            // Into the top of the cogitator's skull, which is drawn over the plugs.
            let end = CGPoint(x: CGFloat.random(in: -40...40, using: &generator), y: CGFloat.random(in: 950...975, using: &generator))
            path.addCurve(to: end,
                          control1: CGPoint(x: start.x * 0.75, y: CGFloat.random(in: 780...980, using: &generator)),
                          control2: CGPoint(x: end.x + CGFloat.random(in: -260...260, using: &generator),
                                            y: end.y + CGFloat.random(in: 60...220, using: &generator)))
        } else {
            // Drapes between two points high on the wall.
            let end = CGPoint(x: CGFloat.random(in: -halfWidth...halfWidth, using: &generator),
                              y: CGFloat.random(in: height - 120...height + 20, using: &generator))
            let sag = CGFloat.random(in: 820...960, using: &generator)
            path.addCurve(to: end, control1: CGPoint(x: start.x, y: sag), control2: CGPoint(x: end.x, y: sag))
        }
        cable(c, path, width: width, tone: tone)
    }

    // MARK: Primitives

    private static func panel(_ c: CGContext, _ rect: CGRect, tone: CGFloat) {
        metal(c, CGPath(rect: rect, transform: nil), tone: tone)
        c.setLineWidth(2)
        c.setStrokeColor(color(1, 1, 1, 0.09))
        line(c, [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)])
        c.strokePath()
        c.setStrokeColor(color(0, 0, 0, 0.55))
        line(c, [CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY)])
        c.strokePath()
        for corner in [CGPoint(x: rect.minX + 9, y: rect.minY + 9), CGPoint(x: rect.maxX - 9, y: rect.minY + 9),
                       CGPoint(x: rect.minX + 9, y: rect.maxY - 9), CGPoint(x: rect.maxX - 9, y: rect.maxY - 9)] {
            c.setFillColor(color(0.04, 0.04, 0.04))
            c.fillEllipse(in: CGRect(x: corner.x - 3.5, y: corner.y - 3.5, width: 7, height: 7))
            c.setFillColor(color(0.5, 0.5, 0.5, 0.6))
            c.fillEllipse(in: CGRect(x: corner.x - 2, y: corner.y, width: 2.5, height: 2.5))
        }
    }

    private static func pipe(_ c: CGContext, from start: CGPoint, to end: CGPoint, width: CGFloat, tone: CGFloat = 0.22) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(0.001, hypot(dx, dy))
        let normal = CGPoint(x: -dy / length * width / 2, y: dx / length * width / 2)
        let body = polygon([CGPoint(x: start.x + normal.x, y: start.y + normal.y), CGPoint(x: end.x + normal.x, y: end.y + normal.y),
                            CGPoint(x: end.x - normal.x, y: end.y - normal.y), CGPoint(x: start.x - normal.x, y: start.y - normal.y)])
        fill(c, body, [color(tone * 0.3, tone * 0.3, tone * 0.32), color(tone * 1.7, tone * 1.7, tone * 1.75),
                       color(tone, tone, tone * 1.04), color(tone * 0.25, tone * 0.25, tone * 0.27)], [0, 0.3, 0.62, 1],
             from: CGPoint(x: start.x + normal.x, y: start.y + normal.y), to: CGPoint(x: start.x - normal.x, y: start.y - normal.y))
    }

    private static func cable(_ c: CGContext, _ path: CGPath, width: CGFloat, tone: CGColor) {
        c.saveGState()
        c.translateBy(x: 5, y: -8)
        c.addPath(path)
        c.setStrokeColor(color(0, 0, 0, 0.35))
        c.setLineWidth(width + 4)
        c.strokePath()
        c.restoreGState()
        c.addPath(path)
        c.setStrokeColor(color(0.02, 0.02, 0.02, 0.9))
        c.setLineWidth(width + 2)
        c.strokePath()
        c.addPath(path)
        c.setStrokeColor(tone)
        c.setLineWidth(width)
        c.strokePath()
        c.saveGState()
        c.translateBy(x: -width * 0.18, y: width * 0.22)
        c.addPath(path)
        c.setStrokeColor(color(1, 1, 1, 0.17))
        c.setLineWidth(width * 0.28)
        c.strokePath()
        c.restoreGState()
    }

    private static func vent(_ c: CGContext, _ rect: CGRect) {
        metal(c, CGPath(rect: rect, transform: nil), tone: 0.16)
        var y = rect.minY + 14
        while y < rect.maxY - 18 {
            c.addPath(CGPath(roundedRect: CGRect(x: rect.minX + 16, y: y, width: rect.width - 32, height: 10),
                             cornerWidth: 5, cornerHeight: 5, transform: nil))
            c.setFillColor(color(0.015, 0.015, 0.015))
            c.fillPath()
            y += 22
        }
    }

    private static func gauge(_ c: CGContext, center: CGPoint, radius: CGFloat, generator: inout Generator) {
        metal(c, CGPath(ellipseIn: CGRect(x: center.x - radius - 5, y: center.y - radius - 5, width: (radius + 5) * 2,
                                          height: (radius + 5) * 2), transform: nil), tone: 0.36)
        c.setFillColor(color(0.82, 0.79, 0.68))
        c.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        c.setStrokeColor(color(0.15, 0.12, 0.1))
        c.setLineWidth(1.2)
        for index in 0...10 {
            let angle = CGFloat.pi * 1.25 - CGFloat(index) / 10 * CGFloat.pi * 1.5
            line(c, [CGPoint(x: center.x + cos(angle) * radius * 0.72, y: center.y + sin(angle) * radius * 0.72),
                     CGPoint(x: center.x + cos(angle) * radius * 0.9, y: center.y + sin(angle) * radius * 0.9)])
        }
        c.strokePath()
        let needle = CGFloat.random(in: -0.6...1.9, using: &generator)
        c.setStrokeColor(color(0.6, 0.06, 0.04))
        c.setLineWidth(2)
        line(c, [center, CGPoint(x: center.x + cos(needle) * radius * 0.8, y: center.y + sin(needle) * radius * 0.8)])
        c.strokePath()
    }

    private static func bezel(_ c: CGContext, _ screen: CGRect, border: CGFloat = 18) {
        metal(c, CGPath(roundedRect: screen.insetBy(dx: -border, dy: -border), cornerWidth: 10, cornerHeight: 10, transform: nil),
              tone: 0.3)
        c.setFillColor(color(0.03, 0.03, 0.03))
        c.fill(screen.insetBy(dx: -5, dy: -5))
        c.setFillColor(color(0.01, 0.045, 0.02))
        c.fill(screen)
        for corner in [CGPoint(x: screen.minX - border / 2, y: screen.minY - border / 2),
                       CGPoint(x: screen.maxX + border / 2, y: screen.minY - border / 2),
                       CGPoint(x: screen.minX - border / 2, y: screen.maxY + border / 2),
                       CGPoint(x: screen.maxX + border / 2, y: screen.maxY + border / 2)] {
            c.setFillColor(color(0.55, 0.55, 0.56))
            c.fillEllipse(in: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6))
        }
    }

    /// A pointed gothic arch.
    private static func arch(_ rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let shoulder = rect.maxY - rect.width * 0.62
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY - rect.width * 0.12))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder), control: CGPoint(x: rect.maxX, y: rect.maxY - rect.width * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// A gold-framed, spiked niche with a dark interior.
    private static func niche(_ c: CGContext, _ rect: CGRect) {
        let outer = rect.insetBy(dx: -14, dy: -10)
        for side: CGFloat in [-1, 1] {
            for index in 0..<4 {
                let t = 0.15 + CGFloat(index) * 0.22
                let start = CGPoint(x: side < 0 ? outer.minX : outer.maxX, y: outer.maxY - outer.width * 0.62)
                let control = CGPoint(x: side < 0 ? outer.minX : outer.maxX, y: outer.maxY - outer.width * 0.12)
                let apex = CGPoint(x: outer.midX, y: outer.maxY)
                let point = CGPoint(x: (1 - t) * (1 - t) * start.x + 2 * (1 - t) * t * control.x + t * t * apex.x,
                                    y: (1 - t) * (1 - t) * start.y + 2 * (1 - t) * t * control.y + t * t * apex.y)
                let dx = point.x - outer.midX, dy = point.y - (outer.maxY - outer.width * 0.5)
                let length = max(1, hypot(dx, dy))
                let normal = CGPoint(x: dx / length, y: dy / length)
                let spike: CGFloat = 16
                gold(c, polygon([CGPoint(x: point.x - normal.y * 6, y: point.y + normal.x * 6),
                                 CGPoint(x: point.x + normal.x * spike, y: point.y + normal.y * spike),
                                 CGPoint(x: point.x + normal.y * 6, y: point.y - normal.x * 6)]))
            }
        }
        gold(c, arch(outer))
        fill(c, arch(rect), [color(0.02, 0.02, 0.025), color(0.09, 0.08, 0.08)], [0, 1],
             from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.minY))
    }

    /// A skull, optionally fitted with bionics. Returns the eye centers.
    private static func skull(_ c: CGContext, at center: CGPoint, size: CGFloat, bionic: Bool) -> [CGPoint] {
        let s = size / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: center.x + x * s, y: center.y + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: p(x, y), size: CGSize(width: width * s, height: height * s))
        }
        bone(c, CGPath(roundedRect: box(-28, -48, 56, 38), cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil), center: p(-10, -20), radius: 50 * s)
        bone(c, CGPath(ellipseIn: box(-42, -26, 84, 82), transform: nil), center: p(-14, 30), radius: 75 * s)
        c.setFillColor(color(0.04, 0.03, 0.03))
        c.fillEllipse(in: box(-31, -8, 25, 22))
        c.fillEllipse(in: box(6, -8, 25, 22))
        c.addPath(polygon([p(-5, -20), p(5, -20), p(0, -8)]))
        c.fillPath()
        c.fill(box(-22, -40, 44, 10))
        c.setFillColor(color(0.78, 0.72, 0.6))
        for index in 0..<7 { c.fill(box(-21 + CGFloat(index) * 6.2, -39, 4.6, 8)) }
        c.setStrokeColor(color(0.2, 0.15, 0.1, 0.7))
        c.setLineWidth(1.2 * s)
        line(c, [p(-20, 50), p(-12, 38), p(-16, 28)])
        line(c, [p(26, 44), p(20, 34)])
        c.strokePath()
        if bionic {
            c.setStrokeColor(color(0.42, 0.42, 0.44))
            c.setLineWidth(4 * s)
            c.strokeEllipse(in: box(4, -10, 29, 26))
            metal(c, CGPath(rect: box(-12, 40, 26, 12), transform: nil), tone: 0.35)
            metal(c, CGPath(ellipseIn: box(28, 30, 16, 16), transform: nil), tone: 0.38)
        }
        return [p(-18.5, 3), p(18.5, 3)]
    }

    private static func bone(_ c: CGContext, _ path: CGPath, center: CGPoint, radius: CGFloat) {
        guard let gradient = gradient([color(0.93, 0.88, 0.75), color(0.66, 0.59, 0.46), color(0.3, 0.25, 0.19)], [0, 0.55, 1]) else { return }
        c.saveGState()
        c.addPath(path)
        c.clip()
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                             options: [.drawsAfterEndLocation])
        c.restoreGState()
    }

    private static func candle(_ c: CGContext, base: CGPoint, height: CGFloat, width: CGFloat, generator: inout Generator) {
        wax(c, CGPath(ellipseIn: CGRect(x: base.x - width * 0.9, y: base.y - 4, width: width * 1.8, height: 10), transform: nil))
        let body = CGRect(x: base.x - width / 2, y: base.y, width: width, height: height)
        fill(c, CGPath(roundedRect: body, cornerWidth: width * 0.2, cornerHeight: width * 0.2, transform: nil),
             [color(0.6, 0.53, 0.4), color(0.98, 0.94, 0.82), color(0.86, 0.79, 0.63), color(0.52, 0.45, 0.34)], [0, 0.35, 0.7, 1],
             from: CGPoint(x: body.minX, y: body.midY), to: CGPoint(x: body.maxX, y: body.midY))
        c.setFillColor(color(1, 0.97, 0.88))
        c.fillEllipse(in: CGRect(x: body.minX, y: body.maxY - width * 0.18, width: width, height: width * 0.36))
        for _ in 0..<Int.random(in: 1...3, using: &generator) {
            let x = CGFloat.random(in: body.minX...(body.maxX - 5), using: &generator)
            let length = CGFloat.random(in: 0.2...0.7, using: &generator) * height
            wax(c, CGPath(roundedRect: CGRect(x: x, y: body.maxY - length, width: 5, height: length), cornerWidth: 2.5,
                          cornerHeight: 2.5, transform: nil))
            wax(c, CGPath(ellipseIn: CGRect(x: x - 1, y: body.maxY - length - 2, width: 7, height: 7), transform: nil))
        }
        c.setStrokeColor(color(0.1, 0.08, 0.06))
        c.setLineWidth(2)
        line(c, [CGPoint(x: base.x, y: body.maxY), CGPoint(x: base.x, y: body.maxY + 7)])
        c.strokePath()
    }

    private static func wax(_ c: CGContext, _ path: CGPath) {
        let box = path.boundingBox
        fill(c, path, [color(0.96, 0.92, 0.8), color(0.72, 0.66, 0.52)], [0, 1],
             from: CGPoint(x: box.minX, y: box.midY), to: CGPoint(x: box.maxX, y: box.midY))
    }

    /// A purity seal: parchment strips under a red wax disc.
    private static func seal(_ c: CGContext, at point: CGPoint, length: CGFloat, angle: CGFloat) {
        c.saveGState()
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: angle)
        for (x, ratio) in [(-9.0, 1.0), (3.0, 0.78)] as [(CGFloat, CGFloat)] {
            let strip = polygon([CGPoint(x: x, y: 0), CGPoint(x: x + 11, y: 0), CGPoint(x: x + 11, y: -length * ratio),
                                 CGPoint(x: x + 7, y: -length * ratio + 4), CGPoint(x: x + 3, y: -length * ratio - 2),
                                 CGPoint(x: x, y: -length * ratio + 3)])
            fill(c, strip, [color(0.9, 0.84, 0.68), color(0.7, 0.62, 0.45)], [0, 1],
                 from: CGPoint(x: x, y: 0), to: CGPoint(x: x + 11, y: -length))
            c.setStrokeColor(color(0.25, 0.18, 0.1, 0.6))
            c.setLineWidth(0.8)
            var y: CGFloat = -14
            while y > -length * ratio + 6 {
                line(c, [CGPoint(x: x + 2, y: y), CGPoint(x: x + 9, y: y)])
                y -= 6
            }
            c.strokePath()
        }
        if let gradient = gradient([color(0.75, 0.12, 0.08), color(0.38, 0.03, 0.02)], [0, 1]) {
            c.saveGState()
            c.addEllipse(in: CGRect(x: -12, y: -10, width: 24, height: 22))
            c.clip()
            c.drawRadialGradient(gradient, startCenter: CGPoint(x: -4, y: 6), startRadius: 0, endCenter: .zero, endRadius: 15,
                                 options: [.drawsAfterEndLocation])
            c.restoreGState()
        }
        c.restoreGState()
    }

    /// A winged cog around a skull, in gold.
    private static func emblem(_ c: CGContext, center: CGPoint, size: CGFloat) {
        let s = size / 100
        for side: CGFloat in [-1, 1] {
            for index in 0..<5 {
                let root = CGPoint(x: center.x + side * 26 * s, y: center.y + (12 - CGFloat(index) * 7) * s)
                let angle = 0.42 - CGFloat(index) * 0.2
                let length = (92 - CGFloat(index) * 9) * s
                let tip = CGPoint(x: root.x + side * cos(angle) * length, y: root.y + sin(angle) * length)
                gold(c, polygon([CGPoint(x: root.x, y: root.y - 6 * s), tip, CGPoint(x: root.x, y: root.y + 7 * s)]))
            }
        }
        let teeth = 12
        var points: [CGPoint] = []
        for index in 0..<(teeth * 2) {
            let angle = CGFloat(index) / CGFloat(teeth * 2) * 2 * .pi
            let radius = (index.isMultiple(of: 2) ? 34 : 28) * s
            for offset: CGFloat in [-0.1, 0.1] {
                points.append(CGPoint(x: center.x + cos(angle + offset) * radius, y: center.y + sin(angle + offset) * radius))
            }
        }
        gold(c, polygon(points))
        c.setFillColor(color(0.3, 0.3, 0.31))
        c.fillEllipse(in: CGRect(x: center.x - 21 * s, y: center.y - 21 * s, width: 42 * s, height: 42 * s))
        gold(c, CGPath(ellipseIn: CGRect(x: center.x - 13 * s, y: center.y - 8 * s, width: 26 * s, height: 24 * s), transform: nil))
        gold(c, CGPath(rect: CGRect(x: center.x - 8 * s, y: center.y - 15 * s, width: 16 * s, height: 9 * s), transform: nil))
        c.setFillColor(color(0.15, 0.1, 0.03))
        c.fillEllipse(in: CGRect(x: center.x - 9 * s, y: center.y, width: 7 * s, height: 7 * s))
        c.fillEllipse(in: CGRect(x: center.x + 2 * s, y: center.y, width: 7 * s, height: 7 * s))
    }

    private static func grime(_ c: CGContext, halfWidth: CGFloat, height: CGFloat, generator: inout Generator) {
        for _ in 0..<Int(halfWidth * height / 9_000) {
            let x = CGFloat.random(in: -halfWidth...halfWidth, using: &generator)
            let y = CGFloat.random(in: 0...height, using: &generator)
            c.setFillColor(color(0.08, 0.05, 0.02, CGFloat.random(in: 0.04...0.12, using: &generator)))
            c.fillEllipse(in: CGRect(x: x, y: y, width: CGFloat.random(in: 20...90, using: &generator),
                                     height: CGFloat.random(in: 10...50, using: &generator)))
        }
        for _ in 0..<Int(halfWidth / 25) {
            let x = CGFloat.random(in: -halfWidth...halfWidth, using: &generator)
            let top = CGFloat.random(in: 200...height, using: &generator)
            c.setFillColor(color(0.18, 0.09, 0.03, CGFloat.random(in: 0.05...0.14, using: &generator)))
            c.fill(CGRect(x: x, y: top - CGFloat.random(in: 60...240, using: &generator), width: 3, height: 200))
        }
        if let fog = gradient([color(0, 0, 0, 0.75), color(0, 0, 0, 0)], [0, 1]) {
            c.drawLinearGradient(fog, start: .zero, end: CGPoint(x: 0, y: 200), options: [])
        }
        if let vignette = gradient([color(0, 0, 0, 0), color(0, 0, 0, 0.55)], [0.55, 1]) {
            let center = CGPoint(x: 0, y: height * 0.55)
            c.drawRadialGradient(vignette, startCenter: center, startRadius: 0, endCenter: center,
                                 endRadius: max(halfWidth, height) * 1.05, options: [.drawsAfterEndLocation])
        }
    }

    // MARK: Helpers

    static func texture(size: CGSize, scale: CGFloat = 2, _ draw: (CGContext) -> Void) -> SKTexture {
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return SKTexture() }
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        draw(context)
        let texture = context.makeImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
        texture.filteringMode = .linear
        return texture
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: min(1, red), green: min(1, green), blue: min(1, blue), alpha: alpha)
    }

    private static func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func line(_ context: CGContext, _ points: [CGPoint]) {
        context.addLines(between: points)
    }

    private static func fill(_ c: CGContext, _ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat],
                             from start: CGPoint, to end: CGPoint) {
        guard let gradient = gradient(colors, locations) else { return }
        c.saveGState()
        c.addPath(path)
        c.clip()
        c.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }

    private static func gold(_ c: CGContext, _ path: CGPath) {
        let box = path.boundingBox
        fill(c, path, [color(0.38, 0.26, 0.07), color(0.96, 0.8, 0.42), color(0.58, 0.41, 0.12), color(0.88, 0.7, 0.32)],
             [0, 0.38, 0.68, 1], from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
        c.addPath(path)
        c.setStrokeColor(color(0.18, 0.11, 0.03))
        c.setLineWidth(1.5)
        c.strokePath()
    }

    private static func metal(_ c: CGContext, _ path: CGPath, tone: CGFloat) {
        let box = path.boundingBox
        fill(c, path, [color(tone * 1.45, tone * 1.45, tone * 1.5), color(tone, tone, tone * 1.04),
                       color(tone * 0.6, tone * 0.6, tone * 0.64)], [0, 0.5, 1],
             from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.minX, y: box.minY))
    }
}
