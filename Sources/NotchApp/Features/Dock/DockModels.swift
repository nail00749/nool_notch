import Foundation

enum DockElementKind: String, Codable, CaseIterable, Sendable {
    case app, folder, stack, integration
}

enum DockVisibilityMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case always, autoHide, intelligent

    var id: Self { self }
    var title: String {
        switch self {
        case .always: "Всегда виден"
        case .autoHide: "Автоскрытие"
        case .intelligent: "Умное скрытие"
        }
    }
}

struct DockElement: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var kind: DockElementKind
    var title: String
    var applicationPath: String?
    var directoryPath: String?
    var integrationID: String?
    var span: Int
    var children: [DockElement]
    var options: [String: String]

    init(id: String = UUID().uuidString, kind: DockElementKind, title: String = "",
         applicationPath: String? = nil, directoryPath: String? = nil,
         integrationID: String? = nil, span: Int = 1, children: [DockElement] = [], options: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationPath = applicationPath
        self.directoryPath = directoryPath
        self.integrationID = integrationID
        self.span = span
        self.children = children
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, applicationPath, directoryPath, integrationID, span, children, options
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try values.decode(DockElementKind.self, forKey: .kind)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        applicationPath = try values.decodeIfPresent(String.self, forKey: .applicationPath)
        directoryPath = try values.decodeIfPresent(String.self, forKey: .directoryPath)
        integrationID = try values.decodeIfPresent(String.self, forKey: .integrationID)
        span = try values.decodeIfPresent(Int.self, forKey: .span) ?? 1
        children = try values.decodeIfPresent([DockElement].self, forKey: .children) ?? []
        options = try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
    }

    var applicationPaths: Set<String> {
        switch kind {
        case .app: applicationPath.map { Set([$0]) } ?? []
        case .folder: Set(children.flatMap { $0.applicationPaths })
        case .stack, .integration: []
        }
    }
}

struct DockProfile: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var elements: [DockElement]

    init(id: String = UUID().uuidString, name: String, elements: [DockElement] = []) {
        self.id = id
        self.name = name
        self.elements = elements
    }
}

/// Ordinary file-identity bookmarks follow a moved bundle without requesting
/// security-scoped access, displaying UI, or mounting an unavailable volume.
enum DockApplicationBookmark {
    static let optionKey = "appBookmark"

    static func refreshed(_ candidate: DockElement) -> DockElement? {
        guard candidate.kind == .app, let path = candidate.applicationPath, path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let encoded = candidate.options[optionKey]
        var bookmarkWasResolved = false
        var stale = false
        if let encoded, encoded.utf8.count <= 1_000_000, let data = Data(base64Encoded: encoded),
           let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale),
           resolved.isFileURL, resolved.pathExtension.lowercased() == "app" {
            url = resolved.standardizedFileURL
            bookmarkWasResolved = true
        }
        // A temporarily missing application keeps its original pin and bookmark.
        // Resolving symlinks only for an existing bundle avoids rewriting an offline path.
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        if exists { url = url.resolvingSymlinksInPath() }
        var result = candidate
        result.applicationPath = url.path
        result.id = "app:\(url.path)"
        result.span = 1
        result.children = []
        if exists, (!bookmarkWasResolved || stale),
           let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            result.options[optionKey] = data.base64EncodedString()
        }
        return result
    }
}

enum DockPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom, left, right

    var id: Self { self }
    var title: String {
        switch self {
        case .bottom: "Снизу"
        case .left: "Слева"
        case .right: "Справа"
        }
    }
    var isVertical: Bool { self != .bottom }
    var edgeDescription: String {
        switch self {
        case .bottom: "нижнему"
        case .left: "левому"
        case .right: "правому"
        }
    }
}

/// Stack presentation: the Dock fan plus Finder's icon, list, column and gallery views.
/// Automatic picks a fan for short bottom stacks, like the system Dock.
enum DockStackStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, fan, grid, list, columns, gallery

    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Автоматически"
        case .fan: "Веер"
        case .grid: "Значки"
        case .list: "Список"
        case .columns: "Колонки"
        case .gallery: "Галерея"
        }
    }

    func resolved(itemCount: Int, position: DockPosition) -> DockStackStyle {
        switch self {
        case .automatic: position == .bottom && itemCount <= 10 ? .fan : .grid
        case .fan: position == .bottom ? .fan : .grid
        case .grid, .list, .columns, .gallery: self
        }
    }
}

struct DockRecentApplication: Identifiable, Equatable, Sendable {
    var id: String { path }
    var path: String
    var title: String
}
