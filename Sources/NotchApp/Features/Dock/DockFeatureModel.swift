import AppKit
import Combine
import SwiftUI

/// Dependencies shared by the Dock window and its settings. Individual views
/// observe the stores they render; this owner handles shared surface lifetime.
@MainActor
final class DockFeatureModel: ObservableObject {
    let prefs: DockPreferences
    let applications: DockApplicationStore
    var apps: DockApplicationStore { applications }
    let previews: DockWindowPreviewService
    let stacks: DockFileStackProvider
    let systemDock: SystemDockController
    let trash: DockTrashModel
    let accessibility: DockAccessibilityMonitor
    let downloads: DockDownloadProgressModel
    let loginItems: DockLoginItems
    /// Current panel frame in AppKit screen coordinates, set by the window coordinator.
    var dockFrame: CGRect?
    let fan = DockFanPresenter()
    let anchors = DockAnchorRegistry()
    private var isActive = false
    @Published private(set) var surfaceGeneration = 0
    @Published var availableWidth: CGFloat = 700
    @Published var errorMessage: String?
    var onOpenLauncher: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onOpenDisplays: () -> Void = {}
    /// The window coordinator replaces this so every restore goes through its serialized queue.
    var onRestoreSystemDock: () -> Void

    init(prefs: DockPreferences,
         applications: DockApplicationStore = DockApplicationStore(),
         previews: DockWindowPreviewService = DockWindowPreviewService(),
         stacks: DockFileStackProvider = DockFileStackProvider(),
         systemDock: SystemDockController = SystemDockController(),
         trash: DockTrashModel = DockTrashModel(),
         accessibility: DockAccessibilityMonitor = DockAccessibilityMonitor(),
         downloads: DockDownloadProgressModel = DockDownloadProgressModel(),
         loginItems: DockLoginItems = DockLoginItems()) {
        self.prefs = prefs
        self.applications = applications
        self.previews = previews
        self.stacks = stacks
        self.systemDock = systemDock
        self.trash = trash
        self.accessibility = accessibility
        self.downloads = downloads
        self.loginItems = loginItems
        applications.applicationLaunched = { [weak prefs] path in prefs?.noteLaunchedApplication(path) }
        onRestoreSystemDock = { [systemDock] in Task { await systemDock.restore() } }
        applications.reconcilePinnedPaths = { [weak prefs] in prefs?.reconcileApplicationPaths() }
        applications.resolvePinnedPath = { [weak prefs] path in prefs?.resolveApplicationPath(path) ?? path }
    }

    func openLauncher() { closeSurfaces(); onOpenLauncher() }
    func openSettings() { closeSurfaces(); onOpenSettings() }
    func openDisplays() { closeSurfaces(); onOpenDisplays() }

    /// Turns replacement off and restores macOS Dock, including when the Dock module is off.
    func restoreSystemDock() {
        prefs.replaceSystemDock = false
        onRestoreSystemDock()
    }

    /// Starts or stops background helpers that only matter while the Dock is shown.
    func setActive(_ active: Bool) {
        if active != isActive {
            isActive = active
            if active { loginItems.refreshIfUsed() }
        }
        accessibility.update(active: active, options: .init(badges: prefs.showBadges,
                                                            minimizedWindows: prefs.showMinimizedWindows))
        if active, prefs.showDownloads, let path = downloadsElement.directoryPath {
            downloads.start(directory: URL(fileURLWithPath: path, isDirectory: true))
        } else {
            downloads.stop()
        }
    }

    func closeSurfaces() {
        fan.dismiss()
        surfaceGeneration += 1
        previews.cancel()
        stacks.cancel()
    }

    func switchProfile(_ id: String) {
        closeSurfaces()
        prefs.selectProfile(id)
    }

    var pinnedApplicationPaths: Set<String> {
        Set(prefs.items.flatMap { item in
            item.kind == .folder ? item.children.compactMap(\.applicationPath)
                : [item.applicationPath].compactMap { $0 }
        })
    }

    /// Downloads and Trash: fixed cells after the applications, like the system Dock.
    var trailingCellCount: Int {
        minimizedWindows.count + (prefs.showDownloads ? 1 : 0) + (prefs.showTrash ? 1 : 0)
    }

    var minimizedWindows: [DockMinimizedWindow] {
        prefs.showMinimizedWindows ? accessibility.minimizedWindows : []
    }

    /// Recently opened applications that are neither pinned nor running, at most three.
    /// Read on every Dock render; the file checks run only when the inputs change.
    var recentApplications: [DockRecentApplication] {
        guard prefs.showRecentApplications else { return [] }
        let excluded = pinnedApplicationPaths.union(applications.running.map(\.path))
        let key = RecentKey(recent: prefs.recentApplications, excluded: excluded)
        if let cached = recentCache, cached.key == key { return cached.value }
        let value = Array(prefs.recentApplications.lazy.filter { path in
            !excluded.contains(path) && FileManager.default.fileExists(atPath: path)
        }.prefix(3).map { path in
            DockRecentApplication(path: path, title: FileManager.default.displayName(atPath: path)
                .replacingOccurrences(of: ".app", with: ""))
        })
        recentCache = (key, value)
        return value
    }
    private struct RecentKey: Equatable {
        let recent: [String]
        let excluded: Set<String>
    }
    private var recentCache: (key: RecentKey, value: [DockRecentApplication])?

    var popoverEdge: Edge {
        switch prefs.position {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    /// A pinned item dragged this far from the Dock and released is removed, like the system Dock.
    func isOutsideDock(_ point: CGPoint) -> Bool {
        guard let frame = dockFrame else { return false }
        return !frame.insetBy(dx: -36, dy: -36).contains(point)
    }

    /// Files dropped on a stack or Downloads; runs off the main actor.
    func receiveFiles(_ urls: [URL], into directoryPath: String) {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let forceCopy = NSEvent.modifierFlags.contains(.option)
        Task { [weak self] in
            let failures = await Task.detached(priority: .userInitiated) {
                DockFileTransfer.transfer(urls, into: directory, forceCopy: forceCopy)
            }.value
            guard let self else { return }
            self.errorMessage = failures.isEmpty ? nil
                : "Не удалось переместить: \(failures.prefix(3).joined(separator: ", "))\(failures.count > 3 ? "…" : "")."
        }
    }

    var downloadsElement: DockElement {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return DockElement(id: "system:downloads", kind: .stack, title: "Загрузки", directoryPath: url.path)
    }

    var immersiveOptions: DockImmersiveContent.Options {
        .init(games: prefs.hideInFullscreenGames, video: prefs.hideInFullscreenVideo,
              excludedBundleIdentifiers: Set(prefs.fullscreenExclusions))
    }

    var unpinnedApplications: [DockRunningApplication] {
        let pinned = pinnedApplicationPaths
        return applications.running.filter { !pinned.contains($0.path) }
    }

    func effectiveElement(_ item: DockElement) -> DockElement {
        var result = item
        // A vertical Dock has one column: every widget uses its compact size.
        if prefs.position.isVertical { result.span = 1; return result }
        result.span = DockLayout.effectiveSpan(item.span, supported: prefs.supportedSpans(for: item),
                                               availableWidth: max(56, availableWidth - 90 * prefs.scale),
                                               scale: prefs.scale)
        return result
    }
}
