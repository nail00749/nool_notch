import AppKit
import Combine

@MainActor
protocol LiveWallpaperDesktopImageSetting {
    func setDesktopImage(_ url: URL, for screen: NSScreen) throws
}

struct SystemLiveWallpaperDesktopImage: LiveWallpaperDesktopImageSetting {
    func setDesktopImage(_ url: URL, for screen: NSScreen) throws {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }
}

/// Owns the wallpaper library, preferences and playback lifecycle; the renderer owns the windows.
@MainActor
final class LiveWallpaperController: ObservableObject {
    @Published private(set) var preferences: LiveWallpaperPreferences
    @Published private(set) var items: [LiveWallpaperItem] = LiveWallpaperItem.presets
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var displays: [LiveWallpaperDisplay] = []
    @Published private(set) var environment = LiveWallpaperEnvironment()
    @Published private(set) var isImporting = false
    @Published private(set) var message: String?

    let library: LiveWallpaperLibrary
    private let renderer: any LiveWallpaperRendering
    private let power: any LiveWallpaperPowerMonitoring
    private let desktopImage: any LiveWallpaperDesktopImageSetting
    private let defaults: UserDefaults
    private let screensProvider: @MainActor () -> [NSScreen]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var thumbnailRequests: Set<String> = []
    private var libraryGeneration = 0
    private var posterGeneration = 0
    private var started = false
    private var stopped = false
    private static let preferencesKey = "nool.liveWallpaper.preferences.v1"

    init(defaults: UserDefaults = .standard,
         library: LiveWallpaperLibrary = LiveWallpaperLibrary(directory: LiveWallpaperLibrary.defaultDirectory()),
         renderer: any LiveWallpaperRendering = DesktopLiveWallpaperRenderer(),
         power: any LiveWallpaperPowerMonitoring = SystemLiveWallpaperPowerMonitor(),
         desktopImage: any LiveWallpaperDesktopImageSetting = SystemLiveWallpaperDesktopImage(),
         screensProvider: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens }) {
        self.defaults = defaults
        self.library = library
        self.renderer = renderer
        self.power = power
        self.desktopImage = desktopImage
        self.screensProvider = screensProvider
        preferences = defaults.data(forKey: Self.preferencesKey).flatMap {
            try? JSONDecoder().decode(LiveWallpaperPreferences.self, from: $0)
        }?.sanitized ?? LiveWallpaperPreferences()
        renderer.onCoverageChange = { [weak self] covered in
            guard let self, self.started else { return }
            self.environment.isCovered = covered
            self.render()
        }
        power.onChange = { [weak self] in self?.refreshPower() }
    }

    /// The video a target shows: a display without its own choice falls back to the shared one.
    func fileName(for target: LiveWallpaperTarget) -> String? {
        switch target {
        case .allDisplays: preferences.selectedFileName
        case .display(let key): preferences.fileName(forDisplay: key)
        }
    }

    func hasOverride(_ display: LiveWallpaperDisplay) -> Bool { preferences.displayFileNames[display.key] != nil }

    func item(named fileName: String?) -> LiveWallpaperItem? {
        guard let fileName else { return nil }
        return items.first { $0.fileName == fileName }
    }

    var fileItems: [LiveWallpaperItem] { items.filter { $0.preset == nil } }

    /// True when any display shows a built-in scene or a picture, so scene settings apply.
    var usesScenes: Bool {
        activeDisplays.contains { item(named: preferences.fileName(forDisplay: $0.key))?.content.isScene == true }
    }

    /// Displays that currently resolve to an existing wallpaper.
    var activeDisplays: [LiveWallpaperDisplay] {
        displays.filter { item(named: preferences.fileName(forDisplay: $0.key)) != nil }
    }

    var playbackState: LiveWallpaperPlaybackState {
        LiveWallpaperPolicy.state(preferences: preferences, hasContent: !activeDisplays.isEmpty, environment: environment)
    }

    // MARK: Module lifecycle

    func start() {
        guard !started, !stopped else { return }
        started = true
        environment = LiveWallpaperEnvironment()
        power.start()
        refreshPower(render: false)
        refreshDisplays()
        observe()
        reloadLibrary()
    }

    /// Reversible: the module catalog turned the feature off. Preferences and files stay.
    func pause() {
        guard started else { return }
        started = false
        libraryGeneration += 1
        posterGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        workspaceObservers = []
        power.stop()
        renderer.apply(nil)
    }

    func stop() {
        pause()
        stopped = true
    }

    // MARK: Commands

    func setPreferences(_ value: LiveWallpaperPreferences) {
        let next = value.sanitized
        guard next != preferences else { return }
        let syncNeeded = next.syncsSystemWallpaper
            && (!preferences.syncsSystemWallpaper || next.selectedFileName != preferences.selectedFileName
                || next.displayFileNames != preferences.displayFileNames)
        preferences = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.preferencesKey) }
        render()
        if syncNeeded { syncSystemWallpaper() }
    }

    /// "All displays" sets the shared video and keeps per-display choices; a display gets its own override.
    func assign(_ item: LiveWallpaperItem, to target: LiveWallpaperTarget) {
        var next = preferences
        switch target {
        case .allDisplays: next.selectedFileName = item.fileName
        case .display(let key): next.displayFileNames[key] = item.fileName
        }
        next.enabled = true
        setPreferences(next)
    }

    func select(_ item: LiveWallpaperItem) { assign(item, to: .allDisplays) }

    /// The display returns to the shared video.
    func resetDisplay(_ key: String) {
        var next = preferences
        next.displayFileNames[key] = nil
        setPreferences(next)
    }

    /// Clears every per-display choice so all displays show the shared video.
    func resetAllDisplays() {
        var next = preferences
        next.displayFileNames = [:]
        setPreferences(next)
    }

    func importVideos(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        message = nil
        let library = library
        Task { [weak self] in
            var imported: [LiveWallpaperItem] = []
            var failures: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard LiveWallpaperLibrary.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                    failures.append(LiveWallpaperLibraryError.unsupportedFile(url.lastPathComponent).localizedDescription)
                    continue
                }
                guard await LiveWallpaperMedia.isUsable(url) else {
                    failures.append(LiveWallpaperLibraryError.unplayable(url.lastPathComponent).localizedDescription)
                    continue
                }
                do {
                    imported.append(try await Task.detached { try library.importFile(from: url) }.value)
                } catch {
                    failures.append("«\(url.lastPathComponent)»: \(error.localizedDescription)")
                }
            }
            self?.finishImport(imported: imported, failures: failures)
        }
    }

    func remove(_ item: LiveWallpaperItem) {
        guard item.preset == nil else { return }
        let library = library
        Task { [weak self] in
            do {
                try await Task.detached { try library.trash(item) }.value
                guard let self else { return }
                self.thumbnails[item.fileName] = nil
                var next = self.preferences
                next.forget(fileName: item.fileName)
                self.setPreferences(next)
                self.reloadLibrary()
            } catch {
                self?.message = "Не удалось переместить в Корзину: \(error.localizedDescription)"
            }
        }
    }

    func revealFolder() {
        try? library.ensureDirectory()
        NSWorkspace.shared.open(library.directory)
    }

    func reveal(_ item: LiveWallpaperItem) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func reloadLibrary() {
        libraryGeneration += 1
        let generation = libraryGeneration
        let library = library
        Task { [weak self] in
            let items = await Task.detached { () -> [LiveWallpaperItem] in
                try? library.ensureDirectory()
                return LiveWallpaperItem.presets + library.items()
            }.value
            guard let self, generation == self.libraryGeneration else { return }
            self.items = items
            let names = Set(items.map(\.fileName))
            self.thumbnails = self.thumbnails.filter { names.contains($0.key) }
            if self.preferences.enabled, !self.preferences.referencedFileNames.isSubset(of: names) {
                self.message = "Выбранные обои не найдены в папке."
            }
            self.render()
            for item in items { self.loadThumbnail(item) }
        }
    }

    // MARK: Internals

    private func finishImport(imported: [LiveWallpaperItem], failures: [String]) {
        isImporting = false
        message = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if let first = imported.first, item(named: preferences.selectedFileName) == nil {
            // The first import becomes the shared wallpaper only when nothing valid is chosen yet.
            var next = preferences
            next.selectedFileName = first.fileName
            setPreferences(next)
        }
        reloadLibrary()
    }

    private func loadThumbnail(_ item: LiveWallpaperItem) {
        guard let url = item.url, thumbnails[item.fileName] == nil,
              thumbnailRequests.insert(item.fileName).inserted else { return }
        let isImage: Bool = if case .image = item.content { true } else { false }
        Task { [weak self] in
            let image = isImage
                ? await Task.detached { LiveWallpaperMedia.image(at: url, maxPixelSize: 480) }.value
                : await LiveWallpaperMedia.frame(of: url, maximumSize: CGSize(width: 480, height: 300))
            guard let self else { return }
            self.thumbnailRequests.remove(item.fileName)
            if let image { self.thumbnails[item.fileName] = NSImage(cgImage: image, size: .zero) }
        }
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        let sleeps: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                           NSWorkspace.sessionDidResignActiveNotification]
        let wakes: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                                          NSWorkspace.sessionDidBecomeActiveNotification]
        for name in sleeps {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(true) }
            })
        }
        for name in wakes {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.refreshDisplays()
                self.render()
            }
        })
    }

    private func refreshDisplays() {
        let next = screensProvider().compactMap(Self.display(for:))
        if next != displays { displays = next }
    }

    static func display(for screen: NSScreen) -> LiveWallpaperDisplay? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = number.uint32Value
        let key = CGDisplayCreateUUIDFromDisplayID(displayID)
            .flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? } ?? "display-\(displayID)"
        return LiveWallpaperDisplay(key: key, displayID: displayID, name: screen.localizedName, frame: screen.frame)
    }

    private func setAsleep(_ asleep: Bool) {
        guard started, environment.isAsleep != asleep else { return }
        environment.isAsleep = asleep
        render()
    }

    private func refreshPower(render shouldRender: Bool = true) {
        guard started else { return }
        environment.isOnBattery = power.isOnBattery
        environment.isLowPowerMode = power.isLowPowerMode
        if shouldRender { render() }
    }

    private func render() {
        guard started else { return }
        renderer.apply(LiveWallpaperPolicy.configuration(
            displays: displays, preferences: preferences, environment: environment,
            resolve: { [items] name in items.first { $0.fileName == name }?.content }
        ))
    }

    /// Sets each display's system wallpaper, which macOS also shows on the lock screen, to a frame of
    /// its video, to its picture or to a snapshot of its scene.
    private func syncSystemWallpaper() {
        guard started else { return }
        posterGeneration += 1
        let generation = posterGeneration
        let library = library
        let targets = displays.compactMap { display -> (LiveWallpaperDisplay, LiveWallpaperItem)? in
            guard let item = item(named: preferences.fileName(forDisplay: display.key)) else { return nil }
            return (display, item)
        }
        // Scenes are random and sized per display, so each display gets its own snapshot file.
        // The file name includes the scene so macOS does not keep showing a cached earlier snapshot.
        let snapshots = targets.compactMap { display, item -> (String, String, LiveWallpaperImageBox)? in
            guard item.content.isScene,
                  let image = renderer.sceneSnapshot(forDisplay: display.displayID) else { return nil }
            return (display.key, "\(item.fileName)-\(display.key)", LiveWallpaperImageBox(image: image))
        }
        Task { [weak self] in
            var posters: [String: URL] = [:]
            for item in Set(targets.map(\.1.fileName)).compactMap({ name in targets.first { $0.1.fileName == name }?.1 }) {
                guard let url = item.url else { continue }
                if case .image = item.content {
                    posters[item.fileName] = url
                    continue
                }
                guard let frame = await LiveWallpaperMedia.frame(of: url, maximumSize: .zero) else { continue }
                let box = LiveWallpaperImageBox(image: frame)
                posters[item.fileName] = try? await Task.detached { try library.writePoster(box.image, for: item.fileName) }.value
            }
            var scenePosters: [String: URL] = [:]
            for (key, name, box) in snapshots {
                scenePosters[key] = try? await Task.detached { try library.writePoster(box.image, for: name) }.value
            }
            guard let self, generation == self.posterGeneration, self.preferences.syncsSystemWallpaper else { return }
            let screens = self.screensProvider()
            var failed = false
            for (display, item) in targets {
                guard let poster = item.content.isScene ? scenePosters[display.key] : posters[item.fileName],
                      let screen = screens.first(where: { Self.display(for: $0)?.key == display.key }) else {
                    failed = true
                    continue
                }
                do { try self.desktopImage.setDesktopImage(poster, for: screen) } catch { failed = true }
            }
            if failed { self.message = "Не удалось обновить системные обои на части дисплеев." }
        }
    }
}

private struct LiveWallpaperImageBox: @unchecked Sendable {
    let image: CGImage
}
