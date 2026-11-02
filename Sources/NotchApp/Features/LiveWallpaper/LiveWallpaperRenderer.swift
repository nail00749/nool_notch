import AppKit
import AVFoundation
import IOKit.ps
import SpriteKit
import SwiftUI
import OSLog

@MainActor
protocol LiveWallpaperRendering: AnyObject {
    /// True when no wallpaper window has a visible pixel, for example behind a full-screen app.
    var onCoverageChange: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var onSceneReady: (() -> Void)? { get set }
    /// `nil` removes the windows and releases the player.
    func apply(_ configuration: LiveWallpaperRenderConfiguration?)
    /// The current frame of a scene surface, used as the system and lock screen wallpaper.
    func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage?
    /// New limits and hardware readings for the overlay; cheap, no windows are rebuilt.
    func updateOverlay(_ data: LiveWallpaperOverlayData)
    /// Hardware load in 0...1 that scenes react to; 0 turns the reaction off.
    func setSceneEnergy(_ value: Double)
}

extension LiveWallpaperRendering {
    var onFailure: ((String) -> Void)? { get { nil } set {} }
    var onSceneReady: (() -> Void)? { get { nil } set {} }
}

/// Click-through windows at the desktop level, below Finder icons. Screens showing the same video share
/// one looping player, so they stay in sync and the clip is decoded once. Plexus uses a complete
/// Metal surface; other scenes and unsupported GPUs retain SpriteKit. Each runs only while allowed.
@MainActor
final class DesktopLiveWallpaperRenderer: LiveWallpaperRendering {
    var onCoverageChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSceneReady: (() -> Void)?

    enum SceneBackend { case automatic, metal, spriteKit }
    private let backend: SceneBackend

    init(backend: SceneBackend = .automatic) {
        self.backend = backend == .automatic
            && ProcessInfo.processInfo.environment["NOOL_PLEXUS_RENDERER"] == "spritekit" ? .spriteKit : backend
    }

    private struct Playback {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
    }

    private enum Surface {
        case video(NSView, AVPlayerLayer)
        case scene(SKView, any LiveWallpaperSpriteScene)
        case metal(PlexusSurface)
        case reactor(LiveWallpaperReactorView, LiveWallpaperReactorHUD)
        case wallpaperEngine(WallpaperEngineWebView)
    }

    @MainActor
    private final class PlexusSurface {
        let view: LiveWallpaperMetalPlexusView
        let simulation: LiveWallpaperPlexusSimulation
        var screenFrame: CGRect
        var settings: LiveWallpaperSceneSettings
        init(view: LiveWallpaperMetalPlexusView, seed: LiveWallpaperPlexusSeed, screenFrame: CGRect) {
            self.view = view
            simulation = LiveWallpaperPlexusSimulation(seed: seed)
            self.screenFrame = screenFrame
            settings = seed.settings
        }
        func frame(at time: TimeInterval) -> LiveWallpaperPlexusFrame {
            let location = NSEvent.mouseLocation
            let cursor = screenFrame.contains(location)
                ? CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY) : nil
            return simulation.advance(at: time, cursor: cursor)
        }
    }

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var overlayViews: [CGDirectDisplayID: NSView] = [:]
    private let overlayModel = LiveWallpaperOverlayModel()
    private var sceneEnergy = 0.0
    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var lineViews: [CGDirectDisplayID: LiveWallpaperMetalLineView] = [:]
    private var failedMetalDisplays = Set<CGDirectDisplayID>()
    private var windowContents: [CGDirectDisplayID: LiveWallpaperContent] = [:]
    private var occlusionObservers: [CGDirectDisplayID: NSObjectProtocol] = [:]
    private var playbacks: [URL: Playback] = [:]
    private var lastCoverage: Bool?
    private var lastConfiguration: LiveWallpaperRenderConfiguration?
    private struct PendingConfiguration {
        let value: LiveWallpaperRenderConfiguration?
    }
    private var pendingConfiguration: PendingConfiguration?
    private var isApplying = false
    private var frameHealth: [CGDirectDisplayID: LiveWallpaperFrameHealth] = [:]
    private var frameMonitor: Timer?
    private var lastFrameHealthCheck: TimeInterval?
    private static let frameLogger = Logger(subsystem: "com.nailuyltyev.NotchApp", category: "WallpaperFrames")

    static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    func apply(_ configuration: LiveWallpaperRenderConfiguration?) {
        // Creating/updating windows can report coverage synchronously. The controller may then
        // submit a newer configuration before this apply has finished. Complete the current
        // mutation first, then apply only the latest queued state, including explicit teardown.
        pendingConfiguration = PendingConfiguration(value: configuration)
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        while let pending = pendingConfiguration {
            pendingConfiguration = nil
            applyConfiguration(pending.value)
        }
    }

    private func applyConfiguration(_ configuration: LiveWallpaperRenderConfiguration?) {
        guard let configuration, !configuration.screens.isEmpty else {
            teardown()
            return
        }
        let videoURLs = configuration.screens.compactMap { screen -> URL? in
            if case .video(let url) = screen.content { url } else { nil }
        }
        for url in playbacks.keys where !videoURLs.contains(url) { releasePlayback(url) }
        for url in videoURLs where playbacks[url] == nil { playbacks[url] = Self.makePlayback(url) }
        if overlayModel.settings != configuration.overlay { overlayModel.settings = configuration.overlay }
        synchronizeWindows(configuration)
        lastConfiguration = configuration

        let gravity = Self.gravity(for: configuration.scaleMode)
        for surface in surfaces.values {
            switch surface {
            case .video(_, let layer):
                if layer.videoGravity != gravity { layer.videoGravity = gravity }
            case .scene(let view, _):
                view.preferredFramesPerSecond = configuration.scene.framesPerSecond
            case .metal(let surface):
                surface.view.preferredFramesPerSecond = configuration.scene.framesPerSecond
            case .reactor(let view, _):
                view.preferredFramesPerSecond = configuration.scene.framesPerSecond
            case .wallpaperEngine: break // Configured with the per-display visibility in applyPlayback.
            }
        }
        // Only the first display's video is audible, so several clips never play sound at once.
        let audibleURL = configuration.volume > 0 ? videoURLs.first : nil
        for (url, playback) in playbacks {
            let player = playback.player
            player.volume = configuration.volume
            player.isMuted = url != audibleURL
            player.defaultRate = configuration.playbackRate
        }
        applyPlayback()
    }

    /// Runs each surface only while playback is allowed and, if asked, while its window is visible.
    /// A shared video keeps playing while any of its displays can be seen.
    private func applyPlayback() {
        guard let configuration = lastConfiguration else { return }
        func runs(_ displayID: CGDirectDisplayID) -> Bool {
            guard configuration.isPlaying else { return false }
            guard configuration.pausesHiddenScreens, let window = windows[displayID] else { return true }
            return window.occlusionState.contains(.visible)
        }
        var playingURLs = Set<URL>()
        for (displayID, surface) in surfaces {
            switch surface {
            case .reactor(let view, _):
                view.setPlaying(runs(displayID))
            case .wallpaperEngine(let view):
                guard let screen = configuration.screens.first(where: { $0.displayID == displayID }) else { continue }
                view.apply(playing: runs(displayID), framesPerSecond: configuration.scene.framesPerSecond,
                           volume: 0, playbackRate: Double(configuration.playbackRate),
                           scaleMode: configuration.scaleMode, screenFrame: screen.frame)
            case .video:
                if runs(displayID), case .video(let url) = windowContents[displayID] { playingURLs.insert(url) }
            case .scene(let view, let scene):
                let shouldRun = runs(displayID)
                if view.isPaused == shouldRun {
                    if shouldRun { scene.resumeClock() }
                    view.isPaused = !shouldRun
                }
            case .metal(let surface):
                if runs(displayID) {
                    if surface.view.isPaused {
                        surface.simulation.resumeClock()
                        let pausedFrame = surface.simulation.frame
                        Self.frameLogger.info("Metal wallpaper resumed: display=\(displayID, privacy: .public)")
                        surface.view.start { [weak surface] time in
                            // The live surface owns the view; this closure must not retain it.
                            surface?.frame(at: time) ?? pausedFrame
                        }
                    }
                } else if !surface.view.isPaused {
                    surface.view.stop()
                    Self.frameLogger.info("Metal wallpaper paused: display=\(displayID, privacy: .public)")
                }
            }
        }
        for (url, playback) in playbacks {
            let player = playback.player
            if playingURLs.contains(url) {
                if player.rate != configuration.playbackRate { player.rate = configuration.playbackRate }
            } else if player.rate != 0 {
                player.pause()
            }
        }
        reconcileFrameMonitor()
    }

    private func canMonitorFrames(displayID: CGDirectDisplayID, view: SKView,
                                  scene: any LiveWallpaperSpriteScene) -> Bool {
        guard lastConfiguration?.isPlaying == true, let window = windows[displayID] else { return false }
        // SpriteKit may legitimately stop callbacks for hidden/detached views even with paused=false.
        return window.isVisible && window.occlusionState.contains(.visible) && !NSApp.isHidden
            && view.window === window && scene.view === view && view.canDraw
            && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
            && !view.isPaused && !scene.isPaused
    }

    private func reconcileFrameMonitor() {
        let eligible = Set(surfaces.compactMap { displayID, surface -> CGDirectDisplayID? in
            guard case .scene(let view, let scene) = surface,
                  canMonitorFrames(displayID: displayID, view: view, scene: scene) else { return nil }
            return displayID
        })
        frameHealth = frameHealth.filter { eligible.contains($0.key) }
        guard !eligible.isEmpty else {
            frameMonitor?.invalidate()
            frameMonitor = nil
            lastFrameHealthCheck = nil
            return
        }
        guard frameMonitor == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                self.checkFrameHealth(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        timer.tolerance = 0.2
        frameMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// A low-frequency health check, not an animation clock. It never advances the scene itself.
    func checkFrameHealth(at now: TimeInterval, runLoopMode: RunLoop.Mode? = nil) {
        let mode = runLoopMode ?? RunLoop.main.currentMode
        let interrupted = lastFrameHealthCheck.map { now - $0 > 3 || now < $0 } ?? false
        lastFrameHealthCheck = now
        // Tracking/modal loops, debugger suspension and long main-thread stalls need a fresh grace
        // period; lack of callbacks during those intervals is not evidence of a broken display link.
        if interrupted || (mode != nil && mode != .default) {
            frameHealth.removeAll(keepingCapacity: true)
            return
        }
        for (displayID, surface) in surfaces {
            guard case .scene(let view, let scene) = surface,
                  canMonitorFrames(displayID: displayID, view: view, scene: scene) else {
                frameHealth.removeValue(forKey: displayID)
                continue
            }
            var health = frameHealth[displayID] ?? LiveWallpaperFrameHealth()
            let recover = health.observe(frameCount: scene.completedUpdateCount, now: now)
            frameHealth[displayID] = health
            guard recover else { continue }
            let attempt = health.recoveryAttempts
            let updates = scene.completedUpdateCount
            let occlusion = windows[displayID]?.occlusionState.rawValue ?? 0
            Self.frameLogger.error("Stalled visible SpriteKit scene: display=\(displayID, privacy: .public) updates=\(updates, privacy: .public) viewPaused=false scenePaused=false occlusion=\(occlusion, privacy: .public) recovery=\(attempt, privacy: .public)")
            view.isPaused = true
            if attempt > 1 {
                // A second attempt replaces the presentation binding, retaining the actual scene
                // and every particle. No random rebuild or visible position reset is involved.
                view.presentScene(nil)
                view.presentScene(scene)
            }
            scene.resumeClock()
            view.isPaused = false
        }
        reconcileFrameMonitor()
    }

    func updateOverlay(_ data: LiveWallpaperOverlayData) {
        if overlayModel.data != data { overlayModel.data = data }
        for surface in surfaces.values {
            if case .reactor(_, let hud) = surface { hud.update(data.system) }
        }
    }

    func setSceneEnergy(_ value: Double) {
        sceneEnergy = value
        for surface in surfaces.values {
            switch surface {
            case .scene(_, let scene): scene.setEnergy(value)
            case .metal(let surface): surface.simulation.setEnergy(value)
            case .reactor(let view, _): view.energy = value
            case .video, .wallpaperEngine: break
            }
        }
    }

    func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage? {
        switch surfaces[displayID] {
        case .reactor(let view, _): return view.snapshot()
        case .scene(let view, let scene): return scene.snapshot(in: view)
        case .metal(let surface):
            let scale = windows[displayID]?.backingScaleFactor ?? 1
            return try? surface.view.snapshot(frame: surface.simulation.frame, scale: scale)
        case .wallpaperEngine(let view): return view.cachedSnapshot
        default: return nil
        }
    }

    // Internal lifecycle diagnostics, also used by native renderer regression tests.
    func sceneBackend(forDisplay displayID: CGDirectDisplayID) -> SceneBackend? {
        switch surfaces[displayID] {
        case .metal, .reactor: .metal
        case .scene: .spriteKit
        default: nil
        }
    }

    func metalView(forDisplay displayID: CGDirectDisplayID) -> LiveWallpaperMetalPlexusView? {
        guard case .metal(let surface) = surfaces[displayID] else { return nil }
        return surface.view
    }

    func wallpaperEngineView(forDisplay displayID: CGDirectDisplayID) -> WallpaperEngineWebView? {
        guard case .wallpaperEngine(let view) = surfaces[displayID] else { return nil }
        return view
    }

    func metalSimulation(forDisplay displayID: CGDirectDisplayID) -> LiveWallpaperPlexusSimulation? {
        guard case .metal(let surface) = surfaces[displayID] else { return nil }
        return surface.simulation
    }

    private static func makePlayback(_ url: URL) -> Playback {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVQueuePlayer()
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .advance
        return Playback(player: player, looper: AVPlayerLooper(player: player, templateItem: item))
    }

    private func releasePlayback(_ url: URL) {
        guard let playback = playbacks.removeValue(forKey: url) else { return }
        playback.player.pause()
        playback.looper.disableLooping()
        playback.player.removeAllItems()
    }

    private func synchronizeWindows(_ configuration: LiveWallpaperRenderConfiguration) {
        let wanted = Set(configuration.screens.map(\.displayID))
        for displayID in windows.keys where !wanted.contains(displayID) { removeWindow(displayID) }
        for screen in configuration.screens {
            let window = windows[screen.displayID] ?? makeWindow(screen)
            if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            if windowContents[screen.displayID] != screen.content {
                windowContents[screen.displayID] = screen.content
                installSurface(screen, in: window, settings: configuration.scene)
            } else if case .scene(_, let scene) = surfaces[screen.displayID] {
                scene.update(settings: configuration.scene, screenFrame: screen.frame)
            } else if case .reactor(let view, _) = surfaces[screen.displayID] {
                view.screenFrame = screen.frame
                view.settings = configuration.scene
            } else if case .metal(let surface) = surfaces[screen.displayID] {
                let next = configuration.scene
                if surface.screenFrame.size != screen.frame.size || surface.settings.density != next.density
                    || surface.settings.imageParticles != next.imageParticles || surface.settings.parallax != next.parallax {
                    installSurface(screen, in: window, settings: next)
                } else {
                    surface.screenFrame = screen.frame
                    surface.settings = next
                    surface.simulation.update(settings: next)
                }
            }
            synchronizeOverlay(screen, in: window)
        }
        reportCoverage()
    }

    private func makeWindow(_ screen: LiveWallpaperScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "NooL Live Wallpaper"
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.setFrame(screen.frame, display: false)
        // Surface below, optional overlay above; both resize with the window.
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizesSubviews = true
        window.contentView = container
        window.orderFrontRegardless()
        windows[screen.displayID] = window
        occlusionObservers[screen.displayID] = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPlayback()
                self?.reportCoverage()
            }
        }
        return window
    }

    private func installSurface(_ screen: LiveWallpaperScreen, in window: NSWindow, settings: LiveWallpaperSceneSettings) {
        releaseSurface(screen.displayID)
        window.orderFrontRegardless()
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        switch screen.content {
        case .wallpaperEngine(let projectURL):
            guard let view = WallpaperEngineWebView(projectURL: projectURL) else {
                window.orderOut(nil)
                onFailure?("Не удалось открыть сцену Wallpaper Engine.")
                return
            }
            insertSurfaceView(view, in: window)
            surfaces[screen.displayID] = .wallpaperEngine(view)
            view.onFailure = { [weak self, weak view] error in
                guard let self, let view,
                      case .wallpaperEngine(let current) = self.surfaces[screen.displayID], current === view else { return }
                self.releaseSurface(screen.displayID)
                self.windows[screen.displayID]?.orderOut(nil)
                self.onFailure?(error)
            }
            view.onReady = { [weak self, weak view] in
                guard let self, let view,
                      case .wallpaperEngine(let current) = self.surfaces[screen.displayID], current === view else { return }
                self.onSceneReady?()
            }
        case .video(let url):
            let view = NSView(frame: bounds)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            let layer = AVPlayerLayer(player: playbacks[url]?.player)
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.backgroundColor = NSColor.black.cgColor
            view.layer?.addSublayer(layer)
            insertSurfaceView(view, in: window)
            surfaces[screen.displayID] = .video(view, layer)
        case .image, .scene:
            if screen.content == .scene(.reactor) {
                guard let view = LiveWallpaperReactorView.make(frame: bounds) else {
                    window.orderOut(nil)
                    onFailure?("Не удалось запустить Metal-реактор на этом дисплее.")
                    return
                }
                view.screenFrame = screen.frame
                view.settings = settings
                view.energy = sceneEnergy
                view.preferredFramesPerSecond = settings.framesPerSecond
                insertSurfaceView(view, in: window)
                let hud = LiveWallpaperReactorHUD(frame: bounds)
                hud.autoresizingMask = [.width, .height]
                hud.update(overlayModel.data.system)
                window.contentView?.addSubview(hud, positioned: .above, relativeTo: view)
                surfaces[screen.displayID] = .reactor(view, hud)
                view.onFailure = { [weak self, weak view] in
                    DispatchQueue.main.async { [weak self, weak view] in
                        guard let self, let view,
                              case .reactor(let current, _) = self.surfaces[screen.displayID], current === view else { return }
                        self.releaseSurface(screen.displayID)
                        self.windows[screen.displayID]?.orderOut(nil)
                        self.onFailure?("Не удалось отрисовать реактор. Выберите другие обои, затем вернитесь к реактору.")
                    }
                }
                return
            }
            if screen.content == .scene(.plexus), backend != .spriteKit,
               !failedMetalDisplays.contains(screen.displayID) {
                // Use the same geometry/texture generator once, then release every SpriteKit node.
                let seedScene = LiveWallpaperParticleScene(size: bounds.size, screenFrame: screen.frame,
                                                          content: screen.content, settings: settings)
                if let seed = seedScene.exportPlexusSeed(), let view = LiveWallpaperMetalPlexusView.make(seed: seed) {
                    let surface = PlexusSurface(view: view, seed: seed, screenFrame: screen.frame)
                    surface.simulation.setEnergy(sceneEnergy)
                    view.preferredFramesPerSecond = settings.framesPerSecond
                    insertSurfaceView(view, in: window)
                    surfaces[screen.displayID] = .metal(surface)
                    Self.frameLogger.info("Wallpaper surface installed: backend=metal display=\(screen.displayID, privacy: .public) width=\(bounds.width, privacy: .public) height=\(bounds.height, privacy: .public)")
                    view.onFailure = { [weak self, weak view] in
                        // Failed GPU callbacks may arrive after hotplug or a newer surface was installed.
                        // Queue replacement outside the current apply/draw traversal and check identity.
                        DispatchQueue.main.async { [weak self, weak view] in
                            guard let self, let view, self.metalView(forDisplay: screen.displayID) === view,
                                  let window = self.windows[screen.displayID],
                                  let configuration = self.lastConfiguration,
                                  let current = configuration.screens.first(where: { $0.displayID == screen.displayID }) else { return }
                            self.failedMetalDisplays.insert(screen.displayID)
                            Self.frameLogger.error("Metal wallpaper failed; using SpriteKit: display=\(screen.displayID, privacy: .public)")
                            self.installSurface(current, in: window, settings: configuration.scene)
                            self.applyPlayback()
                        }
                    }
                    view.update(frame: surface.simulation.frame)
                    return
                }
            }
            let view = SKView(frame: bounds)
            view.ignoresSiblingOrder = true
            view.allowsTransparency = false
            view.preferredFramesPerSecond = settings.framesPerSecond
            view.isPaused = true
            if screen.content == .scene(.cogitator) {
                let scene = LiveWallpaperCogitatorScene(size: bounds.size, screenFrame: screen.frame, settings: settings)
                scene.setEnergy(sceneEnergy)
                view.presentScene(scene)
                insertSurfaceView(view, in: window)
                surfaces[screen.displayID] = .scene(view, scene)
                return
            }
            let scene = LiveWallpaperParticleScene(size: bounds.size, screenFrame: screen.frame,
                                                   content: screen.content, settings: settings)
            scene.setEnergy(sceneEnergy)
            view.presentScene(scene)
            insertSurfaceView(view, in: window)
            surfaces[screen.displayID] = .scene(view, scene)
            Self.frameLogger.info("Wallpaper surface installed: backend=spritekit display=\(screen.displayID, privacy: .public) width=\(bounds.width, privacy: .public) height=\(bounds.height, privacy: .public)")
            if let lines = LiveWallpaperMetalLineView.make(frame: bounds),
               let container = window.contentView {
                lines.autoresizingMask = [.width, .height]
                container.addSubview(lines, positioned: .above, relativeTo: view)
                lineViews[screen.displayID] = lines
                lines.onFailure = { [weak scene, weak lines] in
                    lines?.isHidden = true
                    scene?.setLineRenderer(nil)
                }
                scene.setLineRenderer { [weak lines] segments, size in
                    lines?.update(segments: segments, logicalSize: size)
                }
            }
        }
    }

    private func insertSurfaceView(_ view: NSView, in window: NSWindow) {
        guard let container = window.contentView else { return }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .below, relativeTo: nil)
    }

    private func synchronizeOverlay(_ screen: LiveWallpaperScreen, in window: NSWindow) {
        if screen.showsOverlay, overlayViews[screen.displayID] == nil, let container = window.contentView {
            let view = NSHostingView(rootView: LiveWallpaperOverlayView(model: overlayModel))
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view, positioned: .above, relativeTo: nil)
            overlayViews[screen.displayID] = view
        } else if !screen.showsOverlay {
            overlayViews.removeValue(forKey: screen.displayID)?.removeFromSuperview()
        }
    }

    private func releaseSurface(_ displayID: CGDirectDisplayID) {
        frameHealth.removeValue(forKey: displayID)
        if let lines = lineViews.removeValue(forKey: displayID) {
            lines.onFailure = nil
            lines.clear()
            lines.removeFromSuperview()
        }
        switch surfaces.removeValue(forKey: displayID) {
        case .reactor(let view, let hud):
            view.onFailure = nil
            view.setPlaying(false)
            view.removeFromSuperview()
            hud.removeFromSuperview()
        case .wallpaperEngine(let view):
            view.onFailure = nil
            view.onReady = nil
            view.stop()
            view.removeFromSuperview()
        case .video(let view, let layer):
            layer.player = nil
            view.removeFromSuperview()
        case .scene(let view, let scene):
            view.isPaused = true
            (scene as? LiveWallpaperParticleScene)?.setLineRenderer(nil)
            view.presentScene(nil)
            view.removeFromSuperview()
        case .metal(let surface):
            surface.view.onFailure = nil
            surface.view.stop()
            surface.view.removeFromSuperview()
        case nil: break
        }
    }

    private func removeWindow(_ displayID: CGDirectDisplayID) {
        if let observer = occlusionObservers.removeValue(forKey: displayID) {
            NotificationCenter.default.removeObserver(observer)
        }
        releaseSurface(displayID)
        overlayViews.removeValue(forKey: displayID)?.removeFromSuperview()
        windowContents.removeValue(forKey: displayID)
        failedMetalDisplays.remove(displayID)
        windows.removeValue(forKey: displayID)?.orderOut(nil)
    }

    /// Covered means no wallpaper window has a visible pixel on any display.
    private func reportCoverage() {
        let covered = !windows.isEmpty && !windows.values.contains { $0.occlusionState.contains(.visible) }
        guard covered != lastCoverage else { return }
        lastCoverage = covered
        onCoverageChange?(covered)
    }

    private func teardown() {
        frameMonitor?.invalidate()
        frameMonitor = nil
        frameHealth.removeAll()
        lastFrameHealthCheck = nil
        lastConfiguration = nil
        for displayID in Array(windows.keys) { removeWindow(displayID) }
        for url in Array(playbacks.keys) { releasePlayback(url) }
        if lastCoverage == true { onCoverageChange?(false) }
        lastCoverage = nil
    }

    private static func gravity(for mode: LiveWallpaperScaleMode) -> AVLayerVideoGravity {
        switch mode {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}

@MainActor
protocol LiveWallpaperPowerMonitoring: AnyObject {
    var onChange: (() -> Void)? { get set }
    var isOnBattery: Bool { get }
    var isLowPowerMode: Bool { get }
    func start()
    func stop()
}

/// Power source changes arrive through IOKit's run-loop source; Low Power Mode through ProcessInfo.
@MainActor
final class SystemLiveWallpaperPowerMonitor: LiveWallpaperPowerMonitoring {
    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?

    var isOnBattery: Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemLiveWallpaperPowerMonitor>.fromOpaque(context).takeUnretainedValue().onChange?()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = source
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }
}
