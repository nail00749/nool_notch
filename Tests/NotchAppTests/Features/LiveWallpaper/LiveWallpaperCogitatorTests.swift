import AppKit
import MetalKit
import SpriteKit
import XCTest
@testable import NotchApp

final class LiveWallpaperCogitatorTests: XCTestCase {
    func testInterferenceGrowsWithCursorSpeed() {
        XCTAssertEqual(LiveWallpaperCogitatorRules.interference(speed: 100), 0)
        XCTAssertEqual(LiveWallpaperCogitatorRules.interference(speed: 1_400), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LiveWallpaperCogitatorRules.interference(speed: 9_000), 1)
        XCTAssertLessThan(LiveWallpaperCogitatorRules.snuffSpeed(strength: 1), LiveWallpaperCogitatorRules.snuffSpeed(strength: 0.2))
    }

    func testEyesLookTowardTheCursorWithinTheirSocket() {
        let eye = CGPoint(x: 100, y: 100)
        let gaze = LiveWallpaperCogitatorRules.gaze(eye: eye, cursor: CGPoint(x: 900, y: 100), radius: 10)
        XCTAssertEqual(gaze.dx, 3.5, accuracy: 0.0001)
        XCTAssertEqual(gaze.dy, 0, accuracy: 0.0001)
        XCTAssertEqual(LiveWallpaperCogitatorRules.gaze(eye: eye, cursor: nil, radius: 10), .zero)
        XCTAssertEqual(LiveWallpaperCogitatorRules.distance(from: CGPoint(x: 5, y: 3), toSegment: .zero, CGPoint(x: 10, y: 0)), 3,
                       accuracy: 0.0001)
    }

    func testRiteChargesAfterStillnessAndRearmsOnlyAfterTheCursorMoves() {
        var dwell = LiveWallpaperCogitatorDwell()
        let point = CGPoint(x: 500, y: 300)
        var charge: CGFloat = 0
        for _ in 0..<60 { charge = dwell.advance(cursor: point, dt: 1.0 / 30, ready: true) }
        XCTAssertEqual(charge, 0, "Two seconds of stillness only start the charge")
        for _ in 0..<50 { charge = dwell.advance(cursor: point, dt: 1.0 / 30, ready: true) }
        XCTAssertEqual(charge, 1, accuracy: 0.0001)
        dwell.fire()
        for _ in 0..<200 { charge = dwell.advance(cursor: point, dt: 1.0 / 30, ready: true) }
        XCTAssertEqual(charge, 0, "A resting cursor must not repeat the rite forever")
        XCTAssertFalse(dwell.isArmed)
        _ = dwell.advance(cursor: CGPoint(x: 640, y: 300), dt: 1.0 / 30, ready: true)
        XCTAssertTrue(dwell.isArmed)
        // Jitter inside the tolerance keeps the dwell; a real move restarts it.
        for index in 0..<40 {
            _ = dwell.advance(cursor: CGPoint(x: 640 + CGFloat(index % 2) * 3, y: 300), dt: 1.0 / 30, ready: true)
        }
        XCTAssertGreaterThan(dwell.stillTime, 1)
        _ = dwell.advance(cursor: CGPoint(x: 700, y: 300), dt: 1.0 / 30, ready: true)
        XCTAssertEqual(dwell.stillTime, 0)
        for _ in 0..<200 { charge = dwell.advance(cursor: CGPoint(x: 700, y: 300), dt: 1.0 / 30, ready: false) }
        XCTAssertEqual(charge, 0, "Cooldown blocks the charge")
    }

    @MainActor
    func testHoldingTheCursorOnTheSkullCallsTheBlessing() {
        let size = CGSize(width: 1_440, height: 900)
        var cursor: CGPoint?
        let scene = LiveWallpaperCogitatorScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                                settings: LiveWallpaperSceneSettings(), cursorProvider: { cursor })
        XCTAssertEqual(scene.screenCount, 6)
        XCTAssertGreaterThan(scene.candleCount, 8)
        XCTAssertGreaterThanOrEqual(scene.eyeCount, 6)
        cursor = scene.mainSkull
        var time: TimeInterval = 0
        for _ in 0..<(30 * 5) {
            scene.update(time)
            time += 1.0 / 30
        }
        XCTAssertEqual(scene.riteCount, 1)
        XCTAssertEqual(scene.lastRite, .blessing)
        XCTAssertGreaterThan(scene.riteCooldownRemaining, 0)

        cursor = CGPoint(x: 200, y: 160)
        for _ in 0..<(30 * 14) {
            scene.update(time)
            time += 1.0 / 30
        }
        XCTAssertEqual(scene.riteCount, 2)
        XCTAssertEqual(scene.lastRite, .purification)
    }

    @MainActor
    func testAFastSweepSnuffsACandleThatRelightsLater() throws {
        let size = CGSize(width: 1_728, height: 1_117)
        var cursor: CGPoint?
        let scene = LiveWallpaperCogitatorScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                                settings: LiveWallpaperSceneSettings(), cursorProvider: { cursor })
        let tip = try XCTUnwrap(scene.candleTips.first)
        var time: TimeInterval = 0
        for step in 0...8 {
            cursor = CGPoint(x: tip.x - 320 + CGFloat(step) * 80, y: tip.y)
            scene.update(time)
            time += 1.0 / 30
        }
        XCTAssertLessThan(scene.litCandleCount, scene.candleCount)
        XCTAssertGreaterThan(scene.interference, 0)
        cursor = nil
        for _ in 0..<(30 * 8) {
            scene.update(time)
            time += 1.0 / 30
        }
        XCTAssertEqual(scene.litCandleCount, scene.candleCount)
    }

    @MainActor
    func testDisabledCursorLeavesTheShrineAlone() {
        let size = CGSize(width: 1_280, height: 800)
        var settings = LiveWallpaperSceneSettings()
        settings.cursorMode = .off
        var scene: LiveWallpaperCogitatorScene?
        scene = LiveWallpaperCogitatorScene(size: size, screenFrame: CGRect(origin: .zero, size: size), settings: settings,
                                            cursorProvider: { scene?.mainSkull })
        var time: TimeInterval = 0
        for _ in 0..<(30 * 6) {
            scene?.update(time)
            time += 1.0 / 30
        }
        XCTAssertEqual(scene?.riteCount, 0)
        XCTAssertEqual(scene?.litCandleCount, scene?.candleCount)
    }

    @MainActor
    func testRendererHostsTheSceneInSpriteKitAndSnapshotsIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this Mac") }
        _ = NSApplication.shared
        guard let display = NSScreen.screens.first,
              let number = display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw XCTSkip("A window-server display is unavailable")
        }
        let renderer = DesktopLiveWallpaperRenderer()
        defer { renderer.apply(nil) }
        let frame = CGRect(x: display.frame.minX + 20, y: display.frame.minY + 20, width: 480, height: 300)
        let screen = LiveWallpaperScreen(displayID: number.uint32Value, frame: frame, content: .scene(.cogitator))
        renderer.apply(LiveWallpaperRenderConfiguration(screens: [screen], scaleMode: .fill, volume: 0, playbackRate: 1,
                                                        isPlaying: true, pausesHiddenScreens: false,
                                                        scene: LiveWallpaperSceneSettings()))
        XCTAssertEqual(renderer.sceneBackend(forDisplay: number.uint32Value), .spriteKit)
        XCTAssertNotNil(renderer.sceneSnapshot(forDisplay: number.uint32Value))
    }

    /// Writes PNG previews when `NOOL_COGITATOR_PREVIEW_DIR` is set; otherwise only checks the frame renders.
    @MainActor
    func testPreviewAtDesktopAspectRatios() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this Mac") }
        _ = NSApplication.shared
        for size in [CGSize(width: 1_728, height: 1_117), CGSize(width: 2_560, height: 1_080)] {
            var cursor: CGPoint?
            let scene = LiveWallpaperCogitatorScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                                    settings: LiveWallpaperSceneSettings(), cursorProvider: { cursor })
            scene.setEnergy(0.4)
            cursor = CGPoint(x: size.width * 0.5 + 60, y: scene.mainSkull.y - 40)
            let view = SKView(frame: CGRect(origin: .zero, size: size))
            view.ignoresSiblingOrder = true
            view.presentScene(scene)
            var time: TimeInterval = 0
            for _ in 0..<100 {
                scene.update(time)
                time += 1.0 / 30
            }
            let image = try XCTUnwrap(view.texture(from: scene)?.cgImage())
            XCTAssertGreaterThan(image.width, 0)
            if let directory = ProcessInfo.processInfo.environment["NOOL_COGITATOR_PREVIEW_DIR"] {
                let bitmap = NSBitmapImageRep(cgImage: image)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("cogitator-\(Int(size.width)).png"))
            }
        }
    }
}
