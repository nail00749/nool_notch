import Darwin
import Foundation

struct WorkspaceEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case application
        case folder
        case website
    }

    let id: UUID
    let kind: Kind
    var title: String
    let urlString: String
    let bookmarkData: Data?
    let bundleIdentifier: String?

    init(id: UUID = UUID(), kind: Kind, title: String, urlString: String,
         bookmarkData: Data? = nil, bundleIdentifier: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.urlString = urlString
        self.bookmarkData = bookmarkData
        self.bundleIdentifier = bundleIdentifier
    }

    static func application(url: URL) -> WorkspaceEntry? {
        let url = url.standardizedFileURL
        guard url.isFileURL, url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        let title = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.deletingPathExtension().lastPathComponent
        return WorkspaceEntry(kind: .application, title: title, urlString: url.absoluteString,
                              bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
    }

    static func folder(url: URL) -> WorkspaceEntry? {
        let url = url.standardizedFileURL
        guard url.isFileURL else { return nil }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        let title = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.lastPathComponent
        return WorkspaceEntry(kind: .folder, title: title, urlString: url.absoluteString,
                              bookmarkData: bookmark)
    }

    static func website(_ value: String) -> WorkspaceEntry? {
        guard let url = validatedWebURL(value) else { return nil }
        let title = url.host(percentEncoded: false) ?? url.absoluteString
        return WorkspaceEntry(kind: .website, title: title, urlString: url.absoluteString)
    }

    var resolvedURL: URL? {
        if kind == .folder, let bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url.standardizedFileURL
            }
        }
        guard let url = URL(string: urlString) else { return nil }
        switch kind {
        case .application: return url.standardizedFileURL
        case .folder: return Self.validatedFolderURL(url)
        case .website: return Self.validatedWebURL(url.absoluteString)
        }
    }

    func validated() -> WorkspaceEntry? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 80,
              !cleanTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: urlString) else { return nil }
        switch kind {
        case .application:
            guard url.isFileURL,
                  url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return nil }
        case .folder:
            guard Self.validatedFolderURL(url) != nil else { return nil }
        case .website:
            guard Self.validatedWebURL(url.absoluteString) != nil else { return nil }
        }
        return WorkspaceEntry(id: id, kind: kind, title: cleanTitle,
                              urlString: url.absoluteString, bookmarkData: bookmarkData,
                              bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil)
    }

    func matchesResolvedType(_ candidate: URL) -> Bool {
        switch kind {
        case .application:
            return candidate.isFileURL
                && candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        case .folder:
            guard candidate.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return false }
            guard let canonicalURL = Self.canonicalExistingURL(candidate) else { return false }
            return (try? canonicalURL.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        case .website:
            return Self.validatedWebURL(candidate.absoluteString) != nil
        }
    }

    private static func validatedWebURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        return components.url
    }

    private static func validatedFolderURL(_ candidate: URL) -> URL? {
        let url = candidate.standardizedFileURL
        guard url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return nil }
            guard let canonicalURL = canonicalExistingURL(url) else { return nil }
            if let isPackage = try? canonicalURL.resourceValues(forKeys: [.isPackageKey]).isPackage, isPackage == true {
                return nil
            }
        }
        return url
    }

    private static func canonicalExistingURL(_ url: URL) -> URL? {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = Darwin.realpath(path, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
        }
    }
}

struct SavedWorkspace: Codable, Identifiable, Equatable, Sendable {
    static let maximumCount = 20
    static let maximumEntries = 20

    let id: UUID
    var name: String
    var entries: [WorkspaceEntry]
    var windowLayoutID: UUID?

    init(id: UUID = UUID(), name: String, entries: [WorkspaceEntry], windowLayoutID: UUID? = nil) {
        self.id = id
        self.name = name
        self.entries = entries
        self.windowLayoutID = windowLayoutID
    }

    func validated() -> SavedWorkspace? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 40,
              !cleanName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !entries.isEmpty, entries.count <= Self.maximumEntries else { return nil }
        var seen: Set<UUID> = []
        let cleanEntries = entries.compactMap { entry -> WorkspaceEntry? in
            guard seen.insert(entry.id).inserted else { return nil }
            return entry.validated()
        }
        guard cleanEntries.count == entries.count else { return nil }
        return SavedWorkspace(id: id, name: cleanName, entries: cleanEntries, windowLayoutID: windowLayoutID)
    }
}

struct WorkspaceLaunchFailure: Equatable, Sendable {
    let entryTitle: String
    let reason: String
}

struct WorkspaceLaunchReport: Equatable, Sendable {
    enum Status: Equatable, Sendable { case completed, cancelled, busy }

    let workspaceName: String
    let status: Status
    let openedCount: Int
    let totalCount: Int
    let failures: [WorkspaceLaunchFailure]
    let readinessWarnings: [String]
    let layoutMessage: String?

    var summary: String {
        switch status {
        case .busy: return "Другое рабочее пространство уже запускается."
        case .cancelled: return "Запуск «\(workspaceName)» отменён: открыто \(openedCount) из \(totalCount)."
        case .completed:
            var parts = ["«\(workspaceName)»: открыто \(openedCount) из \(totalCount)."]
            if !failures.isEmpty {
                parts.append("Не удалось: " + failures.map { "\($0.entryTitle) — \($0.reason)" }.joined(separator: "; ") + ".")
            }
            if !readinessWarnings.isEmpty {
                parts.append("Не дождались запуска: " + readinessWarnings.joined(separator: ", ") + ".")
            }
            if let layoutMessage { parts.append(layoutMessage) }
            return parts.joined(separator: " ")
        }
    }
}
