import AppKit
import AVFoundation
import IOKit.ps
import SpriteKit
import SwiftUI

@MainActor
protocol LiveWallpaperRendering: AnyObject {
    /// True when no wallpaper window has a visible pixel, for example behind a full-screen app.
    var onCoverageChange: ((Bool) -> Void)? { get set }
    /// `nil` removes the windows and releases the player.
    func apply(_ configuration: LiveWallpaperRenderConfiguration?)
    /// The current frame of a scene surface, used as the system and lock screen wallpaper.
    func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage?
    /// New limits and hardware readings for the overlay; cheap, no windows are rebuilt.
    func updateOverlay(_ data: LiveWallpaperOverlayData)
    /// Hardware load in 0...1 that scenes react to; 0 turns the reaction off.
    func setSceneEnergy(_ value: Double)
}

/// Click-through windows at the desktop level, below Finder icons. Screens showing the same video share
/// one looping player, so they stay in sync and the clip is decoded once. Scene wallpapers get a SpriteKit
/// view per screen that runs only while playback is allowed.
@MainActor
final class DesktopLiveWallpaperRenderer: LiveWallpaperRendering {
    var onCoverageChange: ((Bool) -> Void)?

    private struct Playback {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
    }

    private enum Surface {
        case video(NSView, AVPlayerLayer)
        case scene(SKView, LiveWallpaperParticleScene)
    }

    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var overlayViews: [CGDirectDisplayID: NSView] = [:]
    private let overlayModel = LiveWallpaperOverlayModel()
    private var sceneEnergy = 0.0
    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var windowContents: [CGDirectDisplayID: LiveWallpaperContent] = [:]
    private var occlusionObservers: [CGDirectDisplayID: NSObjectProtocol] = [:]
    private var playbacks: [URL: Playback] = [:]
    private var lastCoverage: Bool?
    private var lastConfiguration: LiveWallpaperRenderConfiguration?

    static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    func apply(_ configuration: LiveWallpaperRenderConfiguration?) {
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
            case .video:
                if runs(displayID), case .video(let url) = windowContents[displayID] { playingURLs.insert(url) }
            case .scene(let view, let scene):
                let shouldRun = runs(displayID)
                if view.isPaused == shouldRun {
                    if shouldRun { scene.resumeClock() }
                    view.isPaused = !shouldRun
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
    }

    func updateOverlay(_ data: LiveWallpaperOverlayData) {
        if overlayModel.data != data { overlayModel.data = data }
    }

    func setSceneEnergy(_ value: Double) {
        sceneEnergy = value
        for case .scene(_, let scene) in surfaces.values { scene.setEnergy(value) }
    }

    func sceneSnapshot(forDisplay displayID: CGDirectDisplayID) -> CGImage? {
        guard case .scene(let view, let scene) = surfaces[displayID] else { return nil }
        return view.texture(from: scene)?.cgImage()
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
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        switch screen.content {
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
            let view = SKView(frame: bounds)
            view.ignoresSiblingOrder = true
            view.allowsTransparency = false
            view.preferredFramesPerSecond = settings.framesPerSecond
            view.isPaused = true
            let scene = LiveWallpaperParticleScene(size: bounds.size, screenFrame: screen.frame,
                                                   content: screen.content, settings: settings)
            scene.setEnergy(sceneEnergy)
            view.presentScene(scene)
            insertSurfaceView(view, in: window)
            surfaces[screen.displayID] = .scene(view, scene)
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
        switch surfaces.removeValue(forKey: displayID) {
        case .video(let view, let layer):
            layer.player = nil
            view.removeFromSuperview()
        case .scene(let view, _):
            view.isPaused = true
            view.presentScene(nil)
            view.removeFromSuperview()
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
