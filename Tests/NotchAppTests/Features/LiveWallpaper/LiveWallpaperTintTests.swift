import AppKit
import SpriteKit
import XCTest
@testable import NotchApp

@MainActor
final class LiveWallpaperTintTests: XCTestCase {
    func testAllPresetColorsMatchOriginalPerNodeBlendThroughLoadChangesAndReset() throws {
        for preset in LiveWallpaperScenePreset.allCases {
            let scene = makeScene(content: .scene(preset))
            var clock = TintClock()
            for target in [0.2, 0.8, 1.0, 0.35, 0.0] {
                scene.setEnergy(target)
                for _ in 0..<150 {
                    clock.step(scene: scene, target: target)
                    try assertColors(in: scene, appliedEnergy: clock.appliedEnergy)
                }
            }
            XCTAssertEqual(clock.appliedEnergy, 0, "Tint eventually returns to the original color")
            if preset == .embers {
                let bases = try tintNodes(in: scene).map { try XCTUnwrap($0.userData?["nool.baseColor"] as? NSColor) }
                XCTAssertGreaterThan(Set(bases).count, 3, "Embers retain their individually randomized base colors")
            }
        }
    }

    func testRebuildRegroupsNewNodesAndLeavesRemovedNodesUntouched() throws {
        let scene = makeScene(content: .scene(.plexus))
        var clock = TintClock()
        scene.setEnergy(1)
        for _ in 0..<150 { clock.step(scene: scene, target: 1) }
        let oldNodes = tintNodes(in: scene)
        let oldColors = oldNodes.map(\.color)
        var settings = makeSettings()
        settings.density = 1.75
        scene.update(settings: settings, screenFrame: CGRect(origin: .zero, size: scene.size))
        clock.appliedEnergy = nil
        clock.tintedEnergy = 0
        try assertColors(in: scene, appliedEnergy: nil)
        let oldIDs = Set(oldNodes.map(ObjectIdentifier.init))
        XCTAssertTrue(tintNodes(in: scene).allSatisfy { !oldIDs.contains(ObjectIdentifier($0)) })
        scene.setEnergy(0.2)
        for _ in 0..<90 {
            clock.step(scene: scene, target: 0.2)
            try assertColors(in: scene, appliedEnergy: clock.appliedEnergy)
        }
        for (node, color) in zip(oldNodes, oldColors) {
            XCTAssertEqual(node.color, color, "The tint cache must release nodes from the previous scene build")
        }
    }

    func testDisablingImageParticlesClearsTintGroups() throws {
        var settings = makeSettings()
        settings.imageParticles = .embers
        let scene = makeScene(content: .image(URL(fileURLWithPath: "/tmp/nool-tint-test-missing-image.jpg")),
                              settings: settings)
        var clock = TintClock()
        scene.setEnergy(1)
        for _ in 0..<90 { clock.step(scene: scene, target: 1) }
        let oldNodes = tintNodes(in: scene), oldColors = tintNodes(in: scene).map(\.color)
        settings.imageParticles = .none
        scene.update(settings: settings, screenFrame: CGRect(origin: .zero, size: scene.size))
        XCTAssertTrue(tintNodes(in: scene).isEmpty)
        scene.setEnergy(0)
        for _ in 0..<90 { clock.step(scene: scene, target: 0) }
        for (node, color) in zip(oldNodes, oldColors) { XCTAssertEqual(node.color, color) }
    }

    private func makeSettings() -> LiveWallpaperSceneSettings {
        var settings = LiveWallpaperSceneSettings()
        settings.cursorMode = .off
        settings.parallax = 0
        settings.density = 2
        settings.framesPerSecond = 60
        return settings
    }

    private func makeScene(content: LiveWallpaperContent,
                           settings: LiveWallpaperSceneSettings? = nil) -> LiveWallpaperParticleScene {
        let size = CGSize(width: 1100, height: 700)
        return LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                          content: content, settings: settings ?? makeSettings())
    }

    private func tintNodes(in scene: LiveWallpaperParticleScene) -> [SKSpriteNode] {
        (scene.children + scene.children.flatMap(\.children)).compactMap { node in
            guard let sprite = node as? SKSpriteNode, sprite.userData?["nool.baseColor"] is NSColor else { return nil }
            return sprite
        }
    }

    private func assertColors(in scene: LiveWallpaperParticleScene, appliedEnergy: CGFloat?,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let warm = NSColor(red: 1, green: 0.45, blue: 0.25, alpha: 1)
        let referenceNode = SKSpriteNode()
        for node in tintNodes(in: scene) {
            let base = try XCTUnwrap(node.userData?["nool.baseColor"] as? NSColor, file: file, line: line)
            let expected = appliedEnergy.map { base.blended(withFraction: $0 * 0.7, of: warm) ?? base } ?? base
            // SpriteKit converts assigned AppKit colors into its device RGB representation.
            // Compare the old assignment's output, rather than unrelated color-space components.
            referenceNode.color = expected
            XCTAssertEqual(node.color, referenceNode.color, file: file, line: line)
        }
    }

    private struct TintClock {
        var energy: CGFloat = 0
        var tintedEnergy: CGFloat = 0
        var appliedEnergy: CGFloat?
        var time: Double = 0
        var lastTime: Double?

        @MainActor
        mutating func step(scene: LiveWallpaperParticleScene, target: Double) {
            time += 1.0 / 60
            let frameTime = CGFloat(min(1.0 / 15, max(0, time - (lastTime ?? time))))
            lastTime = time
            energy += (CGFloat(target) - energy) * (1 - exp(-frameTime * 1.5))
            if abs(energy - tintedEnergy) > 0.03 || (energy < 0.01 && tintedEnergy != 0) {
                tintedEnergy = energy < 0.01 ? 0 : energy
                appliedEnergy = tintedEnergy
            }
            scene.update(time)
        }
    }
}
