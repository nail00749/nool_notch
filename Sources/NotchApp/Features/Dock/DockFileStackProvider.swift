import AppKit
import Combine
import Quartz

enum DockStackSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case name, added, modified, kind
    var id: Self { self }
    var title: String {
        switch self {
        case .name: "По имени"
        case .added: "По дате добавления"
        case .modified: "По дате изменения"
        case .kind: "По типу"
        }
    }
}

struct DockStackFile: Identifiable, Equatable, Sendable {
    let url: URL
    let title: String
    let isDirectory: Bool
    let modifiedAt: Date?
    var addedAt: Date? = nil
    /// Bundles (.app, .pages) are folders on disk but open like files.
    var isPackage = false
    var id: String { url.path }
    var isBrowsable: Bool { isDirectory && !isPackage }
    var path: String { url.path }
}

/// Directory I/O never runs in the hosting view. A generation owns each result,
/// so opening another stack cannot publish files from an old request.
@MainActor
final class DockFileStackProvider: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var items: [DockStackFile] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasMore = false
    private var generation = 0
    private var allItems: [DockStackFile] = []
    private var worker: Task<[DockStackFile], Error>?
    private var quickLookWindow: NSPanel?
    private var quickLookView: QLPreviewView?
    private let pageSize = 80
    private var icons: [String: NSImage] = [:]

    func load(directory: URL, sort: DockStackSort = .modified) async {
        cancel()
        let token = generation
        isLoading = true
        errorMessage = nil
        defer {
            if token == generation { isLoading = false; worker = nil }
        }
        let work = Task.detached(priority: .userInitiated) {
            try Self.read(directory: directory, sort: sort)
        }
        worker = work
        do {
            let files = try await work.value
            guard token == generation, !Task.isCancelled else { return }
            allItems = files
            items = Array(files.prefix(pageSize))
            hasMore = files.count > items.count
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            if !(error is CancellationError) {
                errorMessage = "Не удалось прочитать папку: \(error.localizedDescription)"
            }
        }
    }

    func loadMore() async {
        guard hasMore else { return }
        items = Array(allItems.prefix(items.count + pageSize))
        hasMore = allItems.count > items.count
    }

    func cancel() {
        generation += 1
        worker?.cancel()
        worker = nil
        items = []
        allItems = []
        hasMore = false
        isLoading = false
        errorMessage = nil
        icons.removeAll()
    }

    func open(_ file: DockStackFile) {
        guard NSWorkspace.shared.open(file.url) else {
            errorMessage = "Не удалось открыть «\(file.title)»."
            return
        }
    }

    func reveal(_ file: DockStackFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func icon(for file: DockStackFile) -> NSImage {
        // The system icon is cheap and doesn't download cloud file contents. Plain files share
        // a per-type icon; folders and bundles (.app) can have their own, so they key by path.
        let fileExtension = file.url.pathExtension.lowercased()
        let key = file.isDirectory || fileExtension.isEmpty ? file.path : "type:" + fileExtension
        if let cached = icons[key] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: file.url.path)
        if icons.count < 128 { icons[key] = icon }
        return icon
    }

    func quickLook(_ file: DockStackFile) {
        quickLookView?.close()
        let window = quickLookWindow ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = file.title
        window.delegate = self
        let preview = QLPreviewView(frame: window.contentView?.bounds ?? .zero, style: .normal)
        preview?.autoresizingMask = [.width, .height]
        preview?.previewItem = file.url as NSURL
        preview?.shouldCloseWithWindow = true
        window.contentView = preview
        if quickLookWindow == nil { window.center() }
        quickLookWindow = window
        quickLookView = preview
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        quickLookView?.close()
        quickLookView = nil
        quickLookWindow = nil
    }

    func stop() {
        cancel()
        quickLookWindow?.close()
    }

    nonisolated static func read(directory: URL, sort: DockStackSort) throws -> [DockStackFile] {
        guard directory.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey,
                                         .addedToDirectoryDateKey, .nameKey]
        let failure = DockStackEnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { url, error in failure.record(url: url, error: error, root: directory) }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        // Bound work for pathological/network directories; do not recursively scan.
        var result: [DockStackFile] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if result.count >= 10_000 { break }
            let values = try? url.resourceValues(forKeys: keys)
            result.append(DockStackFile(url: url, title: values?.name ?? url.lastPathComponent,
                                        isDirectory: values?.isDirectory ?? false,
                                        modifiedAt: values?.contentModificationDate,
                                        addedAt: values?.addedToDirectoryDate,
                                        isPackage: values?.isPackage ?? false))
        }
        try Task.checkCancellation()
        // Errors surface only while iterating. An unreadable folder must not look empty;
        // a single unreadable entry is skipped like Finder does.
        if let error = failure.rootError { throw error }
        return result.sorted { lhs, rhs in
            switch sort {
            case .added:
                let a = lhs.addedAt ?? lhs.modifiedAt ?? .distantPast, b = rhs.addedAt ?? rhs.modifiedAt ?? .distantPast
                if a != b { return a > b }
            case .modified:
                let a = lhs.modifiedAt ?? .distantPast, b = rhs.modifiedAt ?? .distantPast
                if a != b { return a > b }
            case .kind:
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                if lhs.url.pathExtension != rhs.url.pathExtension {
                    return lhs.url.pathExtension.localizedStandardCompare(rhs.url.pathExtension) == .orderedAscending
                }
            case .name: break
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// Collects enumeration errors; the root folder failing stops enumeration, a child is skipped.
private final class DockStackEnumerationFailure: @unchecked Sendable {
    private(set) var rootError: Error?

    func record(url: URL, error: Error, root: URL) -> Bool {
        guard url.standardizedFileURL.path == root.standardizedFileURL.path else { return true }
        rootError = error
        return false
    }
}
