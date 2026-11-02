import AppKit
import MetalKit
import SpriteKit
import XCTest
@testable import NotchApp

final class LiveWallpaperRendererLifecycleTests: XCTestCase {
    @MainActor
    func testReactorHUDPreviewAtDesktopAspectRatios() throws {
        try requireMetalDevice()
        _ = NSApplication.shared
        for size in [CGSize(width: 1600, height: 1000), CGSize(width: 2560, height: 720)] {
            let bounds = CGRect(origin: .zero, size: size)
            let view = try XCTUnwrap(LiveWallpaperReactorView.make(frame: bounds))
            let background = try XCTUnwrap(view.snapshot())
            let hud = LiveWallpaperReactorHUD(frame: bounds)
            for index in 0...60 {
                let wave = sin(Double(index) * 0.3)
                hud.update(SystemMetricsSnapshot(sampledAt: Date(timeIntervalSince1970: Double(index) * 2),
                    cpuFraction: 0.24 + wave * 0.12,
                    memory: .init(usedBytes: 18_000_000_000, totalBytes: 32_000_000_000),
                    disk: .init(usedBytes: 400_000_000_000, totalBytes: 1_000_000_000_000),
                    network: .init(receivedBytesPerSecond: 2_400_000 + wave * 700_000,
                                   sentBytesPerSecond: 156_000 + wave * 80_000)))
            }
            XCTAssertNil(hud.hitTest(.zero))
            let image = NSImage(size: size)
            image.lockFocusFlipped(true)
            NSImage(cgImage: background, size: size).draw(in: bounds)
            hud.draw(bounds)
            image.unlockFocus()
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["NOOL_REACTOR_PREVIEW_DIR"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("reactor-\(Int(size.width)).png"))
            }
        }
    }

    @MainActor
    func testReactorLifecycleKeepsSurfaceOnUpdatesAndReleasesOnDisconnect() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }
        fixture.renderer.apply(fixture.configuration(playing: true, content: .scene(.reactor)))
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.title == "NooL Live Wallpaper" && !fixture.previousWindows.contains($0.windowNumber)
        })
        let view = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? LiveWallpaperReactorView }.first)
        XCTAssertEqual(fixture.renderer.sceneBackend(forDisplay: fixture.displayID), .metal)
        XCTAssertEqual(view.isPaused, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertEqual(window.contentView?.subviews.filter { $0 is LiveWallpaperReactorHUD }.count, 1)
        fixture.renderer.apply(fixture.configuration(playing: false, content: .scene(.reactor)))
        XCTAssertTrue(view.isPaused)
        XCTAssertNotNil(fixture.renderer.sceneSnapshot(forDisplay: fixture.displayID))
        fixture.renderer.apply(fixture.configuration(playing: true, content: .scene(.reactor)))
        XCTAssertEqual(view.isPaused, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertTrue(view.superview === window.contentView)
        fixture.renderer.apply(nil)
        XCTAssertTrue(view.isPaused)
        XCTAssertNil(view.superview)
        fixture.renderer.apply(fixture.configuration(playing: true, content: .scene(.reactor)))
        XCTAssertEqual(fixture.renderer.sceneBackend(forDisplay: fixture.displayID), .metal)
    }

    @MainActor
    func testFailedWallpaperEngineSurfaceRevealsDesktopAndNextSelectionRecovers() throws {
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let project = root.appendingPathComponent("third_party/wallpaper-engine/fixture")
        let configuration = fixture.configuration(playing: true, content: .wallpaperEngine(project))
        fixture.renderer.apply(configuration)
        let view = try XCTUnwrap(fixture.renderer.wallpaperEngineView(forDisplay: fixture.displayID))
        let window = try XCTUnwrap(view.window)
        var error: String?
        fixture.renderer.onFailure = { error = $0 }
        let failure = try XCTUnwrap(view.onFailure)
        failure("Unsupported test scene")
        XCTAssertEqual(error, "Unsupported test scene")
        XCTAssertFalse(window.isVisible, "A failed scene must reveal the system wallpaper instead of a black surface")
        XCTAssertNil(fixture.renderer.wallpaperEngineView(forDisplay: fixture.displayID))
        fixture.renderer.apply(configuration)
        XCTAssertFalse(window.isVisible, "Unchanged state must not repeatedly retry a failed scene")
        fixture.renderer.apply(fixture.configuration(playing: true))
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(fixture.renderer.sceneBackend(forDisplay: fixture.displayID))
        failure("Stale callback")
        XCTAssertTrue(window.isVisible, "An old scene failure must not hide a replacement")
        XCTAssertEqual(error, "Unsupported test scene")
    }

    @MainActor
    func testMetalDrawableUsesNativePixelDensityOnEveryDisplay() throws {
        try requireMetalDevice()
        let scene = LiveWallpaperParticleScene(size: CGSize(width: 320, height: 180),
            screenFrame: CGRect(x: 0, y: 0, width: 320, height: 180),
            content: .scene(.plexus), settings: LiveWallpaperSceneSettings())
        let seed = try XCTUnwrap(scene.exportPlexusSeed())
        let view = try XCTUnwrap(LiveWallpaperMetalPlexusView.make(seed: seed))
        let window = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        defer { view.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        for screen in NSScreen.screens {
            window.setFrameOrigin(CGPoint(x: screen.frame.minX + 40, y: screen.frame.minY + 40))
            window.orderFrontRegardless()
            pump(for: 0.15)
            XCTAssertEqual(view.drawableSize.width, view.bounds.width * screen.backingScaleFactor, accuracy: 1)
            XCTAssertEqual(view.drawableSize.height, view.bounds.height * screen.backingScaleFactor, accuracy: 1)
        }
    }

    @MainActor
    func testFrameHealthRestartsAnUnpausedStalledLoopWithoutReplacingParticles() throws {
        let fixture = try Fixture(backend: .spriteKit)
        defer { fixture.renderer.apply(nil) }
        fixture.renderer.apply(fixture.configuration(playing: true))
        let view = try XCTUnwrap(fixture.sceneView)
        let scene = try XCTUnwrap(view.scene as? LiveWallpaperParticleScene)
        let window = try XCTUnwrap(view.window)
        window.level = .popUpMenu
        window.orderFrontRegardless()
        pump(for: 0.15)
        XCTAssertTrue(window.occlusionState.contains(.visible))
        XCTAssertGreaterThan(scene.completedUpdateCount, 0)

        // Fault injection: suppress actual native callbacks while both pause flags stay false.
        // This validates detection/recovery, not a reproduction of the historical OS incident.
        let gate = RenderGate()
        view.delegate = gate
        pump(for: 0.1)
        let stalledFrames = scene.completedUpdateCount
        let nodes = scene.children.flatMap(\.children).map(ObjectIdentifier.init)
        XCTAssertFalse(view.isPaused)
        XCTAssertFalse(scene.isPaused)
        let observation = view.observe(\.isPaused, options: [.old, .new]) { _, change in
            let didPause = change.oldValue == false && change.newValue == true
            MainActor.assumeIsolated {
                if didPause {
                    gate.recoveryPauses += 1
                    if gate.recoveryPauses == 2 { gate.blocked = false }
                }
            }
        }
        defer { observation.invalidate(); view.delegate = nil }
        fixture.renderer.checkFrameHealth(at: 0)
        fixture.renderer.checkFrameHealth(at: 1)
        XCTAssertEqual(gate.recoveryPauses, 0)
        XCTAssertEqual(scene.completedUpdateCount, stalledFrames)
        fixture.renderer.checkFrameHealth(at: 10) // A suspended main loop gets a fresh grace period.
        fixture.renderer.checkFrameHealth(at: 11)
        fixture.renderer.checkFrameHealth(at: 12)
        XCTAssertEqual(gate.recoveryPauses, 0)
        fixture.renderer.checkFrameHealth(at: 13.1, runLoopMode: .eventTracking)
        fixture.renderer.checkFrameHealth(at: 14, runLoopMode: .default)
        fixture.renderer.checkFrameHealth(at: 15, runLoopMode: .default)
        XCTAssertEqual(gate.recoveryPauses, 0, "Tracking mode must reset stall detection")
        fixture.renderer.checkFrameHealth(at: 16.1, runLoopMode: .default)
        XCTAssertEqual(gate.recoveryPauses, 1)
        XCTAssertTrue(view.scene === scene)
        XCTAssertEqual(scene.children.flatMap(\.children).map(ObjectIdentifier.init), nodes)
        for tick in 1...10 { fixture.renderer.checkFrameHealth(at: 16.1 + Double(tick), runLoopMode: .default) }
        XCTAssertEqual(gate.recoveryPauses, 2)
        XCTAssertTrue(view.scene === scene, "Fallback re-presents the existing scene")
        XCTAssertEqual(scene.children.flatMap(\.children).map(ObjectIdentifier.init), nodes)
        pump(for: 0.15)
        XCTAssertGreaterThan(scene.completedUpdateCount, stalledFrames)
        XCTAssertFalse(view.isPaused)
    }

    @MainActor
    func testFrameHealthDoesNotResumeHiddenOrExplicitlyPausedScenes() throws {
        let fixture = try Fixture(backend: .spriteKit)
        defer { fixture.renderer.apply(nil) }
        fixture.renderer.apply(fixture.configuration(playing: true))
        let view = try XCTUnwrap(fixture.sceneView)
        let window = try XCTUnwrap(view.window)
        window.level = .popUpMenu
        window.orderFrontRegardless()
        pump(for: 0.1)
        let gate = RenderGate()
        view.delegate = gate
        let observation = view.observe(\.isPaused) { view, _ in
            MainActor.assumeIsolated { if view.isPaused { gate.recoveryPauses += 1 } }
        }
        defer { observation.invalidate(); view.delegate = nil }
        fixture.renderer.checkFrameHealth(at: 0)
        view.isHidden = true
        for time in 1...5 { fixture.renderer.checkFrameHealth(at: Double(time)) }
        XCTAssertEqual(gate.recoveryPauses, 0)
        view.isHidden = false
        fixture.renderer.apply(fixture.configuration(playing: false))
        let pauses = gate.recoveryPauses
        for time in 6...12 { fixture.renderer.checkFrameHealth(at: Double(time)) }
        XCTAssertTrue(view.isPaused)
        XCTAssertEqual(gate.recoveryPauses, pauses)
    }

    @MainActor
    private final class RenderGate: NSObject, @preconcurrency SKViewDelegate {
        var blocked = true
        var recoveryPauses = 0
        func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool { !blocked }
    }

    @MainActor
    private func pump(for duration: TimeInterval) {
        let until = Date().addingTimeInterval(duration)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: min(until, Date().addingTimeInterval(0.01)),
                                          inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
        }
    }

    @MainActor
    @discardableResult
    private func pump(until timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any,
                                           until: min(deadline, Date().addingTimeInterval(0.01)),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
        }
        return condition()
    }

    @MainActor
    func testReentrantCoverageUpdateKeepsLatestPlayingConfigurationAndAnimation() async throws {
        let fixture = try Fixture(backend: .spriteKit)
        defer { fixture.renderer.apply(nil) }
        var reentered = false
        fixture.renderer.onCoverageChange = { _ in
            guard !reentered else { return }
            reentered = true
            fixture.renderer.apply(fixture.configuration(playing: true))
        }
        fixture.renderer.apply(fixture.configuration(playing: false))
        XCTAssertTrue(reentered, "The real renderer reports initial window coverage synchronously")
        let view = try XCTUnwrap(fixture.sceneView)
        XCTAssertFalse(view.isPaused, "The outer paused configuration must not overwrite the newer playing state")
        guard !view.isPaused, let scene = view.scene else { return }
        let particles = scene.children.flatMap(\.children).compactMap { $0 as? SKSpriteNode }
        let initial = particles.map(\.position)
        XCTAssertFalse(initial.isEmpty)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while particles.map(\.position) == initial, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(particles.map(\.position), initial, "The native display loop must actually resume")
    }

    @MainActor
    func testReentrantCoverageUpdateKeepsLatestPauseConfiguration() throws {
        let fixture = try Fixture(backend: .spriteKit)
        defer { fixture.renderer.apply(nil) }
        var reentered = false
        fixture.renderer.onCoverageChange = { _ in
            guard !reentered else { return }
            reentered = true
            fixture.renderer.apply(fixture.configuration(playing: false))
        }
        fixture.renderer.apply(fixture.configuration(playing: true))
        XCTAssertTrue(reentered)
        XCTAssertTrue(try XCTUnwrap(fixture.sceneView).isPaused,
                      "The outer playing configuration must not overwrite a newer pause")
    }

    @MainActor
    func testLatestReentrantNilConfigurationRemovesWindows() throws {
        let fixture = try Fixture(backend: .spriteKit)
        defer { fixture.renderer.apply(nil) }
        var reentered = false
        fixture.renderer.onCoverageChange = { _ in
            guard !reentered else { return }
            reentered = true
            fixture.renderer.apply(fixture.configuration(playing: false))
            fixture.renderer.apply(nil)
        }
        fixture.renderer.apply(fixture.configuration(playing: true))
        XCTAssertTrue(reentered)
        XCTAssertNil(fixture.sceneView, "A queued nil is a teardown request, not an empty queue")
    }

    @MainActor
    func testPlexusDefaultsToMetalAndPreservesSurfaceAcrossPauseNoopAndOriginUpdates() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }

        let playing = fixture.configuration(playing: true)
        fixture.renderer.apply(playing)
        let view = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        let simulation = try XCTUnwrap(fixture.renderer.metalSimulation(forDisplay: fixture.displayID))
        let window = try XCTUnwrap(view.window)
        window.level = .popUpMenu
        window.orderFrontRegardless()
        XCTAssertEqual(fixture.renderer.sceneBackend(forDisplay: fixture.displayID), .metal)

        pump(for: 0.25)
        XCTAssertGreaterThan(view.statistics.presented, 0, "The native Metal surface must draw in its AppKit window")
        XCTAssertNotNil(fixture.renderer.sceneSnapshot(forDisplay: fixture.displayID),
                        "The Metal surface must remain available to the wallpaper snapshot path")
        let initialFrame = simulation.frame

        let paused = fixture.configuration(playing: false)
        fixture.renderer.apply(paused)
        XCTAssertTrue(view.isPaused)
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === view)
        XCTAssertTrue(fixture.renderer.metalSimulation(forDisplay: fixture.displayID) === simulation)
        let pausedFrame = simulation.frame
        XCTAssertEqual(initialFrame.sprites.map(\.center), pausedFrame.sprites.map(\.center),
                       "Applying pause must not recreate or advance the simulation")

        pump(for: 0.15)
        XCTAssertEqual(simulation.frame.sprites.map(\.center), pausedFrame.sprites.map(\.center),
                       "An explicit pause must freeze simulation progress")

        // Applying the same configuration and moving the display in the global coordinate space
        // must not recreate the renderer or reseed particle positions.
        fixture.renderer.apply(paused)
        let moved = fixture.configuration(playing: false, frame: fixture.frame.offsetBy(dx: 80, dy: 35))
        fixture.renderer.apply(moved)
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === view)
        XCTAssertTrue(fixture.renderer.metalSimulation(forDisplay: fixture.displayID) === simulation)
        XCTAssertEqual(simulation.frame.sprites.map(\.center), pausedFrame.sprites.map(\.center))

        fixture.renderer.apply(playing)
        XCTAssertFalse(view.isPaused)
        let beforeResume = simulation.frame.sprites.map(\.center)
        pump(for: 0.25)
        XCTAssertNotEqual(simulation.frame.sprites.map(\.center), beforeResume,
                          "Resume must continue the existing Metal simulation")
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === view)
    }

    @MainActor
    func testMetalPausesForOccludedWindowAndResumesSameSurfaceWhenVisible() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }
        fixture.renderer.apply(fixture.configuration(playing: true, pausesHiddenScreens: true))
        let view = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        let simulation = try XCTUnwrap(fixture.renderer.metalSimulation(forDisplay: fixture.displayID))
        let window = try XCTUnwrap(view.window)
        window.level = .popUpMenu
        window.orderFrontRegardless()
        XCTAssertTrue(pump(until: 1) { view.statistics.presented > 0 })

        window.orderOut(nil)
        XCTAssertTrue(pump(until: 1) { view.isPaused }, "An occluded wallpaper window should pause Metal")
        let pausedFrame = simulation.frame
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === view)
        XCTAssertTrue(fixture.renderer.metalSimulation(forDisplay: fixture.displayID) === simulation)

        window.orderFrontRegardless()
        XCTAssertTrue(pump(until: 1) {
            !view.isPaused && simulation.frame.sprites.map(\.center) != pausedFrame.sprites.map(\.center)
        }, "Making the display visible should resume the existing Metal simulation")
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === view)
    }

    @MainActor
    func testMetalRebuildsForSizeAndSimulationSettingsButKeepsViewForFrameRateChange() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }
        fixture.renderer.apply(fixture.configuration(playing: true))
        let initial = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))

        var faster = fixture.settings
        faster.framesPerSecond = 30
        fixture.renderer.apply(fixture.configuration(playing: true, settings: faster))
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === initial,
                      "Changing the display cadence should update the current MTKView")
        XCTAssertEqual(initial.preferredFramesPerSecond, 30)

        let resized = fixture.configuration(playing: true,
                                            frame: CGRect(origin: fixture.frame.origin,
                                                          size: CGSize(width: fixture.frame.width + 24,
                                                                       height: fixture.frame.height + 16)),
                                            settings: faster)
        fixture.renderer.apply(resized)
        let afterResize = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        XCTAssertFalse(afterResize === initial, "A drawable-size change must rebuild size-dependent Metal resources")
        XCTAssertTrue(initial.isPaused)
        XCTAssertNil(initial.frameProvider)

        var denser = faster
        denser.density = 1.5
        fixture.renderer.apply(fixture.configuration(playing: true, frame: resized.screens[0].frame,
                                                     settings: denser))
        let afterDensity = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        XCTAssertFalse(afterDensity === afterResize, "A particle-density change must regenerate the Metal seed")
        XCTAssertTrue(afterResize.isPaused)
        XCTAssertNil(afterResize.frameProvider)
    }

    @MainActor
    func testRemovedDisplayStopsMetalCallbacksAndReaddCreatesLiveSurface() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }
        let configuration = fixture.configuration(playing: true)
        fixture.renderer.apply(configuration)
        let removed = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        let staleFailureCallback = removed.onFailure
        XCTAssertNotNil(removed.frameProvider)

        fixture.renderer.apply(fixture.configuration(playing: true, screens: []))
        XCTAssertNil(fixture.renderer.metalView(forDisplay: fixture.displayID))
        XCTAssertTrue(removed.isPaused)
        XCTAssertNil(removed.frameProvider)
        XCTAssertNil(removed.onFailure)

        fixture.renderer.apply(configuration)
        let readded = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        XCTAssertFalse(readded === removed)
        XCTAssertFalse(readded.isPaused)
        XCTAssertNotNil(readded.frameProvider)
        staleFailureCallback?()
        let window = try XCTUnwrap(readded.window)
        window.level = .popUpMenu
        window.orderFrontRegardless()
        pump(for: 0.25)
        XCTAssertTrue(fixture.renderer.metalView(forDisplay: fixture.displayID) === readded,
                      "A late callback from a removed display surface must not replace its reconnected surface")
        XCTAssertGreaterThan(readded.statistics.presented, 0)
    }

    @MainActor
    func testNonPlexusScenesAndImagesUseSpriteKitAndMetalFailureFallsBack() throws {
        try requireMetalDevice()
        let fixture = try Fixture()
        defer { fixture.renderer.apply(nil) }

        for content in [LiveWallpaperContent.scene(.snow),
                        .image(URL(fileURLWithPath: "/tmp/nool-lifecycle-image.png"))] {
            fixture.renderer.apply(fixture.configuration(playing: true, content: content))
            XCTAssertEqual(fixture.renderer.sceneBackend(forDisplay: fixture.displayID), .spriteKit)
            XCTAssertNil(fixture.renderer.metalView(forDisplay: fixture.displayID))
            XCTAssertNotNil(fixture.sceneView)
        }

        fixture.renderer.apply(fixture.configuration(playing: true))
        let metal = try XCTUnwrap(fixture.renderer.metalView(forDisplay: fixture.displayID))
        metal.onFailure?()
        pump(for: 0.1)
        XCTAssertEqual(fixture.renderer.sceneBackend(forDisplay: fixture.displayID), .spriteKit,
                       "A failed Metal callback must replace only that surface with SpriteKit")
        XCTAssertTrue(metal.isPaused)
        XCTAssertNil(metal.frameProvider)
        XCTAssertNil(metal.onFailure)

        let forcedSpriteKit = try Fixture(backend: .spriteKit)
        defer { forcedSpriteKit.renderer.apply(nil) }
        forcedSpriteKit.renderer.apply(forcedSpriteKit.configuration(playing: true))
        XCTAssertEqual(forcedSpriteKit.renderer.sceneBackend(forDisplay: forcedSpriteKit.displayID), .spriteKit)
        XCTAssertNil(forcedSpriteKit.renderer.metalView(forDisplay: forcedSpriteKit.displayID))
    }

    @MainActor
    private func requireMetalDevice(file: StaticString = #filePath, line: UInt = #line) throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this Mac") }
    }

    @MainActor
    private struct Fixture {
        let renderer: DesktopLiveWallpaperRenderer
        let displayID: CGDirectDisplayID
        let screen: LiveWallpaperScreen
        let frame: CGRect
        let settings: LiveWallpaperSceneSettings
        let previousWindows: Set<Int>

        init(backend: DesktopLiveWallpaperRenderer.SceneBackend = .automatic) throws {
            _ = NSApplication.shared
            guard let display = NSScreen.screens.first,
                  let number = display.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw XCTSkip("A window-server display is unavailable")
            }
            renderer = DesktopLiveWallpaperRenderer(backend: backend)
            displayID = number.uint32Value
            previousWindows = Set(NSApp.windows.map(\.windowNumber))
            frame = CGRect(x: display.frame.minX + 20, y: display.frame.minY + 20,
                           width: 420, height: 280)
            var sceneSettings = LiveWallpaperSceneSettings()
            sceneSettings.density = 0.4
            sceneSettings.framesPerSecond = 60
            settings = sceneSettings
            screen = LiveWallpaperScreen(displayID: number.uint32Value, frame: frame, content: .scene(.plexus))
        }

        func configuration(playing: Bool, content: LiveWallpaperContent = .scene(.plexus),
                           frame: CGRect? = nil, settings: LiveWallpaperSceneSettings? = nil,
                           screens: [LiveWallpaperScreen]? = nil,
                           pausesHiddenScreens: Bool = false) -> LiveWallpaperRenderConfiguration {
            let targetScreen = LiveWallpaperScreen(displayID: displayID, frame: frame ?? self.frame, content: content)
            return LiveWallpaperRenderConfiguration(screens: screens ?? [targetScreen], scaleMode: .fill, volume: 0,
                                                    playbackRate: 1, isPlaying: playing,
                                                    pausesHiddenScreens: pausesHiddenScreens,
                                                    scene: settings ?? self.settings)
        }

        var sceneView: SKView? {
            NSApp.windows.filter { !previousWindows.contains($0.windowNumber) && $0.isVisible }
                .flatMap { $0.contentView?.subviews ?? [] }.compactMap { $0 as? SKView }.first
        }
    }
}
