import AppKit
import ImageIO
import Combine

struct RecentCapture: Identifiable, @unchecked Sendable {
    var id: URL { url }
    let url: URL
    let date: Date
    let fileSize: Int
    let thumbnail: CGImage
}

struct RecentCaptureScan: @unchecked Sendable {
    let items: [RecentCapture]
    let isPartial: Bool
}

// A worker keeps access alive until its last read, even if the panel closes.
private final class CaptureFolderAccess: @unchecked Sendable {
    let resource: SecurityScopedResource
    init(_ url: URL) { resource = SecurityScopedResource(url: url) }
}

enum RecentCaptureScanner {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]
    static let maximumFileSize = 30 * 1024 * 1024

    static func scan(folder: URL, entryLimit: Int = 5_000, itemLimit: Int = 40, cachedItems: [RecentCapture] = [], decodeLimit: Int = 80) throws -> RecentCaptureScan {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var candidates: [(URL, Date, Int)] = []
        var count = 0
        var partial = false
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if count >= entryLimit { partial = true; break }
            count += 1
            guard extensions.contains(url.pathExtension.lowercased()),
                  url.deletingLastPathComponent().standardizedFileURL == root,
                  url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == root,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= maximumFileSize else { continue }
            candidates.append((url, values.contentModificationDate ?? values.creationDate ?? .distantPast, size))
        }
        if let enumerationError { throw enumerationError }
        candidates.sort { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.lastPathComponent < rhs.0.lastPathComponent : lhs.1 > rhs.1
        }
        var items: [RecentCapture] = []
        var decodeAttempts = 0
        let cached = Dictionary(cachedItems.prefix(40).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for (url, date, fileSize) in candidates {
            try Task.checkCancellation()
            if let previous = cached[url], previous.date == date, previous.fileSize == fileSize {
                items.append(previous)
                if items.count >= itemLimit { break }
                continue
            }
            if decodeAttempts >= decodeLimit { partial = true; break }
            decodeAttempts += 1
            guard let current = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  current.isRegularFile == true, current.isSymbolicLink != true,
                  let currentSize = current.fileSize, currentSize > 0, currentSize <= maximumFileSize,
                  url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent() == root else { continue }
            // Decode a bounded thumbnail; do not load the full image into AppKit.
            let thumbnail: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            if let thumbnail { items.append(RecentCapture(url: url, date: date, fileSize: fileSize, thumbnail: thumbnail)) }
            if items.count >= itemLimit { break }
        }
        return RecentCaptureScan(items: items, isPartial: partial)
    }
}

@MainActor
final class RecentCapturesStore: ObservableObject {
    static let bookmarkKey = "recentCaptures.folderBookmark"
    @Published private(set) var items: [RecentCapture] = []
    @Published private(set) var folderURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPartial = false
    private let defaults: UserDefaults
    private var isActive = false
    private var didRestore = false
    private var generation = 0
    private var access: CaptureFolderAccess?
    private var scanTask: Task<RecentCaptureScan, Error>?
    private var pollTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static var suggestedFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if !active {
            generation += 1
            scanTask?.cancel()
            scanTask = nil
            pollTask?.cancel()
            pollTask = nil
            access = nil
            isLoading = false
            items = []
            return
        }
        restoreFolderIfNeeded()
        if let folderURL { access = CaptureFolderAccess(folderURL) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func chooseFolder(_ url: URL) async {
        let newAccess = CaptureFolderAccess(url)
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            didRestore = true
            folderURL = url
            access = isActive ? newAccess : nil
            items = []
            errorMessage = nil
            await refresh()
        } catch { errorMessage = "Не удалось открыть папку. Выберите её ещё раз." }
    }

    func forgetFolder() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        access = nil
        folderURL = nil
        didRestore = true
        defaults.removeObject(forKey: Self.bookmarkKey)
        items = []
        isPartial = false
        isLoading = false
        errorMessage = nil
    }

    func refresh() async {
        guard isActive, let folderURL, let access else { return }
        generation += 1
        let currentGeneration = generation
        scanTask?.cancel()
        isLoading = items.isEmpty
        let cachedItems = items
        let worker = Task.detached(priority: .utility) { [access] in
            defer { withExtendedLifetime(access) {} }
            return try RecentCaptureScanner.scan(folder: folderURL, cachedItems: cachedItems)
        }
        scanTask = worker
        do {
            let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard isActive, currentGeneration == generation, !Task.isCancelled else { return }
            items = result.items
            isPartial = result.isPartial
            errorMessage = nil
        } catch {
            guard isActive, currentGeneration == generation, !Task.isCancelled else { return }
            if !(error is CancellationError) { errorMessage = "Не удалось прочитать папку. Проверьте доступ или выберите другую." }
        }
        guard currentGeneration == generation else { return }
        isLoading = false
        scanTask = nil
    }

    private func restoreFolderIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            folderURL = url
            if stale {
                let lease = CaptureFolderAccess(url)
                defer { withExtendedLifetime(lease) {} }
                defaults.set(try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), forKey: Self.bookmarkKey)
            }
        } catch { errorMessage = "Доступ к сохранённой папке устарел. Выберите её ещё раз." }
    }
}
