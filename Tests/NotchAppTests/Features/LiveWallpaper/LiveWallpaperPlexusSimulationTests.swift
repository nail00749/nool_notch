import AppKit
import SpriteKit
import XCTest
@testable import NotchApp

@MainActor
final class LiveWallpaperPlexusSimulationTests: XCTestCase {
    func testSharedSeedMatchesSpriteKitOverSixHundredFramesWithCursorEnergyAndResume() throws {
        let cases: [(CGSize, LiveWallpaperCursorMode)] = [
            (CGSize(width: 1100, height: 700), .repel),
            (CGSize(width: 5120, height: 1440), .attract),
            (CGSize(width: 320, height: 220), .off)
        ]
        for (size, mode) in cases {
            var settings = LiveWallpaperSceneSettings()
            settings.cursorMode = mode
            settings.cursorStrength = 0.8
            settings.parallax = 0.65
            settings.density = 2
            settings.framesPerSecond = 60
            var cursor: CGPoint?
            let scene = LiveWallpaperParticleScene(
                size: size, screenFrame: CGRect(origin: .zero, size: size), content: .scene(.plexus),
                settings: settings, cursorProvider: { cursor })
            let seed = try XCTUnwrap(scene.exportPlexusSeed())
            let model = LiveWallpaperPlexusSimulation(seed: seed)
            var latestLines: [LiveWallpaperPlexusSegment] = []
            scene.setLineRenderer { lines, _ in latestLines = lines }
            try assertFrame(model.frame, matches: scene, lines: latestLines)
            XCTAssertEqual(seed.gradient.width, 1_024)
            XCTAssertEqual(seed.gradient.height, 2_048)
            XCTAssertEqual(seed.glow.width, 512)
            XCTAssertEqual(seed.glow.height, 512)

            var timeOffset: TimeInterval = 0
            for index in 0..<600 {
                if index % 90 < 15 { cursor = nil }
                else {
                    cursor = CGPoint(x: size.width * (0.5 + 0.45 * sin(Double(index) * 0.031)),
                                     y: size.height * (0.5 + 0.45 * cos(Double(index) * 0.047)))
                }
                if index == 100 { scene.setEnergy(1); model.setEnergy(1) }
                if index == 250 { scene.setEnergy(0.2); model.setEnergy(0.2) }
                if index == 400 { scene.setEnergy(0); model.setEnergy(0) }
                if index == 550 { scene.setEnergy(.nan); model.setEnergy(.nan) }
                if index == 300 {
                    scene.resumeClock()
                    model.resumeClock()
                    timeOffset += 10_000
                }
                if index == 480 { timeOffset += 0.6 }
                let time = Double(index) / 60 + timeOffset
                scene.update(time)
                let frame = model.advance(at: time, cursor: cursor)
                try assertFrame(frame, matches: scene, lines: latestLines)
            }

            // A/B runs must share the original random seed, not just the same preset.
            XCTAssertTrue(scene.restorePlexusPrototypeSeed(seed))
            let replay = LiveWallpaperPlexusSimulation(seed: seed)
            try assertFrame(replay.frame, matches: scene, lines: latestLines)
            for index in 0..<60 {
                cursor = CGPoint(x: size.width * 0.25, y: size.height * 0.75)
                scene.update(Double(index) / 60)
                try assertFrame(replay.advance(at: Double(index) / 60, cursor: cursor),
                                matches: scene, lines: latestLines)
            }
        }
    }

    func testPrototypeRestoreRejectsMismatchedGeometryWithoutMutatingScene() throws {
        let size = CGSize(width: 640, height: 400)
        let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                              content: .scene(.plexus), settings: LiveWallpaperSceneSettings(),
                                              cursorProvider: { nil })
        let seed = try XCTUnwrap(scene.exportPlexusSeed())
        scene.update(0)
        scene.update(1)
        let positions = spriteNodes(in: scene).map(\.position)
        let wrongSize = LiveWallpaperPlexusSeed(size: CGSize(width: 641, height: 400), settings: seed.settings,
            gradient: seed.gradient, glow: seed.glow, backgroundSize: seed.backgroundSize,
            clouds: seed.clouds, particles: seed.particles)
        XCTAssertFalse(scene.restorePlexusPrototypeSeed(wrongSize))
        let wrongCount = LiveWallpaperPlexusSeed(size: size, settings: seed.settings,
            gradient: seed.gradient, glow: seed.glow, backgroundSize: seed.backgroundSize,
            clouds: seed.clouds, particles: Array(seed.particles.dropLast()))
        XCTAssertFalse(scene.restorePlexusPrototypeSeed(wrongCount))
        var settings = seed.settings
        settings.cursorStrength += 0.1
        let wrongSettings = LiveWallpaperPlexusSeed(size: size, settings: settings,
            gradient: seed.gradient, glow: seed.glow, backgroundSize: seed.backgroundSize,
            clouds: seed.clouds, particles: seed.particles)
        XCTAssertFalse(scene.restorePlexusPrototypeSeed(wrongSettings))
        XCTAssertEqual(spriteNodes(in: scene).map(\.position), positions)
    }

    func testHighResolutionBackgroundKeepsPaletteAndSpreadsEightBitRoundingAcrossRows() throws {
        let size = CGSize(width: 5120, height: 1440)
        let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
            content: .scene(.plexus), settings: LiveWallpaperSceneSettings(), cursorProvider: { nil })
        let seed = try XCTUnwrap(scene.exportPlexusSeed())
        let background = try XCTUnwrap(scene.children.compactMap { $0 as? SKSpriteNode }
            .first { $0.zPosition == 0 })
        XCTAssertEqual(background.texture?.filteringMode, .linear)
        XCTAssertTrue(spriteNodes(in: scene).allSatisfy { $0.texture?.filteringMode == .linear })

        // Compare against the original Core Graphics gradient at matching resolution. More pixels
        // and dithering must smooth the same palette, including its vertical orientation.
        let space = CGColorSpaceCreateDeviceRGB()
        let (top, bottom) = LiveWallpaperScenePreset.plexus.gradient
        let reference = try XCTUnwrap(CGContext(data: nil, width: seed.gradient.width, height: seed.gradient.height,
            bitsPerComponent: 8, bytesPerRow: seed.gradient.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: [
            CGColor(red: bottom.x, green: bottom.y, blue: bottom.z, alpha: 1),
            CGColor(red: top.x, green: top.y, blue: top.z, alpha: 1)
        ] as CFArray, locations: [0, 1]))
        reference.drawLinearGradient(gradient, start: .zero,
            end: CGPoint(x: 0, y: seed.gradient.height), options: [])
        let actualPixels = try rgbaPixels(seed.gradient)
        // SpriteKit exports its own CGImage color-space metadata; put both sources through
        // the identical texture import/export before comparing their normalized pixels.
        let referenceTexture = SKTexture(cgImage: try XCTUnwrap(reference.makeImage()))
        let referencePixels = try rgbaPixels(referenceTexture.cgImage())
        let row = seed.gradient.height / 2
        var distinctRedValues = Set<UInt8>()
        for y in [0, row, seed.gradient.height - 1] {
            for x in 0..<seed.gradient.width {
                let offset = (y * seed.gradient.width + x) * 4
                for channel in 0..<3 {
                    let difference = Double(actualPixels[offset + channel]) - Double(referencePixels[offset + channel])
                    XCTAssertLessThanOrEqual(abs(difference), 1)
                }
                XCTAssertEqual(actualPixels[offset + 3], 255)
                if y == row { distinctRedValues.insert(actualPixels[offset]) }
            }
        }
        XCTAssertEqual(distinctRedValues.count, 2, "A dark gradient row distributes adjacent shades instead of forming a solid band")
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    func testSeedExportIsLimitedToPlexusAndKeepsOriginalTexturePixels() throws {
        let size = CGSize(width: 640, height: 400)
        for preset in LiveWallpaperScenePreset.allCases {
            let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                content: .scene(preset), settings: LiveWallpaperSceneSettings(), cursorProvider: { nil })
            if preset == .plexus {
                let seed = try XCTUnwrap(scene.exportPlexusSeed())
                let background = try XCTUnwrap(scene.children.compactMap { $0 as? SKSpriteNode }
                    .first { $0.zPosition == 0 })
                let pixels = try XCTUnwrap(background.texture?.cgImage().dataProvider?.data)
                XCTAssertEqual(seed.gradient.dataProvider?.data, pixels)
                let cloud = try XCTUnwrap(spriteNodes(in: scene).first)
                XCTAssertEqual(seed.glow.dataProvider?.data, cloud.texture?.cgImage().dataProvider?.data)
            } else { XCTAssertNil(scene.exportPlexusSeed()) }
        }
    }

    private func spriteNodes(in scene: LiveWallpaperParticleScene) -> [SKSpriteNode] {
        let clouds = scene.children.compactMap { $0 as? SKSpriteNode }.filter { $0.zPosition == 1 }
        let particles = scene.children.first { $0.zPosition == 10 }?.children.compactMap { $0 as? SKSpriteNode } ?? []
        return clouds + particles
    }

    private func assertFrame(_ frame: LiveWallpaperPlexusFrame, matches scene: LiveWallpaperParticleScene,
                             lines: [LiveWallpaperPlexusSegment],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let nodes = spriteNodes(in: scene)
        XCTAssertEqual(frame.size, scene.size, file: file, line: line)
        XCTAssertEqual(frame.sprites.map(\.center), nodes.map(\.position), file: file, line: line)
        XCTAssertEqual(frame.sprites.map(\.size), nodes.map(\.size), file: file, line: line)
        XCTAssertEqual(frame.lines, lines, file: file, line: line)
        let background = try XCTUnwrap(scene.children.compactMap { $0 as? SKSpriteNode }
            .first { $0.zPosition == 0 }, file: file, line: line)
        XCTAssertEqual(frame.backgroundCenter, background.position, file: file, line: line)
        XCTAssertEqual(frame.backgroundSize, background.size, file: file, line: line)
        for (sprite, node) in zip(frame.sprites, nodes) {
            let color = try XCTUnwrap(node.color.usingColorSpace(.deviceRGB), file: file, line: line)
            let expected = SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent),
                                 Float(color.alphaComponent * node.alpha))
            if zip(sprite.color.indices, expected.indices).contains(where: { abs(sprite.color[$0.0] - expected[$0.1]) > 0.000001 }) {
                XCTFail("Sprite color \(sprite.color) differs from SpriteKit \(expected)", file: file, line: line)
                return
            }
        }
    }
}
