import Foundation
import UniformTypeIdentifiers

@MainActor
final class FileShelfStore: ObservableObject {
    static let maximumItemCount = 20

    @Published private(set) var entries: [FileShelfItem] = []
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?
    private var activeImportCount = 0

    /// Called after an accepted drop has finished loading, including a drop that
    /// contained no usable file URLs. The owner can use it to resume collapse.
    var onImportCompleted: (() -> Void)?

    /// Convenience name for views that render the shelf as a list of files.
    var items: [FileShelfItem] { entries }

    @discardableResult
    func add(urls: [URL]) -> Int {
        var addedCount = 0
        var rejectedMissingFile = false
        var rejectedNonFileURL = false
        var reachedLimit = false

        for url in urls {
            guard url.isFileURL else {
                rejectedNonFileURL = true
                continue
            }
            let entry = FileShelfItem(url: url)

            guard FileManager.default.fileExists(atPath: entry.url.path) else {
                entry.endSecurityScopedAccess()
                rejectedMissingFile = true
                continue
            }

            guard entries.contains(where: { $0.id == entry.id }) == false else {
                entry.endSecurityScopedAccess()
                continue
            }

            guard entries.count < Self.maximumItemCount else {
                entry.endSecurityScopedAccess()
                reachedLimit = true
                continue
            }

            entries.append(entry)
            addedCount += 1
        }

        if rejectedNonFileURL {
            errorMessage = "Можно добавить только файлы с этого Mac."
        } else if rejectedMissingFile {
            errorMessage = "Один из файлов больше не доступен."
        } else if reachedLimit {
            errorMessage = "На полке можно держать до \(Self.maximumItemCount) файлов."
        } else if addedCount > 0 {
            errorMessage = nil
        }

        return addedCount
    }

    func remove(_ item: FileShelfItem) {
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = entries.remove(at: index)
        removed.endSecurityScopedAccess()
    }

    func dismissError() {
        errorMessage = nil
    }

    /// Starts asynchronous URL loading for a SwiftUI file drop.
    /// The returned value reports whether the providers were accepted for import.
    @discardableResult
    func acceptDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard fileProviders.isEmpty == false else {
            errorMessage = "Перетащите файл с этого Mac."
            return false
        }

        activeImportCount += 1
        isImporting = true
        errorMessage = nil

        Task { [weak self] in
            let urls = await Self.loadFileURLs(from: fileProviders)
            guard let self else { return }

            if urls.isEmpty {
                self.errorMessage = "Не удалось прочитать перетащенный файл."
            } else {
                self.add(urls: urls)
            }
            self.activeImportCount -= 1
            self.isImporting = self.activeImportCount > 0
            if self.isImporting == false {
                self.onImportCompleted?()
            }
        }

        return true
    }

    private static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: fileURL(from: item))
            }
        }
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url.isFileURL ? url : nil
        }
        if let url = item as? NSURL {
            let fileURL = url as URL
            return fileURL.isFileURL ? fileURL : nil
        }
        if let data = item as? Data {
            return fileURL(from: data)
        }
        return nil
    }

    nonisolated private static func fileURL(from data: Data) -> URL? {
        if let archivedURL = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
            let url = archivedURL as URL
            if url.isFileURL { return url }
        }

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.isFileURL {
                return url
            }
            if trimmed.hasPrefix("/") {
                return URL(fileURLWithPath: trimmed)
            }
        }

        guard let dataURL = URL(dataRepresentation: data, relativeTo: nil) else {
            return nil
        }
        return dataURL.isFileURL ? dataURL : nil
    }
}

final class FileShelfItem: Identifiable {
    let url: URL
    let standardizedURL: URL
    let id: String
    private var isAccessingSecurityScopedResource: Bool

    init(url: URL) {
        self.url = url
        self.standardizedURL = url.standardizedFileURL
        self.id = self.standardizedURL.path
        self.isAccessingSecurityScopedResource = self.url.startAccessingSecurityScopedResource()
    }

    func endSecurityScopedAccess() {
        guard isAccessingSecurityScopedResource else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessingSecurityScopedResource = false
    }

    deinit {
        endSecurityScopedAccess()
    }
}
