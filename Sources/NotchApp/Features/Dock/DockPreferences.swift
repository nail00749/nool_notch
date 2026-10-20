import AppKit
import Combine
import Foundation

@MainActor
final class DockPreferences: ObservableObject {
    static let storageKey = "nool.dock.v2.preferences"
    /// Built-in integration metadata comes only from `DockIntegrationRegistry`.
    static var integrationTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: DockIntegrationRegistry.integrations.map { ($0.id, $0.title) })
    }
    private let defaults: UserDefaults
    private var isNormalizing = false
    private var relocatedApplicationPaths: [String: String] = [:]
    /// Additional integrations may be registered on top of the built-in registry.
    var integrationSpans: [String: [Int]] = Dictionary(uniqueKeysWithValues:
        DockIntegrationRegistry.integrations.map { ($0.id, $0.supportedSpans) })
    private var registeredTitles = DockPreferences.integrationTitles
    var onChange: (() -> Void)?

    @Published var isEnabled: Bool { didSet { changed() } }
    @Published var visibility: DockVisibilityMode { didSet { changed() } }
    @Published var scale: Double { didSet { changed() } }
    @Published var opacity: Double { didSet { changed() } }
    @Published var magnification: Double { didSet { changed() } }
    @Published var displayUUID: String { didSet { changed() } }
    @Published var replaceSystemDock: Bool { didSet { changed() } }
    @Published var previewEnabled: Bool { didSet { changed() } }
    @Published var showAppLabels: Bool { didSet { changed() } }
    @Published var noteText: String { didSet { changed() } }
    /// System Dock-style trailing section: Downloads stack and Trash.
    @Published var showDownloads: Bool { didSet { changed() } }
    @Published var showTrash: Bool { didSet { changed() } }
    @Published var downloadsSort: DockStackSort { didSet { changed() } }
    /// Full screen: the bottom edge stays inert for games, playing video and these bundle identifiers.
    @Published var hideInFullscreenGames: Bool { didSet { changed() } }
    @Published var hideInFullscreenVideo: Bool { didSet { changed() } }
    @Published private(set) var fullscreenExclusions: [String]
    @Published var position: DockPosition { didSet { changed() } }
    /// Up to three recently opened, unpinned and closed applications after running ones.
    @Published var showRecentApplications: Bool { didSet { changed() } }
    @Published private(set) var recentApplications: [String]
    @Published var animateLaunch: Bool { didSet { changed() } }
    @Published var dimHiddenApplications: Bool { didSet { changed() } }
    /// ⌥⌘D toggles automatic hiding, like the system Dock shortcut.
    @Published var hideHotKeyEnabled: Bool { didSet { changed() } }
    @Published var downloadsStyle: DockStackStyle { didSet { changed() } }
    /// Accessibility-backed: badges from the system Dock and minimized windows of running apps.
    @Published var showBadges: Bool { didSet { changed() } }
    @Published var showMinimizedWindows: Bool { didSet { changed() } }
    @Published private(set) var profiles: [DockProfile]
    @Published private(set) var activeProfileID: String

    var items: [DockElement] { profiles.first(where: { $0.id == activeProfileID })?.elements ?? [] }
    var flattenedApps: [DockElement] { items.flatMap { $0.kind == .app ? [$0] : $0.children.filter { $0.kind == .app } } }

    private struct Payload: Codable {
        var version = 2
        var isEnabled: Bool
        var visibility: DockVisibilityMode
        var scale: Double
        var opacity: Double
        var magnification: Double
        var displayUUID: String
        var replaceSystemDock: Bool
        var previewEnabled: Bool
        var noteText: String
        var profiles: [DockProfile]
        var activeProfileID: String
        var showAppLabels: Bool? = nil
        var showDownloads: Bool? = nil
        var showTrash: Bool? = nil
        var downloadsSort: DockStackSort? = nil
        var hideInFullscreenGames: Bool? = nil
        var hideInFullscreenVideo: Bool? = nil
        var fullscreenExclusions: [String]? = nil
        var position: DockPosition? = nil
        var showRecentApplications: Bool? = nil
        var recentApplications: [String]? = nil
        var animateLaunch: Bool? = nil
        var dimHiddenApplications: Bool? = nil
        var hideHotKeyEnabled: Bool? = nil
        var downloadsStyle: DockStackStyle? = nil
        var showBadges: Bool? = nil
        var showMinimizedWindows: Bool? = nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedData = defaults.data(forKey: Self.storageKey)
        let saved = storedData.flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        if let storedData, saved?.version != 2, defaults.data(forKey: Self.storageKey + ".unreadableBackup") == nil {
            // Never destroy the only copy of a corrupt or newer schema while repairing preferences.
            defaults.set(storedData, forKey: Self.storageKey + ".unreadableBackup")
        }
        let payload = saved.flatMap { $0.version == 2 ? $0 : nil } ?? Self.migrate(defaults)
        isEnabled = payload.isEnabled
        visibility = payload.visibility
        scale = Self.clamp(payload.scale, to: 0.7...1.4, fallback: 1)
        opacity = Self.clamp(payload.opacity, to: 0.45...1, fallback: 0.88)
        magnification = Self.clamp(payload.magnification, to: 0...1, fallback: 0.3)
        displayUUID = payload.displayUUID
        replaceSystemDock = payload.replaceSystemDock
        previewEnabled = payload.previewEnabled
        showAppLabels = payload.showAppLabels ?? false
        showDownloads = payload.showDownloads ?? true
        showTrash = payload.showTrash ?? true
        downloadsSort = payload.downloadsSort ?? .added
        hideInFullscreenGames = payload.hideInFullscreenGames ?? true
        hideInFullscreenVideo = payload.hideInFullscreenVideo ?? true
        fullscreenExclusions = Self.exclusions(payload.fullscreenExclusions ?? [])
        position = payload.position ?? .bottom
        showRecentApplications = payload.showRecentApplications ?? true
        recentApplications = Self.recent(payload.recentApplications ?? [])
        animateLaunch = payload.animateLaunch ?? true
        dimHiddenApplications = payload.dimHiddenApplications ?? true
        hideHotKeyEnabled = payload.hideHotKeyEnabled ?? true
        downloadsStyle = payload.downloadsStyle ?? .automatic
        showBadges = payload.showBadges ?? true
        showMinimizedWindows = payload.showMinimizedWindows ?? true
        noteText = String(payload.noteText.prefix(2_000))
        var ids = Set<String>()
        var restoredProfiles = payload.profiles.prefix(16).compactMap { profile -> DockProfile? in
            guard !profile.id.isEmpty, ids.insert(profile.id).inserted else { return nil }
            return DockProfile(id: profile.id, name: Self.title(profile.name, fallback: "Профиль"),
                               elements: Self.normalized(profile.elements))
        }
        if restoredProfiles.isEmpty { restoredProfiles = [DockProfile(name: "Основной", elements: Self.defaultItems)] }
        profiles = restoredProfiles
        activeProfileID = restoredProfiles.contains(where: { $0.id == payload.activeProfileID }) ? payload.activeProfileID : restoredProfiles[0].id
        persist()
    }

    @discardableResult
    func addApplication(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        _ = resolveApplicationPath(canonical.path)
        var isDirectory: ObjCBool = false
        guard canonical.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue, let bundle = Bundle(url: canonical),
              !items.flatMap({ $0.applicationPaths }).contains(canonical.path),
              items.flatMap({ $0.applicationPaths }).count < 128 else { return false }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? canonical.deletingPathExtension().lastPathComponent
        let element = DockElement(id: "app:\(canonical.path)", kind: .app, title: name, applicationPath: canonical.path)
        return append(DockApplicationBookmark.refreshed(element) ?? element)
    }

    /// Resolve immediately before an explicit application action. Refresh every
    /// profile together so moving a bundle cannot create a second running icon.
    func resolveApplicationPath(_ savedPath: String) -> String {
        reconcileApplicationPaths()
        var resolvedPath = savedPath
        // Follow a bounded chain: a bundle may have moved more than once.
        for _ in 0..<8 {
            guard let next = relocatedApplicationPaths[resolvedPath], next != resolvedPath else { break }
            resolvedPath = next
        }
        return resolvedPath
    }

    /// One bookmark resolution per pinned application. Profiles are normalized and
    /// persisted only when a pin actually moved or received a fresh bookmark.
    func reconcileApplicationPaths() {
        var modified = false
        func refresh(_ element: DockElement) -> DockElement {
            guard element.kind == .app, let oldPath = element.applicationPath,
                  let fresh = DockApplicationBookmark.refreshed(element) else { return element }
            if let freshPath = fresh.applicationPath, freshPath != oldPath { relocatedApplicationPaths[oldPath] = freshPath }
            if fresh != element { modified = true }
            return fresh
        }
        let updated = profiles.map { profile -> DockProfile in
            var profile = profile
            profile.elements = profile.elements.map { element in
                guard element.kind == .folder else { return refresh(element) }
                var folder = element
                folder.children = folder.children.map(refresh)
                return folder
            }
            return profile
        }
        guard modified else { return }
        profiles = updated.map { DockProfile(id: $0.id, name: $0.name, elements: Self.normalized($0.elements)) }
        changed()
    }

    /// Bundle identifiers survive application updates and moves, unlike paths.
    @discardableResult
    func addFullscreenExclusion(_ bundleIdentifier: String) -> Bool {
        let updated = Self.exclusions(fullscreenExclusions + [bundleIdentifier])
        guard updated != fullscreenExclusions else { return false }
        fullscreenExclusions = updated
        changed()
        return true
    }

    func removeFullscreenExclusion(_ bundleIdentifier: String) {
        guard fullscreenExclusions.contains(bundleIdentifier) else { return }
        fullscreenExclusions.removeAll { $0 == bundleIdentifier }
        changed()
    }

    /// Most recent first. Recorded only while the recent section is enabled.
    func noteLaunchedApplication(_ path: String) {
        guard showRecentApplications, path.hasPrefix("/"), path.lowercased().hasSuffix(".app") else { return }
        let updated = Self.recent([path] + recentApplications)
        guard updated != recentApplications else { return }
        recentApplications = updated
        changed()
    }

    func clearRecentApplications() {
        guard !recentApplications.isEmpty else { return }
        recentApplications = []
        changed()
    }

    func toggleAutoHide() {
        visibility = visibility == .always ? .autoHide : .always
    }

    @discardableResult
    func addIntegration(_ id: String) -> Bool {
        guard let title = registeredTitles[id], !items.contains(where: { $0.integrationID == id }) else { return false }
        let spans = integrationSpans[id] ?? [1]
        let preferred = id == "music" || id == "calendar" ? 2 : 1
        return append(DockElement(id: "integration:\(id)", kind: .integration, title: title, integrationID: id,
                                  span: spans.contains(preferred) ? preferred : spans.first ?? 1))
    }

    /// Registry metadata is supplied by the app composition root, not stored in user profiles.
    func registerIntegration(id: String, title: String, supportedSpans: [Int]) {
        let widths = Array(Set(supportedSpans.filter { 1...12 ~= $0 })).sorted()
        guard !id.isEmpty, id.count <= 120, !widths.isEmpty else { return }
        registeredTitles[id] = Self.title(title, fallback: id)
        integrationSpans[id] = widths
    }

    func registerIntegrations(titles: [String: String], spans: [String: [Int]]) {
        for (id, title) in titles {
            registerIntegration(id: id, title: title, supportedSpans: spans[id] ?? [1])
        }
    }

    @discardableResult
    func addFolder(name: String) -> String {
        let folder = DockElement(kind: .folder, title: Self.title(name, fallback: "Папка"))
        _ = append(folder)
        return folder.id
    }

    @discardableResult
    func addStack(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue,
              canonical.pathExtension.lowercased() != "app",
              !items.contains(where: { $0.directoryPath == canonical.path }) else { return false }
        return append(DockElement(id: "stack:\(canonical.path)", kind: .stack,
                                  title: canonical.lastPathComponent, directoryPath: canonical.path))
    }

    func remove(id: String) {
        edit { elements in
            if let index = elements.firstIndex(where: { $0.id == id && $0.kind == .folder }) {
                let children = elements[index].children
                elements.replaceSubrange(index...index, with: children)
                return
            }
            elements.removeAll { $0.id == id }
            for index in elements.indices { elements[index].children.removeAll { $0.id == id } }
        }
    }

    func rename(id: String, title: String) {
        edit { elements in
            for index in elements.indices {
                if elements[index].id == id { elements[index].title = Self.title(title, fallback: elements[index].title) }
                if let child = elements[index].children.firstIndex(where: { $0.id == id }) {
                    elements[index].children[child].title = Self.title(title, fallback: elements[index].children[child].title)
                }
            }
        }
    }

    func supportedSpans(for element: DockElement) -> [Int] {
        guard element.kind == .integration, let id = element.integrationID else { return [1] }
        return Array(Set((integrationSpans[id] ?? [1]).filter { 1...12 ~= $0 })).sorted()
    }

    func setSpan(_ span: Int, for id: String) {
        guard let element = items.first(where: { $0.id == id }), supportedSpans(for: element).contains(span) else { return }
        edit { elements in if let index = elements.firstIndex(where: { $0.id == id }) { elements[index].span = span } }
    }

    func setOption(_ key: String, value: String, for id: String) {
        guard !key.isEmpty, key.count <= 120, value.count <= 2_000 else { return }
        edit { elements in
            if let index = elements.firstIndex(where: { $0.id == id }) { elements[index].options[key] = value }
            for index in elements.indices {
                if let child = elements[index].children.firstIndex(where: { $0.id == id }) { elements[index].children[child].options[key] = value }
            }
        }
    }

    /// Drop on the free part of the strip: the item becomes the last top-level element.
    func moveToEnd(id: String) {
        edit { elements in
            if let source = elements.firstIndex(where: { $0.id == id }) {
                elements.append(elements.remove(at: source))
                return
            }
            guard elements.count < 128 else { return }
            for folder in elements.indices {
                if let child = elements[folder].children.firstIndex(where: { $0.id == id }) {
                    elements.append(elements[folder].children.remove(at: child))
                    return
                }
            }
        }
    }

    func move(id: String, before targetID: String) {
        guard id != targetID else { return }
        edit { elements in
            if let source = elements.firstIndex(where: { $0.id == id }), elements.contains(where: { $0.id == targetID }) {
                let element = elements.remove(at: source)
                if let target = elements.firstIndex(where: { $0.id == targetID }) { elements.insert(element, at: target) }
                return
            }
            for folder in elements.indices {
                guard let source = elements[folder].children.firstIndex(where: { $0.id == id }),
                      elements[folder].children.contains(where: { $0.id == targetID }) else { continue }
                let child = elements[folder].children.remove(at: source)
                if let target = elements[folder].children.firstIndex(where: { $0.id == targetID }) { elements[folder].children.insert(child, at: target) }
                return
            }
        }
    }

    @discardableResult
    func group(_ id: String, with targetID: String) -> Bool {
        guard id != targetID, let source = items.first(where: { $0.id == id }),
              let target = items.first(where: { $0.id == targetID }), source.kind == .app else { return false }
        if target.kind == .folder { return moveIntoFolder(id, folderID: targetID) }
        guard target.kind == .app else { return false }
        edit { elements in
            elements.removeAll { $0.id == id }
            if let index = elements.firstIndex(where: { $0.id == targetID }) {
                elements[index] = DockElement(kind: .folder, title: "Папка", children: [target, source])
            }
        }
        return true
    }

    @discardableResult
    func moveIntoFolder(_ id: String, folderID: String) -> Bool {
        guard id != folderID, let folder = items.first(where: { $0.id == folderID }), folder.kind == .folder,
              folder.children.count < 128,
              let app = items.flatMap({ [$0] + $0.children }).first(where: { $0.id == id }), app.kind == .app,
              !folder.children.contains(where: { $0.id == id }) else { return false }
        edit { elements in
            elements.removeAll { $0.id == id }
            for index in elements.indices { elements[index].children.removeAll { $0.id == id } }
            if let index = elements.firstIndex(where: { $0.id == folderID }) { elements[index].children.append(app) }
        }
        return true
    }

    func moveOutOfFolder(_ id: String, before targetID: String? = nil) {
        guard items.count < 128,
              let app = items.flatMap(\.children).first(where: { $0.id == id }) else { return }
        edit { elements in
            for index in elements.indices { elements[index].children.removeAll { $0.id == id } }
            let destination = targetID.flatMap { target in elements.firstIndex(where: { $0.id == target }) } ?? elements.count
            elements.insert(app, at: destination)
        }
    }

    @discardableResult
    func createProfile(name: String, duplicateCurrent: Bool) -> String {
        guard profiles.count < 16 else { return activeProfileID }
        let profile = DockProfile(name: Self.title(name, fallback: "Профиль"), elements: duplicateCurrent ? items : [])
        profiles.append(profile)
        activeProfileID = profile.id
        changed()
        return profile.id
    }

    func selectProfile(_ id: String) {
        guard id != activeProfileID, profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        changed()
    }

    func renameProfile(_ id: String, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = Self.title(name, fallback: profiles[index].name)
        changed()
    }

    func removeProfile(_ id: String) {
        guard profiles.count > 1, profiles.contains(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = profiles[0].id }
        changed()
    }

    private func append(_ item: DockElement) -> Bool {
        guard items.count < 128 else { return false }
        edit { $0.append(item) }
        return true
    }

    private func edit(_ mutation: (inout [DockElement]) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        var elements = profiles[index].elements
        let occupiedFolders = Set(elements.filter { $0.kind == .folder && !$0.children.isEmpty }.map(\.id))
        mutation(&elements)
        elements.removeAll { $0.kind == .folder && $0.children.isEmpty && occupiedFolders.contains($0.id) }
        guard elements != profiles[index].elements else { return }
        profiles[index].elements = elements
        changed()
    }

    private func changed() {
        guard !isNormalizing else { return }
        isNormalizing = true
        // Assign only real corrections: every @Published write re-renders observers.
        let clampedScale = Self.clamp(scale, to: 0.7...1.4, fallback: 1)
        if clampedScale != scale { scale = clampedScale }
        let clampedOpacity = Self.clamp(opacity, to: 0.45...1, fallback: 0.88)
        if clampedOpacity != opacity { opacity = clampedOpacity }
        let clampedMagnification = Self.clamp(magnification, to: 0...1, fallback: 0.3)
        if clampedMagnification != magnification { magnification = clampedMagnification }
        if noteText.count > 2_000 { noteText = String(noteText.prefix(2_000)) }
        if !showRecentApplications, !recentApplications.isEmpty { recentApplications = [] }
        isNormalizing = false
        persist()
        onChange?()
    }

    private func persist() {
        let payload = Payload(isEnabled: isEnabled, visibility: visibility, scale: scale, opacity: opacity,
                              magnification: magnification, displayUUID: displayUUID, replaceSystemDock: replaceSystemDock,
                              previewEnabled: previewEnabled, noteText: noteText, profiles: profiles,
                              activeProfileID: activeProfileID, showAppLabels: showAppLabels,
                              showDownloads: showDownloads, showTrash: showTrash, downloadsSort: downloadsSort,
                              hideInFullscreenGames: hideInFullscreenGames, hideInFullscreenVideo: hideInFullscreenVideo,
                              fullscreenExclusions: fullscreenExclusions, position: position,
                              showRecentApplications: showRecentApplications, recentApplications: recentApplications,
                              animateLaunch: animateLaunch, dimHiddenApplications: dimHiddenApplications,
                              hideHotKeyEnabled: hideHotKeyEnabled, downloadsStyle: downloadsStyle,
                              showBadges: showBadges, showMinimizedWindows: showMinimizedWindows)
        if let data = try? JSONEncoder().encode(payload) { defaults.set(data, forKey: Self.storageKey) }
    }

    private static func clamp(_ number: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        number.isFinite ? min(max(number, range.lowerBound), range.upperBound) : fallback
    }

    private static func exclusions(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        let valid = identifiers.compactMap { identifier -> String? in
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 255, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        return Array(valid.prefix(128))
    }

    private static func recent(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return Array(paths.filter {
            $0.hasPrefix("/") && $0.count <= 1_024 && $0.lowercased().hasSuffix(".app") && seen.insert($0).inserted
        }.prefix(8))
    }

    private static func title(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(120))
    }

    private static var defaultItems: [DockElement] {
        [DockElement(id: "app:/System/Library/CoreServices/Finder.app", kind: .app, title: "Finder", applicationPath: "/System/Library/CoreServices/Finder.app")]
        + ["music", "calendar", "timer", "note"].map {
            DockElement(id: "integration:\($0)", kind: .integration, title: integrationTitles[$0] ?? $0,
                        integrationID: $0, span: $0 == "music" || $0 == "calendar" ? 2 : 1)
        }
    }

    private struct LegacyItem: Decodable {
        var kind: String
        var applicationPath: String?
        var title: String
        var size: String?
    }

    private static func migrate(_ defaults: UserDefaults) -> Payload {
        let oldItems = defaults.data(forKey: "nool.dock.items").flatMap { try? JSONDecoder().decode([LegacyItem].self, from: $0) }
        let elements = oldItems.map { old in
            normalized(old.compactMap { item in
                if item.kind == "app" {
                    return DockElement(kind: .app, title: item.title, applicationPath: item.applicationPath)
                }
                guard integrationTitles[item.kind] != nil else { return nil }
                return DockElement(kind: .integration, title: integrationTitles[item.kind] ?? item.kind,
                                   integrationID: item.kind, span: item.size == "compact" ? 1 : item.kind == "timer" ? 2 : 3)
            })
        } ?? defaultItems
        let profile = DockProfile(name: "Основной", elements: elements)
        let legacyDisplay = defaults.string(forKey: "nool.dock.displayID") ?? ""
        var uuid = ""
        if let displayID = UInt32(legacyDisplay), NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }), let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, cfUUID) as String
        } else if UUID(uuidString: legacyDisplay) != nil { uuid = legacyDisplay }
        return Payload(isEnabled: defaults.object(forKey: "nool.dock.enabled") as? Bool ?? false,
                       visibility: defaults.bool(forKey: "nool.dock.autoHide") ? .autoHide : .always,
                       scale: (defaults.object(forKey: "nool.dock.scale") as? NSNumber)?.doubleValue ?? 1,
                       opacity: (defaults.object(forKey: "nool.dock.opacity") as? NSNumber)?.doubleValue ?? 0.88,
                       magnification: 0.3, displayUUID: uuid, replaceSystemDock: false, previewEnabled: true,
                       noteText: defaults.string(forKey: "nool.dock.noteText") ?? "", profiles: [profile], activeProfileID: profile.id)
    }

    /// Normalize by structure, never by existence: removable-volume apps and folders stay pinned.
    private static func normalized(_ input: [DockElement]) -> [DockElement] {
        var apps = Set<String>(), integrations = Set<String>(), stacks = Set<String>(), ids = Set<String>()
        func app(_ candidate: DockElement) -> DockElement? {
            guard let resolved = DockApplicationBookmark.refreshed(candidate),
                  let path = resolved.applicationPath, apps.count < 128 else { return nil }
            let url = URL(fileURLWithPath: path)
            guard apps.insert(url.path).inserted else { return nil }
            return DockElement(id: "app:\(url.path)", kind: .app,
                               title: title(candidate.title, fallback: url.deletingPathExtension().lastPathComponent), applicationPath: url.path, options: resolved.options)
        }
        func flattenedApps(_ elements: [DockElement], depth: Int = 0) -> [DockElement] {
            guard depth < 8 else { return [] }
            return elements.prefix(128).flatMap { element -> [DockElement] in
                if element.kind == .folder { return flattenedApps(element.children, depth: depth + 1) }
                return element.kind == .app ? app(element).map { [$0] } ?? [] : []
            }
        }
        return input.prefix(512).compactMap { candidate in
            switch candidate.kind {
            case .app: return app(candidate)
            case .folder:
                let reserved = ["app:", "stack:", "integration:"].contains(where: { candidate.id.hasPrefix($0) })
                let id = candidate.id.isEmpty || reserved || ids.contains(candidate.id) ? UUID().uuidString : candidate.id
                ids.insert(id)
                return DockElement(id: id, kind: .folder, title: title(candidate.title, fallback: "Папка"), children: flattenedApps(candidate.children), options: candidate.options)
            case .stack:
                guard let path = candidate.directoryPath, path.hasPrefix("/") else { return nil }
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard stacks.insert(url.path).inserted else { return nil }
                return DockElement(id: "stack:\(url.path)", kind: .stack, title: title(candidate.title, fallback: url.lastPathComponent), directoryPath: url.path, options: candidate.options)
            case .integration:
                guard let id = candidate.integrationID, !id.isEmpty, integrations.insert(id).inserted else { return nil }
                // Keep future integration identifiers and spans, even when temporarily unavailable.
                return DockElement(id: "integration:\(id)", kind: .integration,
                                   title: title(candidate.title, fallback: integrationTitles[id] ?? id), integrationID: id,
                                   span: min(max(candidate.span, 1), 12), options: candidate.options)
            }
        }
    }
}
