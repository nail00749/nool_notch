import AppKit
import NotchCore
import SpriteKit
import XCTest
@testable import NotchApp

final class LiveWallpaperPolicyTests: XCTestCase {
    func testOverlaySettingsDecodeSanitizeAndTargetMainDisplay() throws {
        let decoded = try JSONDecoder().decode(LiveWallpaperOverlaySettings.self, from: Data(#"{"showsQuotas":true,"opacity":7,"metrics":["network","cpu"]}"#.utf8))
        XCTAssertTrue(decoded.showsQuotas)
        XCTAssertTrue(decoded.hiddenQuotaProviderIDs.isEmpty)
        XCTAssertEqual(decoded.position, .bottomRight)
        XCTAssertEqual(decoded.horizontalInset, 64)
        XCTAssertEqual(decoded.verticalInset, 160)
        var custom = decoded
        custom.hiddenQuotaProviderIDs = ["codex", "claude"]
        custom.horizontalInset = 120
        custom.verticalInset = 240
        XCTAssertEqual(try JSONDecoder().decode(LiveWallpaperOverlaySettings.self,
                                              from: JSONEncoder().encode(custom)), custom)
        custom.horizontalInset = -10
        custom.verticalInset = 900
        XCTAssertEqual(custom.sanitized.horizontalInset, 0)
        XCTAssertEqual(custom.sanitized.verticalInset, 320)
        XCTAssertEqual(decoded.sanitized.opacity, 1)
        XCTAssertEqual(decoded.sanitized.metrics, [.cpu, .network])
        XCTAssertFalse(LiveWallpaperOverlaySettings().isVisible)
        XCTAssertFalse(LiveWallpaperOverlaySettings().needsSystemMetrics)

        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "nool-scene-snow"
        preferences.overlay.showsSystem = true
        let displays = [
            LiveWallpaperDisplay(key: "main", displayID: 1, name: "A", frame: .init(x: 0, y: 0, width: 100, height: 100)),
            LiveWallpaperDisplay(key: "side", displayID: 2, name: "B", frame: .init(x: 100, y: 0, width: 100, height: 100))
        ]
        let resolve: (String) -> LiveWallpaperContent? = { LiveWallpaperScenePreset(key: $0).map(LiveWallpaperContent.scene) }
        let mainOnly = LiveWallpaperPolicy.configuration(displays: displays, preferences: preferences,
                                                        environment: LiveWallpaperEnvironment(), resolve: resolve)
        XCTAssertEqual(mainOnly?.screens.map(\.showsOverlay), [true, false])
        preferences.overlay.mainDisplayOnly = false
        let everywhere = LiveWallpaperPolicy.configuration(displays: displays, preferences: preferences,
                                                          environment: LiveWallpaperEnvironment(), resolve: resolve)
        XCTAssertEqual(everywhere?.screens.map(\.showsOverlay), [true, true])
    }

    func testStateRequiresEnabledVideoAndRespectsPauseReasons() {
        var preferences = LiveWallpaperPreferences()
        let environment = LiveWallpaperEnvironment()
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment), .hidden)
        preferences.enabled = true
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: false, environment: environment), .hidden)
        XCTAssertEqual(LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment), .playing)

        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isAsleep: true, isCovered: true)), .paused(.asleep))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isOnBattery: true)), .paused(.power))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isLowPowerMode: true)), .paused(.power))
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isCovered: true)), .paused(.covered))

        preferences.pausesOnBattery = false
        preferences.pausesWhenCovered = false
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isOnBattery: true, isCovered: true)), .playing)
        XCTAssertEqual(state(preferences, LiveWallpaperEnvironment(isAsleep: true)), .paused(.asleep))
    }

    func testConfigurationIsNilWithoutScreensAndCarriesSanitizedValues() {
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "a.mp4"
        preferences.volume = 4
        preferences.playbackRate = .nan
        let display = LiveWallpaperDisplay(key: "A", displayID: 1, name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertNil(LiveWallpaperPolicy.configuration(displays: [], preferences: preferences,
                                                       environment: LiveWallpaperEnvironment(), resolve: Self.resolve))
        let configuration = LiveWallpaperPolicy.configuration(
            displays: [display], preferences: preferences,
            environment: LiveWallpaperEnvironment(isCovered: true), resolve: Self.resolve)
        XCTAssertEqual(configuration?.volume, 1)
        XCTAssertEqual(configuration?.playbackRate, 1)
        XCTAssertEqual(configuration?.isPlaying, false)
    }

    func testEachDisplayUsesItsOwnVideoOrFallsBackToSharedOne() {
        let displays = ["A", "B", "C"].enumerated().map { index, key in
            LiveWallpaperDisplay(key: key, displayID: CGDirectDisplayID(index + 1), name: key,
                                 frame: CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100))
        }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.displayFileNames = ["B": "b.mov", "C": "missing.mp4"]
        var configuration = LiveWallpaperPolicy.configuration(
            displays: displays, preferences: preferences, environment: LiveWallpaperEnvironment(), resolve: Self.resolve)
        XCTAssertEqual(configuration?.screens.map(\.displayID), [2], "Only displays with an existing video render")
        XCTAssertEqual(configuration?.screens.first?.content.fileName, "b.mov")

        preferences.selectedFileName = "a.mp4"
        configuration = LiveWallpaperPolicy.configuration(
            displays: displays, preferences: preferences, environment: LiveWallpaperEnvironment(), resolve: Self.resolve)
        XCTAssertEqual(configuration?.screens.map(\.content.fileName), ["a.mp4", "b.mov"])

        preferences.forget(fileName: "b.mov")
        XCTAssertNil(preferences.displayFileNames["B"])
        XCTAssertEqual(preferences.fileName(forDisplay: "B"), "a.mp4")
    }

    private static func resolve(_ name: String) -> LiveWallpaperContent? {
        name == "missing.mp4" ? nil : .video(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testScenePresetsAreAcceptableKeysAndSceneSettingsSanitize() throws {
        XCTAssertEqual(LiveWallpaperScenePreset(key: "nool-scene-plexus"), .plexus)
        XCTAssertNil(LiveWallpaperScenePreset(key: "nool-scene-unknown"))
        XCTAssertTrue(LiveWallpaperItem.isAcceptableKey("nool-scene-snow"))
        XCTAssertTrue(LiveWallpaperItem.isAcceptableKey("photo.HEIC"))
        XCTAssertEqual(LiveWallpaperItem.presets.count, LiveWallpaperScenePreset.allCases.count)

        var scene = LiveWallpaperSceneSettings()
        scene.density = 9
        scene.cursorStrength = .nan
        scene.parallax = -1
        scene.framesPerSecond = 120
        let sanitized = scene.sanitized
        XCTAssertEqual(sanitized.density, 2)
        XCTAssertEqual(sanitized.cursorStrength, 0.6)
        XCTAssertEqual(sanitized.parallax, 0)
        XCTAssertEqual(sanitized.framesPerSecond, 60)

        let decoded = try JSONDecoder().decode(LiveWallpaperPreferences.self,
                                               from: Data(#"{"scene":{"cursorMode":"attract"}}"#.utf8))
        XCTAssertEqual(decoded.scene.cursorMode, .attract)
        XCTAssertEqual(decoded.scene.framesPerSecond, 30)
    }

    func testPreferencesDecodeMissingKeysAndRejectUnsafeFileNames() throws {
        let decoded = try JSONDecoder().decode(LiveWallpaperPreferences.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertTrue(decoded.pausesOnBattery)
        XCTAssertEqual(decoded.scaleMode, .fill)
        XCTAssertEqual(decoded.displayFileNames, [:])

        var preferences = LiveWallpaperPreferences()
        for name in ["../secret.mp4", ".hidden.mp4", "a/b.mov", "clip.txt"] {
            preferences.selectedFileName = name
            XCTAssertNil(preferences.sanitized.selectedFileName, name)
        }
        preferences.selectedFileName = "Ocean 2.MOV"
        XCTAssertEqual(preferences.sanitized.selectedFileName, "Ocean 2.MOV")
        preferences.displayFileNames = ["A": "../x.mp4", "": "a.mp4", "B": "b.mp4"]
        XCTAssertEqual(preferences.sanitized.displayFileNames, ["B": "b.mp4"])
    }

    private func state(_ preferences: LiveWallpaperPreferences,
                       _ environment: LiveWallpaperEnvironment) -> LiveWallpaperPlaybackState {
        LiveWallpaperPolicy.state(preferences: preferences, hasContent: true, environment: environment)
    }
}

final class LiveWallpaperMotionTests: XCTestCase {
    @MainActor
    func testAllParticleStylesPreserveNodesAndResumeWithoutAMotionJump() throws {
        for preset in LiveWallpaperScenePreset.allCases {
            var settings = LiveWallpaperSceneSettings()
            settings.cursorMode = .off
            settings.parallax = 0
            settings.imageParticles = preset.particles
            let size = CGSize(width: 320, height: 220)
            let scene = LiveWallpaperParticleScene(
                size: size, screenFrame: CGRect(origin: .zero, size: size),
                content: .image(URL(fileURLWithPath: "/tmp/nool-test-missing-motion-background.jpg")), settings: settings)
            let layer = try XCTUnwrap(scene.children.first { $0.zPosition == 10 })
            let particles = layer.children.compactMap { $0 as? SKSpriteNode }
            XCTAssertFalse(particles.isEmpty, preset.rawValue)
            let initial = particles.map(\.position)
            for frame in 0..<180 { scene.update(Double(frame) / 60) }
            XCTAssertNotEqual(particles.map(\.position), initial, "Stored motion must advance on successive frames")
            let positions = particles.map(\.position)
            let alphas = particles.map(\.alpha)
            scene.resumeClock()
            scene.update(1_000)
            XCTAssertEqual(particles.map(\.position), positions, "The first resumed frame has zero motion time")
            XCTAssertEqual(particles.map(\.alpha), alphas, "The first resumed frame preserves the pulse/fade phase")
            scene.update(1_000 + 1.0 / 60)
            XCTAssertNotEqual(particles.map(\.position), positions)
            XCTAssertTrue(particles.allSatisfy { $0.parent === layer })
            XCTAssertTrue(particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.alpha.isFinite })
        }
    }

    func testCursorPushesWithinRadiusOnlyAndRespectsMode() {
        let cursor = CGPoint(x: 100, y: 100)
        let near = CGPoint(x: 150, y: 100)
        let repel = LiveWallpaperMotion.cursorAcceleration(particle: near, cursor: cursor, mode: .repel, strength: 1)
        let attract = LiveWallpaperMotion.cursorAcceleration(particle: near, cursor: cursor, mode: .attract, strength: 1)
        XCTAssertGreaterThan(repel.dx, 0)
        XCTAssertEqual(repel.dy, 0, accuracy: 0.001)
        XCTAssertEqual(attract.dx, -repel.dx, accuracy: 0.001)

        let closer = LiveWallpaperMotion.cursorAcceleration(particle: CGPoint(x: 120, y: 100), cursor: cursor,
                                                            mode: .repel, strength: 1)
        XCTAssertGreaterThan(closer.dx, repel.dx, "Force falls off with distance")
        for (point, mode, strength, cursor) in [
            (CGPoint(x: 1_000, y: 100), LiveWallpaperCursorMode.repel, 1.0, Optional(cursor)),
            (near, .off, 1, cursor), (near, .repel, 0, cursor), (near, .repel, 1, nil)
        ] {
            XCTAssertEqual(LiveWallpaperMotion.cursorAcceleration(particle: point, cursor: cursor, mode: mode,
                                                                  strength: strength), .zero)
        }
    }

    func testParallaxMovesAgainstCursorAndParticleCountScalesWithArea() {
        let size = CGSize(width: 1000, height: 500)
        XCTAssertEqual(LiveWallpaperMotion.parallaxOffset(cursor: CGPoint(x: 500, y: 250), size: size, amount: 1), .zero)
        let right = LiveWallpaperMotion.parallaxOffset(cursor: CGPoint(x: 1000, y: 250), size: size, amount: 1)
        XCTAssertEqual(right.dx, -LiveWallpaperMotion.maxParallaxShift, accuracy: 0.001)
        XCTAssertEqual(LiveWallpaperMotion.parallaxOffset(cursor: nil, size: size, amount: 1), .zero)

        let laptop = LiveWallpaperMotion.particleCount(style: .snow, size: CGSize(width: 1800, height: 1169), density: 1)
        let ultrawide = LiveWallpaperMotion.particleCount(style: .snow, size: CGSize(width: 5120, height: 1440), density: 1)
        XCTAssertGreaterThan(ultrawide, laptop)
        XCTAssertLessThanOrEqual(LiveWallpaperMotion.particleCount(style: .plexus, size: CGSize(width: 8000, height: 4000),
                                                                   density: 2), 160)
        XCTAssertEqual(LiveWallpaperMotion.particleCount(style: .none, size: size, density: 1), 0)
    }
}

final class LiveWallpaperPlexusTests: XCTestCase {
    func testLinkClockRefreshesThirtyTimesPerSecondAtThirtyAndSixtyFPS() {
        for fps in [30, 60] {
            var clock = LiveWallpaperLinkClock()
            var refreshes: [Double] = []
            for frame in 0..<fps * 10 {
                let time = Double(frame) / Double(fps)
                if clock.shouldRefresh(at: time) { refreshes.append(time) }
            }
            XCTAssertEqual(refreshes.count, 300)
            for (a, b) in zip(refreshes, refreshes.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a + 1e-9, 1.0 / 30)
            }
        }
    }

    func testClockResetsAfterPauseRebuildAndBackwardRendererTime() {
        var clock = LiveWallpaperLinkClock()
        XCTAssertTrue(clock.shouldRefresh(at: 50))
        XCTAssertFalse(clock.shouldRefresh(at: 50.01))
        clock.reset()
        XCTAssertTrue(clock.shouldRefresh(at: 50.01))
        XCTAssertTrue(clock.shouldRefresh(at: 2))
        XCTAssertFalse(clock.shouldRefresh(at: .nan))
        XCTAssertFalse(clock.shouldRefresh(at: .infinity))
        XCTAssertFalse(clock.shouldRefresh(at: 2.01))
        XCTAssertTrue(clock.shouldRefresh(at: 100), "A long pause produces one refresh, without catch-up work")
        XCTAssertFalse(clock.shouldRefresh(at: 100))
    }

    @MainActor
    func testSceneCadenceIsIndependentOfEnergyAndResetsOnResumeAndRebuild() throws {
        for fps in [30, 60] {
            for energy in [0.0, 1.0] {
                var settings = LiveWallpaperSceneSettings()
                settings.density = 2
                settings.cursorMode = .off
                settings.parallax = 0
                settings.framesPerSecond = fps
                let size = CGSize(width: 1000, height: 500)
                let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                                      content: .scene(.plexus), settings: settings)
                scene.setEnergy(energy)
                var previous: CGPath?
                var refreshes = 0
                for frame in 0..<fps * 3 {
                    scene.update(Double(frame) / Double(fps))
                    let path = try XCTUnwrap(scene.children.flatMap(\.children)
                        .compactMap { ($0 as? SKShapeNode)?.path }.first)
                    if path !== previous { refreshes += 1 }
                    previous = path
                }
                XCTAssertEqual(refreshes, 90, "fps=\(fps), energy=\(energy)")
                scene.resumeClock()
                let time = Double(fps * 3 - 1) / Double(fps)
                scene.update(time)
                let resumed = try XCTUnwrap(scene.children.flatMap(\.children)
                    .compactMap { ($0 as? SKShapeNode)?.path }.first)
                XCTAssertFalse(resumed === previous)
                settings.density = 1.9
                scene.update(settings: settings, screenFrame: CGRect(origin: .zero, size: size))
                scene.update(time)
                XCTAssertNotNil(scene.children.flatMap(\.children).compactMap { ($0 as? SKShapeNode)?.path }.first,
                                "Rebuilt shapes get links immediately, even at the previous refresh time")
            }
        }
    }

    func testGridMatchesOriginalNeighborsAndBandsIncludingNegativeCellsAndEdges() {
        var points = [CGPoint.zero]
        for distance in [-340.0, -170.001, -170, -169.999, -113.334, -113.333, -56.667, -56.666,
                         -0.001, 0.001, 56.666, 56.667, 113.333, 113.334, 169.999, 170, 170.001, 340] {
            points.append(CGPoint(x: distance, y: 0))
            points.append(CGPoint(x: -0.25, y: distance))
        }
        points.append(CGPoint(x: 0, y: -340))
        for boundary in [CGFloat(170) / 3, CGFloat(340) / 3] {
            for distance in [boundary.nextDown, boundary, boundary.nextUp] {
                points.append(CGPoint(x: distance, y: -340))
            }
        }
        var random: UInt64 = 17
        for _ in 0..<120 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let x = CGFloat(random % 5_400) - 140
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let y = CGFloat(random % 1_720) - 140
            points.append(CGPoint(x: x, y: y))
        }
        var grid = LiveWallpaperPlexusLinks()
        assertEquivalent(points, grid: &grid)
        // Reuse after moving to another display-sized geometry and after the particle count shrinks.
        assertEquivalent(points.map { CGPoint(x: $0.x * 0.3 - 170, y: $0.y * 0.5 - 170) }, grid: &grid)
        assertEquivalent(Array(points.prefix(9)), grid: &grid)
        assertEquivalent([], grid: &grid)
        assertEquivalent([.zero], grid: &grid)
        assertEquivalent(points, grid: &grid)
    }

    func testExtremeGridBoundsFallBackWithoutLosingNearbyPairs() {
        var grid = LiveWallpaperPlexusLinks()
        assertEquivalent([.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1_000_000_000, y: 0),
                          CGPoint(x: 1_000_000_001, y: 0)], grid: &grid)
    }

    @MainActor
    func testExternalLineRendererGetsSameGeometryAndDisablingRestoresNativePaths() throws {
        let scene = makeLineScene(size: CGSize(width: 100, height: 100))
        scene.update(0)
        let shapes = lineShapes(in: scene)
        XCTAssertEqual(shapes.count, 3)
        let nativeSegments = try segments(in: shapes)
        XCTAssertFalse(nativeSegments.isEmpty)
        var submissions: [([LiveWallpaperPlexusSegment], CGSize)] = []
        scene.setLineRenderer { submissions.append(($0, $1)) }
        let initial = try XCTUnwrap(submissions.last)
        XCTAssertEqual(initial.1, scene.size)
        XCTAssertEqual(initial.0.sorted(by: segmentOrder), nativeSegments.sorted(by: segmentOrder))
        XCTAssertTrue(initial.0.allSatisfy { (0...2).contains($0.bucket) })
        XCTAssertTrue(shapes.allSatisfy { $0.isHidden && $0.path == nil },
                      "External rendering must avoid duplicate SpriteKit strokes and their tessellation")
        scene.update(1.0 / 60)
        XCTAssertEqual(submissions.count, 2, "Installing the renderer resets the geometry clock")
        let latest = try XCTUnwrap(submissions.last?.0)
        scene.setLineRenderer(nil)
        XCTAssertTrue(shapes.allSatisfy { !$0.isHidden && $0.path != nil })
        XCTAssertEqual(try segments(in: shapes).sorted(by: segmentOrder), latest.sorted(by: segmentOrder))
        let count = submissions.count
        scene.update(1.0 / 30)
        XCTAssertEqual(submissions.count, count, "No callbacks survive removal of the external renderer")
    }

    @MainActor
    func testRebuildingWithoutPlexusClearsExternalLinesAndStopsSubmittingGeometry() throws {
        var settings = lineSettings()
        settings.imageParticles = .plexus
        let size = CGSize(width: 100, height: 100)
        let scene = LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                              content: .image(URL(fileURLWithPath: "/tmp/nool-test-missing-background.jpg")),
                                              settings: settings)
        var submissions: [[LiveWallpaperPlexusSegment]] = []
        scene.setLineRenderer { segments, _ in submissions.append(segments) }
        scene.update(0)
        XCTAssertFalse(try XCTUnwrap(submissions.last).isEmpty)
        settings.imageParticles = .snow
        scene.update(settings: settings, screenFrame: CGRect(origin: .zero, size: size))
        XCTAssertTrue(try XCTUnwrap(submissions.last).isEmpty)
        XCTAssertTrue(lineShapes(in: scene).isEmpty)
        let count = submissions.count
        scene.update(1)
        XCTAssertEqual(submissions.count, count, "A non-Plexus scene must leave the external layer cleared")
        settings.imageParticles = .plexus
        scene.update(settings: settings, screenFrame: CGRect(origin: .zero, size: size))
        scene.update(1)
        XCTAssertFalse(try XCTUnwrap(submissions.last).isEmpty)
        XCTAssertTrue(lineShapes(in: scene).allSatisfy { $0.isHidden && $0.path == nil })
    }

    @MainActor
    func testWallpaperSnapshotIncludesNativeLinesWhileExternalRendererIsActive() throws {
        let size = CGSize(width: 320, height: 220)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SKView(frame: CGRect(origin: .zero, size: size))
        view.isPaused = true
        view.ignoresSiblingOrder = true
        view.allowsTransparency = false
        window.contentView = view
        let scene = makeLineScene(size: size)
        view.presentScene(scene)
        defer { view.presentScene(nil) }
        scene.update(0)
        let reference = try XCTUnwrap(scene.snapshot(in: view))
        var submissions = 0
        scene.setLineRenderer { _, _ in submissions += 1 }
        let snapshot = try XCTUnwrap(scene.snapshot(in: view))
        XCTAssertEqual(snapshot.width, reference.width)
        XCTAssertEqual(snapshot.height, reference.height)
        let actualPixels = rgbaPixels(snapshot), expectedPixels = rgbaPixels(reference)
        let changedChannels = zip(actualPixels, expectedPixels).filter { $0 != $1 }.count
        XCTAssertEqual(changedChannels, 0,
                       "Static wallpaper export retains the original SpriteKit antialiasing and every line")
        XCTAssertEqual(submissions, 1, "Export does not submit duplicate geometry to the live renderer")
        XCTAssertTrue(lineShapes(in: scene).allSatisfy { $0.isHidden && $0.path == nil })
    }

    @MainActor
    func testFailedWallpaperSnapshotAlsoRestoresExternalRendererState() throws {
        let scene = makeLineScene(size: CGSize(width: 100, height: 100))
        scene.update(0)
        scene.setLineRenderer { _, _ in }
        let view = FailingWallpaperSnapshotView(frame: CGRect(origin: .zero, size: scene.size))
        var attempted = false
        view.onCapture = {
            attempted = true
            XCTAssertTrue(self.lineShapes(in: scene).allSatisfy { !$0.isHidden && $0.path != nil })
        }
        XCTAssertNil(scene.snapshot(in: view))
        XCTAssertTrue(attempted)
        XCTAssertTrue(lineShapes(in: scene).allSatisfy { $0.isHidden && $0.path == nil },
                      "A failed capture must not leave duplicate native lines in the live wallpaper")
    }

    private func lineSettings() -> LiveWallpaperSceneSettings {
        var settings = LiveWallpaperSceneSettings()
        settings.cursorMode = .off
        settings.parallax = 0
        settings.density = 2
        return settings
    }

    @MainActor
    private func makeLineScene(size: CGSize) -> LiveWallpaperParticleScene {
        LiveWallpaperParticleScene(size: size, screenFrame: CGRect(origin: .zero, size: size),
                                   content: .scene(.plexus), settings: lineSettings())
    }

    @MainActor
    private func lineShapes(in scene: SKScene) -> [SKShapeNode] {
        scene.children.flatMap(\.children).compactMap { $0 as? SKShapeNode }
    }

    @MainActor
    private func segments(in shapes: [SKShapeNode]) throws -> [LiveWallpaperPlexusSegment] {
        var segments: [LiveWallpaperPlexusSegment] = []
        for (bucket, shape) in shapes.enumerated() {
            let path = try XCTUnwrap(shape.path)
            var start = CGPoint.zero
            path.applyWithBlock { raw in
                let element = raw.pointee
                switch element.type {
                case .moveToPoint: start = element.points[0]
                case .addLineToPoint:
                    segments.append(LiveWallpaperPlexusSegment(start: start, end: element.points[0], bucket: bucket))
                    start = element.points[0]
                default: XCTFail("Plexus geometry contains only independent straight segments")
                }
            }
        }
        return segments
    }

    private func segmentOrder(_ a: LiveWallpaperPlexusSegment, _ b: LiveWallpaperPlexusSegment) -> Bool {
        let aKey = [CGFloat(a.bucket), a.start.x, a.start.y, a.end.x, a.end.y]
        let bKey = [CGFloat(b.bucket), b.start.x, b.start.y, b.end.x, b.end.y]
        return aKey.lexicographicallyPrecedes(bKey)
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private struct Link: Hashable {
        let first: Int
        let second: Int
        let bucket: Int
    }

    private func assertEquivalent(_ points: [CGPoint], grid: inout LiveWallpaperPlexusLinks,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var expected: [Link: Int] = [:]
        for first in points.indices {
            for second in (first + 1)..<points.count {
                let dx = points[first].x - points[second].x, dy = points[first].y - points[second].y
                let squared = dx * dx + dy * dy
                if squared < 170 * 170 {
                    let link = Link(first: points.firstIndex(of: points[first])!,
                                    second: points.firstIndex(of: points[second])!,
                                    bucket: min(2, Int(squared.squareRoot() / 170 * 3)))
                    expected[link, default: 0] += 1
                }
            }
        }
        grid.updatePoints(count: points.count) { points[$0] }
        var actual: [Link: Int] = [:]
        var visits = 0
        grid.forEachLink { a, b, bucket in
            visits += 1
            let link = Link(first: points.firstIndex(of: a)!, second: points.firstIndex(of: b)!, bucket: bucket)
            actual[link, default: 0] += 1
        }
        XCTAssertEqual(visits, expected.values.reduce(0, +), "Each pair is emitted only once", file: file, line: line)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

@MainActor
private final class FailingWallpaperSnapshotView: SKView {
    var onCapture: (() -> Void)?

    override func texture(from node: SKNode) -> SKTexture? {
        onCapture?()
        return nil
    }
}

final class LiveWallpaperLibraryTests: XCTestCase {
    func testItemsListOnlyVideosAndImportUsesUniqueNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LiveWallpaperLibrary(directory: root.appendingPathComponent("Wallpapers"))
        try library.ensureDirectory()
        for name in ["b.mov", "a.mp4", "notes.txt", ".x.partial", ".hidden.mp4", "c.png"] {
            try Data().write(to: library.directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: library.directory.appendingPathComponent("folder.mp4"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(library.items().map(\.fileName), ["a.mp4", "b.mov", "c.png"])
        XCTAssertEqual(library.items().last?.content, .image(library.directory.appendingPathComponent("c.png")))

        let source = root.appendingPathComponent("a.MP4")
        try Data([1, 2, 3]).write(to: source)
        let imported = try library.importFile(from: source)
        XCTAssertEqual(imported.fileName, "a 2.mp4")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(imported.url)), Data([1, 2, 3]))
        XCTAssertFalse(library.items().map(\.fileName).contains { $0.hasSuffix(".partial") })

        let text = root.appendingPathComponent("clip.txt")
        try Data().write(to: text)
        XCTAssertThrowsError(try library.importFile(from: text))
        XCTAssertNil(library.url(for: "../a.mp4"))
    }
}

@MainActor
final class LiveWallpaperControllerTests: XCTestCase {
    func testStartRendersSelectedVideoPausesOnPowerAndModulePauseRemovesWindows() async throws {
        let fixture = try Fixture(files: ["ocean.mp4"])
        defer { fixture.cleanUp() }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "ocean.mp4"
        fixture.controller.setPreferences(preferences)
        XCTAssertTrue(fixture.renderer.configurations.isEmpty, "Nothing renders before the module starts")

        fixture.controller.start()
        try await waitUntil { fixture.renderer.configurations.last??.isPlaying == true }
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "ocean.mp4")
        XCTAssertTrue(fixture.power.started)

        fixture.power.isOnBattery = true
        fixture.power.onChange?()
        XCTAssertEqual(fixture.renderer.configurations.last??.isPlaying, false)
        XCTAssertEqual(fixture.controller.playbackState, .paused(.power))

        fixture.renderer.onCoverageChange?(true)
        XCTAssertTrue(fixture.controller.environment.isCovered)

        fixture.controller.pause()
        XCTAssertNil(fixture.renderer.configurations.last ?? nil)
        XCTAssertFalse(fixture.power.started)
        let count = fixture.renderer.configurations.count
        fixture.power.onChange?()
        fixture.renderer.onCoverageChange?(false)
        XCTAssertEqual(fixture.renderer.configurations.count, count, "Late callbacks are ignored after pause")
        XCTAssertEqual(fixture.controller.preferences.selectedFileName, "ocean.mp4")
    }

    func testAssigningToDisplayOverridesOnlyThatDisplay() async throws {
        let fixture = try Fixture(files: ["ocean.mp4", "city.mov"])
        defer { fixture.cleanUp() }
        fixture.controller.start()
        try await waitUntil { fixture.controller.fileItems.count == 2 && !fixture.controller.displays.isEmpty }
        let display = try XCTUnwrap(fixture.controller.displays.first)
        let ocean = try XCTUnwrap(fixture.controller.item(named: "ocean.mp4"))
        let city = try XCTUnwrap(fixture.controller.item(named: "city.mov"))

        fixture.controller.assign(ocean, to: .allDisplays)
        fixture.controller.assign(city, to: .display(display.key))
        XCTAssertEqual(fixture.controller.preferences.selectedFileName, "ocean.mp4")
        XCTAssertEqual(fixture.controller.fileName(for: .display(display.key)), "city.mov")
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "city.mov")

        fixture.controller.resetDisplay(display.key)
        XCTAssertFalse(fixture.controller.hasOverride(display))
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content.fileName, "ocean.mp4")
    }

    func testBuiltInScenesAreAlwaysInLibraryAndCanBeAssigned() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        fixture.controller.start()
        try await waitUntil { !fixture.controller.displays.isEmpty }
        let fireflies = try XCTUnwrap(fixture.controller.item(named: "nool-scene-fireflies"))
        fixture.controller.select(fireflies)
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content, .scene(.fireflies))
        XCTAssertTrue(fixture.controller.usesScenes)
        fixture.controller.remove(fireflies)
        XCTAssertNotNil(fixture.controller.item(named: "nool-scene-fireflies"), "Built-in scenes cannot be removed")
    }

    func testOverlayFeedRunsOnlyWhilePlayingAndDrivesSceneEnergy() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        var quotaRequests = 0
        fixture.controller.onQuotaRefreshNeeded = { quotaRequests += 1 }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "nool-scene-plexus"
        fixture.controller.setPreferences(preferences)
        fixture.controller.start()
        try await waitUntil { fixture.renderer.configurations.last??.isPlaying == true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.sampler.sampleCount, 0, "No overlay, no hardware sampling")

        preferences.overlay.showsSystem = true
        preferences.overlay.showsQuotas = true
        preferences.overlay.scenesReactToLoad = true
        fixture.controller.setPreferences(preferences)
        try await waitUntil { fixture.renderer.overlayData.last?.system?.cpuFraction == 0.75 }
        XCTAssertEqual(fixture.renderer.energies.last, 0.75)
        XCTAssertEqual(quotaRequests, 1)
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.showsOverlay, true)

        let quota = QuotaWidgetProvider(snapshot: QuotaSnapshot(
            providerID: "claude", providerName: "Claude",
            windows: [QuotaWindow(id: "5h", label: "5h", limit: 100, remaining: 40, resetAt: nil, unit: .percentage)],
            connection: .live, updatedAt: Date(), sourceURL: nil, message: nil))
        fixture.controller.setQuotaProviders([quota])
        XCTAssertEqual(fixture.renderer.overlayData.last?.quotas.first?.percentage(for: .fiveHours), 40)

        fixture.power.isOnBattery = true
        fixture.power.onChange?()
        let samples = fixture.sampler.sampleCount
        XCTAssertEqual(fixture.renderer.energies.last, 0, "Paused wallpaper drops the load reaction")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.sampler.sampleCount, samples, "Sampling stops while paused")
    }

    func testReactorSamplesMetricsWithoutOptionalOverlayAndStopsWhenDeselected() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = LiveWallpaperScenePreset.reactor.key
        fixture.controller.setPreferences(preferences)
        fixture.controller.start()
        try await waitUntil { fixture.renderer.overlayData.last?.system?.cpuFraction == 0.75 }
        XCTAssertFalse(preferences.overlay.needsSystemMetrics)
        XCTAssertEqual(fixture.renderer.configurations.last??.screens.first?.content, .scene(.reactor))
        preferences.selectedFileName = LiveWallpaperScenePreset.plexus.key
        fixture.controller.setPreferences(preferences)
        let samples = fixture.sampler.sampleCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.sampler.sampleCount, samples)
        preferences.selectedFileName = LiveWallpaperScenePreset.reactor.key
        fixture.controller.setPreferences(preferences)
        try await waitUntil { fixture.sampler.sampleCount > samples }
        fixture.power.isOnBattery = true
        fixture.power.onChange?()
        let pausedSamples = fixture.sampler.sampleCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.sampler.sampleCount, pausedSamples)
    }

    func testMissingSelectedFileHidesWallpaper() async throws {
        let fixture = try Fixture(files: [])
        defer { fixture.cleanUp() }
        var preferences = LiveWallpaperPreferences()
        preferences.enabled = true
        preferences.selectedFileName = "gone.mp4"
        fixture.controller.setPreferences(preferences)
        fixture.controller.start()
        try await waitUntil { fixture.controller.message != nil }
        XCTAssertNil(fixture.renderer.configurations.last ?? nil)
        XCTAssertEqual(fixture.controller.playbackState, .hidden)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let renderer = FakeRenderer()
        let power = FakePower()
        let sampler = FakeSampler()
        let controller: LiveWallpaperController

        init(files: [String]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let library = LiveWallpaperLibrary(directory: root)
            try library.ensureDirectory()
            for name in files { try Data().write(to: root.appendingPathComponent(name)) }
            suiteName = "LiveWallpaperTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
            controller = LiveWallpaperController(defaults: defaults, library: library, renderer: renderer,
                                                 power: power, desktopImage: FakeDesktopImage(),
                                                 metricsSampler: sampler, screensProvider: { [screen] })
        }

        func cleanUp() {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class FakeRenderer: LiveWallpaperRendering {
        var onCoverageChange: ((Bool) -> Void)?
        var configurations: [LiveWallpaperRenderConfiguration?] = []
        var overlayData: [LiveWallpaperOverlayData] = []
        var energies: [Double] = []
        func apply(_ configuration: LiveWallpaperRenderConfiguration?) { configurations.append(configuration) }
        func updateOverlay(_ data: LiveWallpaperOverlayData) { overlayData.append(data) }
        func setSceneEnergy(_ value: Double) { energies.append(value) }
        func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage? { nil }
    }

    private final class FakeSampler: SystemMetricsSampling, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var sampleCount: Int { lock.withLock { count } }
        func sample() async -> SystemMetricsSnapshot {
            lock.withLock { count += 1 }
            return SystemMetricsSnapshot(sampledAt: Date(), cpuFraction: 0.75,
                                         memory: SystemResourceUsage(usedBytes: 4, totalBytes: 8), disk: nil, network: nil)
        }
        func reset() async {}
    }

    @MainActor
    private final class FakePower: LiveWallpaperPowerMonitoring {
        var onChange: (() -> Void)?
        var isOnBattery = false
        var isLowPowerMode = false
        var started = false
        func start() { started = true }
        func stop() { started = false }
    }

    @MainActor
    private struct FakeDesktopImage: LiveWallpaperDesktopImageSetting {
        func setDesktopImage(_ url: URL, for screen: NSScreen) throws {}
    }
}

private extension LiveWallpaperContent {
    var fileName: String? {
        switch self {
        case .video(let url), .image(let url), .wallpaperEngine(let url): url.lastPathComponent
        case .scene(let preset): preset.key
        }
    }
}
