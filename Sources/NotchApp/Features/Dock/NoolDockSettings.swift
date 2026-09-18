import Combine
import CoreGraphics
import Foundation

enum NoolDockItemKind: String, CaseIterable, Codable, Identifiable {
    case app
    case music
    case calendar
    case timer
    case note

    var id: Self { self }

    var title: String {
        switch self {
        case .app: "Приложение"
        case .music: "Музыка"
        case .calendar: "Календарь"
        case .timer: "Таймер"
        case .note: "Заметка"
        }
    }

    var systemImage: String {
        switch self {
        case .app: "app.fill"
        case .music: "music.note"
        case .calendar: "calendar"
        case .timer: "timer"
        case .note: "note.text"
        }
    }

    var isWidget: Bool { self != .app }
}

enum NoolDockItemSize: String, CaseIterable, Codable, Identifiable {
    case compact
    case regular

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Компактный"
        case .regular: "Обычный"
        }
    }
}

struct NoolDockItem: Codable, Identifiable, Equatable {
    let id: String
    let kind: NoolDockItemKind
    let applicationPath: String?
    let title: String
    let size: NoolDockItemSize

    var baseWidth: CGFloat {
        switch (kind, size) {
        case (.app, .regular): 56
        case (.music, .regular): 260
        case (.calendar, .regular): 230
        case (.timer, .regular): 200
        case (.note, .regular): 220
        case (.app, .compact): 48
        case (.music, .compact): 210
        case (.calendar, .compact): 185
        case (.timer, .compact): 165
        case (.note, .compact): 175
        }
    }
}

@MainActor
final class NoolDockSettings: ObservableObject {
    private enum Key {
        static let prefix = "nool.dock."
        static let enabled = prefix + "enabled"
        static let scale = prefix + "scale"
        static let opacity = prefix + "opacity"
        static let autoHide = prefix + "autoHide"
        static let displayID = prefix + "displayID"
        static let noteText = prefix + "noteText"
        static let items = prefix + "items"
    }

    private static let scaleRange = 0.8 ... 1.2
    private static let opacityRange = 0.55 ... 1.0
    private static let noteTextLimit = 2_000
    private static let applicationLimit = 24
    private static let finderPath = "/System/Library/CoreServices/Finder.app"

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            persist(isEnabled, forKey: Key.enabled)
        }
    }

    @Published var scale: Double {
        didSet {
            guard scale != oldValue else { return }
            persistClampedScale()
        }
    }

    @Published var opacity: Double {
        didSet {
            guard opacity != oldValue else { return }
            persistClampedOpacity()
        }
    }

    @Published var autoHide: Bool {
        didSet {
            guard autoHide != oldValue else { return }
            persist(autoHide, forKey: Key.autoHide)
        }
    }

    @Published var displayID: String {
        didSet {
            guard displayID != oldValue else { return }
            persist(displayID, forKey: Key.displayID)
        }
    }

    @Published var noteText: String {
        didSet {
            guard noteText != oldValue else { return }
            persistTruncatedNoteText()
        }
    }

    @Published private(set) var items: [NoolDockItem] {
        didSet {
            guard items != oldValue else { return }
            persistItems()
        }
    }

    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        scale = Self.clampedScale(Self.number(forKey: Key.scale, defaults: defaults, fallback: 1.0))
        opacity = Self.clampedOpacity(Self.number(forKey: Key.opacity, defaults: defaults, fallback: 0.92))
        autoHide = defaults.object(forKey: Key.autoHide) as? Bool ?? false
        displayID = defaults.string(forKey: Key.displayID) ?? ""
        noteText = Self.truncated(defaults.string(forKey: Key.noteText) ?? "")

        let storedItems = defaults.data(forKey: Key.items)
            .flatMap { try? JSONDecoder().decode([NoolDockItem].self, from: $0) }
        items = storedItems.map(Self.normalizedItems) ?? Self.defaultItems()

        // Keep a repaired payload after decoding old or malformed preferences.
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(scale, forKey: Key.scale)
        defaults.set(opacity, forKey: Key.opacity)
        defaults.set(autoHide, forKey: Key.autoHide)
        defaults.set(displayID, forKey: Key.displayID)
        defaults.set(noteText, forKey: Key.noteText)
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Key.items)
        }
    }

    @discardableResult
    func addApplication(_ url: URL) -> Bool {
        guard let app = Self.applicationItem(for: url),
              items.filter({ $0.kind == .app }).count < Self.applicationLimit,
              items.contains(where: { $0.applicationPath == app.applicationPath }) == false
        else { return false }

        items.append(app)
        return true
    }

    @discardableResult
    func addWidget(_ kind: NoolDockItemKind) -> Bool {
        guard kind.isWidget,
              items.contains(where: { $0.kind == kind }) == false
        else { return false }

        items.append(Self.widgetItem(kind))
        return true
    }

    func remove(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
    }

    func move(id: String, before targetID: String) {
        guard id != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == targetID })
        else { return }

        var updated = items
        let item = updated.remove(at: sourceIndex)
        guard let destinationIndex = updated.firstIndex(where: { $0.id == targetID }) else { return }
        updated.insert(item, at: destinationIndex)
        items = updated
    }

    func move(id: String, by offset: Int) {
        guard offset != 0,
              let sourceIndex = items.firstIndex(where: { $0.id == id })
        else { return }

        let destinationIndex = min(max(sourceIndex + offset, 0), items.count - 1)
        guard destinationIndex != sourceIndex else { return }
        var updated = items
        let item = updated.remove(at: sourceIndex)
        updated.insert(item, at: destinationIndex)
        items = updated
    }

    func setSize(_ size: NoolDockItemSize, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].size != size
        else { return }

        let item = items[index]
        items[index] = NoolDockItem(
            id: item.id,
            kind: item.kind,
            applicationPath: item.applicationPath,
            title: item.title,
            size: size
        )
    }

    private func persistClampedScale() {
        let normalized = Self.clampedScale(scale)
        guard normalized == scale else {
            scale = normalized
            return
        }
        persist(scale, forKey: Key.scale)
    }

    private func persistClampedOpacity() {
        let normalized = Self.clampedOpacity(opacity)
        guard normalized == opacity else {
            opacity = normalized
            return
        }
        persist(opacity, forKey: Key.opacity)
    }

    private func persistTruncatedNoteText() {
        let normalized = Self.truncated(noteText)
        guard normalized == noteText else {
            noteText = normalized
            return
        }
        persist(noteText, forKey: Key.noteText)
    }

    private func persist<T>(_ value: T, forKey key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }

    private func persistItems() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Key.items)
        onChange?()
    }

    private static func clampedScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.92 }
        return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
    }

    private static func number(forKey key: String, defaults: UserDefaults, fallback: Double) -> Double {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }

    private static func truncated(_ text: String) -> String {
        String(text.prefix(noteTextLimit))
    }

    private static func defaultItems() -> [NoolDockItem] {
        [
            NoolDockItem(
                id: applicationID(for: finderPath),
                kind: .app,
                applicationPath: finderPath,
                title: "Finder",
                size: .regular
            ),
            widgetItem(.music),
            widgetItem(.calendar),
            widgetItem(.timer),
            widgetItem(.note)
        ]
    }

    private static func widgetItem(_ kind: NoolDockItemKind) -> NoolDockItem {
        NoolDockItem(
            id: kind.rawValue,
            kind: kind,
            applicationPath: nil,
            title: kind.title,
            size: .regular
        )
    }

    private static func applicationItem(for url: URL) -> NoolDockItem? {
        guard url.isFileURL else { return nil }
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.pathExtension.lowercased() == "app" else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: resolvedURL)
        else { return nil }

        let title = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? resolvedURL.deletingPathExtension().lastPathComponent
        let path = resolvedURL.path
        return NoolDockItem(
            id: applicationID(for: path),
            kind: .app,
            applicationPath: path,
            title: title.isEmpty ? resolvedURL.deletingPathExtension().lastPathComponent : title,
            size: .regular
        )
    }

    private static func applicationID(for path: String) -> String {
        "app:\(path)"
    }

    /// Saved applications can live on a removable volume. Keep a structurally valid
    /// entry while it is unavailable; activation can report the missing app later.
    private static func savedApplicationItem(from candidate: NoolDockItem) -> NoolDockItem? {
        guard let rawPath = candidate.applicationPath,
              rawPath.hasPrefix("/"),
              rawPath.isEmpty == false
        else { return nil }

        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let savedTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = savedTitle.isEmpty ? fallbackTitle : truncated(savedTitle)
        return NoolDockItem(
            id: applicationID(for: url.path),
            kind: .app,
            applicationPath: url.path,
            title: title,
            size: candidate.size
        )
    }

    private static func normalizedItems(_ candidates: [NoolDockItem]) -> [NoolDockItem] {
        var normalized: [NoolDockItem] = []
        var applicationPaths = Set<String>()
        var widgets = Set<NoolDockItemKind>()

        for candidate in candidates {
            switch candidate.kind {
            case .app:
                guard let item = savedApplicationItem(from: candidate),
                      let normalizedPath = item.applicationPath,
                      applicationPaths.insert(normalizedPath).inserted,
                      normalized.filter({ $0.kind == .app }).count < applicationLimit
                else { continue }
                normalized.append(item)
            case .music, .calendar, .timer, .note:
                guard widgets.insert(candidate.kind).inserted else { continue }
                normalized.append(NoolDockItem(
                    id: candidate.kind.rawValue,
                    kind: candidate.kind,
                    applicationPath: nil,
                    title: candidate.kind.title,
                    size: candidate.size
                ))
            }
        }
        return normalized
    }
}
