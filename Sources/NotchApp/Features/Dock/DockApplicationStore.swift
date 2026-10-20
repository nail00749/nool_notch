import AppKit
import Combine
import Foundation

struct DockRunningApplication: Identifiable {
    var id: String { path }
    var path: String
    var title: String
    var pid: Int32
    var icon: NSImage?
    var isActive: Bool
    var isHidden = false
}

struct DockInstalledApplication: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var title: String
}

@MainActor
final class DockApplicationStore: ObservableObject {
    @Published private(set) var running: [DockRunningApplication] = []
    @Published var errorMessage: String?
    @Published private(set) var catalog: [DockInstalledApplication] = []
    @Published private(set) var isCatalogLoading = false
    /// Applications opened from the Dock that have not appeared yet: their icons bounce.
    @Published private(set) var launching: Set<String> = []
    /// Called with the bundle path of every newly launched regular application.
    var applicationLaunched: ((String) -> Void)?
    private var launchTimeouts: [String: Task<Void, Never>] = [:]
    private var observations: [NSObjectProtocol] = []
    private var icons: [String: NSImage] = [:]
    private var canonicalPaths: [Int32: (source: String, resolved: String)] = [:]
    private let workspace: NSWorkspace
    private let documentOpener: (@MainActor ([URL], URL) -> Void)?
    private var isStarted = false
    /// Supplied by the composition root so persisted bookmarks can update pins
    /// atomically before a launch, file drop, or normal quit action.
    var resolvePinnedPath: ((String) -> String)?
    /// Refreshes moved pinned bundles in every profile; called on discovery and launch only.
    var reconcilePinnedPaths: (() -> Void)?
    private let catalogLoader: @MainActor () async -> [DockInstalledApplication]
    private var catalogTask: Task<[DockInstalledApplication], Never>?
    private var catalogGeneration = UUID()

    init(workspace: NSWorkspace = .shared,
         catalogLoader: (@MainActor () async -> [DockInstalledApplication])? = nil,
         documentOpener: (@MainActor ([URL], URL) -> Void)? = nil) {
        self.workspace = workspace
        self.documentOpener = documentOpener
        if let catalogLoader {
            self.catalogLoader = catalogLoader
        } else {
            let provider = LauncherApplicationProvider()
            self.catalogLoader = {
                // Launcher owns the bounded, cancellable detached filesystem scan and its cache.
                await provider.refresh()
                return provider.results.compactMap { result in
                    guard case let .application(url) = result.payload else { return nil }
                    return DockInstalledApplication(path: url.standardizedFileURL.path, title: result.title)
                }
            }
        }
    }

    func loadCatalog() async {
        let generation: UUID
        let task: Task<[DockInstalledApplication], Never>
        if let existing = catalogTask {
            task = existing
            generation = catalogGeneration
        } else {
            generation = UUID()
            catalogGeneration = generation
            let loader = catalogLoader
            task = Task { await loader() }
            catalogTask = task
            isCatalogLoading = true
        }
        let loaded = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        guard generation == catalogGeneration else { return }
        if !Task.isCancelled && !task.isCancelled {
            var paths = Set<String>()
            catalog = loaded.prefix(3_000).compactMap { candidate in
                guard candidate.path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
                guard url.pathExtension.lowercased() == "app", paths.insert(url.path).inserted else { return nil }
                return DockInstalledApplication(path: url.path, title: candidate.title)
            }
        }
        catalogTask = nil
        isCatalogLoading = false
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = workspace.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification,
                                          NSWorkspace.didActivateApplicationNotification,
                                          NSWorkspace.didHideApplicationNotification,
                                          NSWorkspace.didUnhideApplicationNotification]
        observations = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                    ? (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                        .flatMap { $0.activationPolicy == .regular ? $0.bundleURL : nil }?
                        .standardizedFileURL.resolvingSymlinksInPath().path
                    : nil
                Task { @MainActor [weak self] in
                    guard let self, self.isStarted else { return }
                    if let launched { self.applicationLaunched?(launched) }
                    if name == NSWorkspace.didActivateApplicationNotification ||
                        name == NSWorkspace.didHideApplicationNotification || name == NSWorkspace.didUnhideApplicationNotification {
                        let frontmost = self.workspace.frontmostApplication
                        if let frontmost, frontmost.activationPolicy == .regular,
                           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                           !self.running.contains(where: { $0.pid == frontmost.processIdentifier }) {
                            self.refresh(reconcilePinnedPaths: false)
                        } else {
                            self.updateActivation(activePID: frontmost?.processIdentifier)
                        }
                    } else {
                        self.refresh(reconcilePinnedPaths: name == NSWorkspace.didLaunchApplicationNotification)
                    }
                }
            }
        }
        refresh()
    }

    func stop() {
        isStarted = false
        for token in observations { workspace.notificationCenter.removeObserver(token) }
        observations.removeAll()
        launchTimeouts.values.forEach { $0.cancel() }
        launchTimeouts.removeAll()
        launching = []
        running = []
        icons.removeAll()
        canonicalPaths.removeAll()
        errorMessage = nil
        catalogTask?.cancel()
        catalogTask = nil
        catalogGeneration = UUID()
        isCatalogLoading = false
        catalog = []
    }

    func refresh(reconcilePinnedPaths: Bool = true) {
        let snapshots = workspace.runningApplications.compactMap { application -> DockRunningApplication? in
            guard application.activationPolicy == .regular, !application.isTerminated,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let url = application.bundleURL else { return nil }
            let sourcePath = url.path
            let path: String
            if let cached = canonicalPaths[application.processIdentifier], cached.source == sourcePath {
                path = cached.resolved
            } else {
                path = url.standardizedFileURL.resolvingSymlinksInPath().path
                canonicalPaths[application.processIdentifier] = (sourcePath, path)
            }
            let image = icons[path] ?? application.icon ?? icon(for: path)
            icons[path] = image
            return DockRunningApplication(path: path, title: application.localizedName ?? url.deletingPathExtension().lastPathComponent,
                                          pid: application.processIdentifier, icon: image, isActive: application.isActive,
                                          isHidden: application.isHidden)
        }
        let livePIDs = Set(snapshots.map(\.pid))
        canonicalPaths = canonicalPaths.filter { livePIDs.contains($0.key) }
        updateRunningApplications(snapshots, reconcilePinnedPaths: reconcilePinnedPaths)
    }

    /// Activation notifications only change focus. Do not scan bundles, load
    /// icons, or resolve every profile's bookmarks while switching applications.
    func updateActivation(activePID: Int32?) {
        let updated = running.map { application in
            var result = application
            result.isActive = application.pid == activePID
            result.isHidden = NSRunningApplication(processIdentifier: application.pid)?.isHidden ?? application.isHidden
            return result
        }
        publishIfChanged(updated)
    }

    func updateRunningApplications(_ snapshots: [DockRunningApplication], reconcilePinnedPaths: Bool) {
        // Resolve moved pins on initial discovery/launch, before exposing the new
        // running icon. Explicit actions also resolve their target immediately.
        if reconcilePinnedPaths, !snapshots.isEmpty { self.reconcilePinnedPaths?() }
        // Keep the user's mental position stable across activation notifications.
        let previousOrder = Dictionary(uniqueKeysWithValues: running.enumerated().map { ($0.element.path, $0.offset) })
        let updated = Self.deduplicated(snapshots).sorted {
            let left = previousOrder[$0.path] ?? Int.max
            let right = previousOrder[$1.path] ?? Int.max
            if left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        publishIfChanged(updated)
        if icons.count > 256 {
            let current = Set(running.map(\.path))
            icons = icons.filter { current.contains($0.key) }
        }
    }

    private func publishIfChanged(_ updated: [DockRunningApplication]) {
        guard running.count != updated.count || zip(running, updated).contains(where: { old, new in
            old.path != new.path || old.title != new.title || old.pid != new.pid ||
            old.isActive != new.isActive || old.isHidden != new.isHidden || old.icon !== new.icon
        }) else { return }
        running = updated
        let appeared = launching.intersection(updated.map(\.path))
        for path in appeared { finishLaunching(path) }
    }

    static func deduplicated(_ applications: [DockRunningApplication]) -> [DockRunningApplication] {
        var output: [DockRunningApplication] = []
        var indexes: [String: Int] = [:]
        for application in applications {
            if let index = indexes[application.path] {
                if application.isActive { output[index] = application }
            } else {
                indexes[application.path] = output.count
                output.append(application)
            }
        }
        return output
    }

    func icon(for path: String) -> NSImage {
        if let image = icons[path] { return image }
        let image = workspace.icon(forFile: path)
        if icons.count >= 256 {
            let current = Set(running.map(\.path))
            icons = icons.filter { current.contains($0.key) }
        }
        icons[path] = image
        return image
    }

    func open(path: String) {
        guard let url = applicationURL(path: path) else { return }
        errorMessage = nil
        if url.path == "/System/Library/CoreServices/Finder.app" {
            // Finder normally already runs without a window. Activating that
            // process only focuses the desktop; opening a folder creates/reuses
            // an actual Finder window even when another file manager is default.
            openDocuments([FileManager.default.homeDirectoryForCurrentUser], with: url)
            return
        }
        // Like the system Dock: activates a running instance and sends it a reopen event,
        // so an application without windows opens a new one. `activate()` alone does
        // neither and may be ignored for a non-active accessory app on macOS 14+.
        if !running.contains(where: { $0.path == url.path }) { beginLaunching(url.path) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            let message = error?.localizedDescription
            let path = url.path
            Task { @MainActor [weak self] in
                guard let message else { return }
                self?.errorMessage = message
                self?.finishLaunching(path)
            }
        }
    }

    /// The icon bounces until the application appears, at most ten seconds, like the system Dock.
    func beginLaunching(_ path: String) {
        launching.insert(path)
        launchTimeouts[path]?.cancel()
        launchTimeouts[path] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.finishLaunching(path)
        }
    }

    private func finishLaunching(_ path: String) {
        launchTimeouts.removeValue(forKey: path)?.cancel()
        if launching.contains(path) { launching.remove(path) }
    }

    /// ⌥-click: hides the active application, otherwise opens it and hides all others.
    func openHidingOthers(path: String) {
        guard let url = applicationURL(path: path) else { return }
        let matching = matchingApplications(path: url.path)
        if matching.contains(where: \.isActive) {
            matching.forEach { $0.hide() }
            return
        }
        open(path: url.path)
        let own = ProcessInfo.processInfo.processIdentifier
        for application in workspace.runningApplications where application.activationPolicy == .regular
            && application.processIdentifier != own && !matching.contains(application) {
            application.hide()
        }
    }

    func setHidden(_ hidden: Bool, path: String) {
        guard let url = applicationURL(path: path) else { return }
        for application in matchingApplications(path: url.path) {
            if hidden { application.hide() } else { application.unhide() }
        }
    }

    /// ⌥ in the context menu: like the system Dock, no save prompts are shown.
    func forceTerminate(path: String) {
        guard let url = applicationURL(path: path) else { return }
        errorMessage = nil
        let rejected = matchingApplications(path: url.path).filter { !$0.forceTerminate() }
        if !rejected.isEmpty {
            errorMessage = "Не удалось принудительно завершить «\(url.deletingPathExtension().lastPathComponent)»."
        }
    }

    func revealInFinder(path: String) {
        let current = resolvePinnedPath?(path) ?? path
        workspace.activateFileViewerSelecting([URL(fileURLWithPath: current)])
    }

    func openFiles(_ files: [URL], with path: String) {
        guard !files.isEmpty, files.count <= 512, files.allSatisfy(\.isFileURL),
              let application = applicationURL(path: path) else { return }
        errorMessage = nil
        openDocuments(files, with: application)
    }

    private func openDocuments(_ files: [URL], with application: URL) {
        if let documentOpener {
            documentOpener(files, application)
            return
        }
        workspace.open(files, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                if let message { self?.errorMessage = message }
            }
        }
    }

    func terminate(path: String) {
        guard let url = applicationURL(path: path) else { return }
        errorMessage = nil
        // terminate() only reports whether the request was delivered; the app may still ask to save.
        let rejected = matchingApplications(path: url.path).filter { !$0.terminate() }
        if !rejected.isEmpty {
            errorMessage = "Приложение «\(url.deletingPathExtension().lastPathComponent)» отклонило запрос на завершение."
        }
    }

    private func applicationURL(path: String) -> URL? {
        guard path.hasPrefix("/") else { errorMessage = "Некорректный путь приложения."; return nil }
        let currentPath = resolvePinnedPath?(path) ?? path
        guard currentPath.hasPrefix("/") else { errorMessage = "Некорректный путь приложения."; return nil }
        let url = URL(fileURLWithPath: currentPath).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              Bundle(url: url) != nil else {
            errorMessage = "Приложение «\(url.deletingPathExtension().lastPathComponent)» недоступно."
            return nil
        }
        return url
    }

    private func matchingApplications(path: String) -> [NSRunningApplication] {
        workspace.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }
}
