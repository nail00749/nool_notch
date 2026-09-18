import AppKit
import Combine
import Foundation
import ImageIO

struct LauncherClipboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String?
    let imageData: Data?
    let createdAt: Date

    var title: String {
        guard let text, text.isEmpty == false else { return "Изображение" }
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count > 96 ? String(normalized.prefix(95)) + "…" : normalized
    }

    var subtitle: String {
        if text != nil, imageData != nil { return "Текст и изображение" }
        return text != nil ? "Текст в буфере" : "Изображение в буфере"
    }
}

/// An opt-in, local-only clipboard history. The launcher owns any explicit
/// Accessibility-backed paste; this store only copies a selected item.
@MainActor
final class LauncherClipboardStore: ObservableObject {
    nonisolated static let defaultLimit = 100
    nonisolated static let defaultRetentionDays = 7
    nonisolated static let maximumItemBytes = 5 * 1024 * 1024
    nonisolated static let maximumTotalBytes = 50 * 1024 * 1024

    nonisolated private static let maximumItemCount = 1_000
    nonisolated private static let maximumRetentionDays = 3_650
    // Binary image data is base64 in JSON (about 4/3 its size); escaped text
    // can grow further. This remains a finite corrupt-file cap while accepting
    // a valid full 50 MB history.
    nonisolated private static let maximumPersistedFileBytes = 128 * 1024 * 1024
    nonisolated private static let maximumImagePixels: Int64 = 40_000_000
    nonisolated private static let pollInterval: TimeInterval = 0.75

    @Published private(set) var items: [LauncherClipboardItem] = []
    @Published private(set) var errorMessage: String?

    private let persistenceURL: URL
    private let pasteboard: NSPasteboard
    private let persistenceQueue = DispatchQueue(label: "app.nool.notch.launcher-clipboard.persistence")
    private var isEnabled = false
    private var isLoadingHistory = false
    private var hasLoadedHistory = false
    private var itemLimit = defaultLimit
    private var retentionDays = defaultRetentionDays
    private var lastChangeCount: Int?
    private var pollTimer: Timer?
    private var isMonitoring = false
    private var lifecycleGeneration = 0
    private var persistenceGeneration = 0
    private var pendingPersistenceOperations = 0
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistenceURL: URL = LauncherClipboardStore.defaultPersistenceURL(),
        pasteboard: NSPasteboard = .general
    ) {
        self.persistenceURL = persistenceURL
        self.pasteboard = pasteboard
    }

    func configure(enabled: Bool, limit: Int, retentionDays: Int) {
        itemLimit = min(max(limit, 1), Self.maximumItemCount)
        self.retentionDays = min(max(retentionDays, 1), Self.maximumRetentionDays)

        guard enabled else {
            isEnabled = false
            lifecycleGeneration += 1
            isLoadingHistory = false
            hasLoadedHistory = false
            stop()
            clear()
            return
        }

        let needsLoad = isEnabled == false || hasLoadedHistory == false
        isEnabled = true
        isMonitoring = true
        if needsLoad {
            lifecycleGeneration += 1
            isLoadingHistory = true
            loadHistory(generation: lifecycleGeneration)
            return
        }

        trimItems(now: Date())
        enqueuePersistence()
        startPolling()
    }

    func clear() {
        items = []
        errorMessage = nil
        lastChangeCount = pasteboard.changeCount
        lifecycleGeneration += 1
        isLoadingHistory = false
        hasLoadedHistory = true
        enqueueDeletion()
    }

    @discardableResult
    func copy(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else {
            errorMessage = "Элемент буфера больше недоступен."
            return false
        }

        pasteboard.clearContents()
        var didWrite = false
        if let text = item.text {
            didWrite = pasteboard.setString(text, forType: .string) || didWrite
        }
        if let imageData = item.imageData {
            didWrite = pasteboard.setData(imageData, forType: .tiff) || didWrite
        }
        guard didWrite else {
            errorMessage = "Не удалось скопировать элемент буфера."
            return false
        }

        lastChangeCount = pasteboard.changeCount
        errorMessage = nil
        return true
    }

    /// Polling calls this method; tests may call it after explicitly opting in.
    func captureIfChanged() {
        guard isEnabled, isMonitoring, isLoadingHistory == false else { return }

        let now = Date()
        let hadExpiredItems = trimItems(now: now)
        if hadExpiredItems { enqueuePersistence() }

        let changeCount = pasteboard.changeCount
        guard lastChangeCount != changeCount else { return }
        lastChangeCount = changeCount

        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.isEmpty == false, shouldIgnore(pasteboardItems) == false else { return }

        let text = pasteboard.string(forType: .string)
        let imageData = normalizedImageData()
        // The pasteboard can change between its type/privacy check and payload
        // reads. Never retain a payload from that newer, uninspected generation.
        guard pasteboard.changeCount == changeCount else { return }
        guard (text?.isEmpty == false) || imageData != nil else { return }
        guard Self.byteCount(text: text, imageData: imageData) <= Self.maximumItemBytes else {
            errorMessage = "Содержимое буфера превышает допустимый размер."
            return
        }
        if let mostRecent = items.first,
           mostRecent.text == text,
           mostRecent.imageData == imageData {
            return
        }

        items.insert(
            LauncherClipboardItem(id: UUID(), text: text, imageData: imageData, createdAt: now),
            at: 0
        )
        trimItems(now: now)
        errorMessage = nil
        enqueuePersistence()
    }

    /// Stops polling without revoking consent or erasing the retained history.
    func stop() {
        isMonitoring = false
        isLoadingHistory = false
        lifecycleGeneration += 1
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Allows focused tests to await all pending background load/write/delete work.
    func waitForPersistence() async {
        guard pendingPersistenceOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            persistenceWaiters.append(continuation)
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.captureIfChanged()
            }
        }
    }

    private func loadHistory(generation: Int) {
        let persistenceURL = persistenceURL
        let itemLimit = itemLimit
        let retentionDays = retentionDays
        beginPersistenceOperation()
        persistenceQueue.async { [weak self] in
            let result = LauncherClipboardStore.readHistory(
                at: persistenceURL,
                itemLimit: itemLimit,
                retentionDays: retentionDays,
                now: Date()
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.isEnabled,
                      self.isMonitoring,
                      self.lifecycleGeneration == generation else { return }
                self.isLoadingHistory = false
                self.hasLoadedHistory = true
                switch result {
                case let .success(items, requiresRewrite):
                    self.items = items
                    self.errorMessage = nil
                    if requiresRewrite {
                        self.enqueuePersistence()
                    }
                case .failure:
                    self.items = []
                    self.errorMessage = "Не удалось прочитать историю буфера."
                }
                self.startPolling()
                self.lastChangeCount = nil
                self.captureIfChanged()
            }
        }
    }

    private func enqueuePersistence() {
        let snapshot = items
        let persistenceURL = persistenceURL
        persistenceGeneration += 1
        let generation = persistenceGeneration
        beginPersistenceOperation()
        persistenceQueue.async { [weak self] in
            let didPersist = LauncherClipboardStore.write(snapshot, to: persistenceURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.persistenceGeneration == generation else { return }
                if didPersist == false {
                    self.errorMessage = "Не удалось сохранить историю буфера."
                }
            }
        }
    }

    private func enqueueDeletion() {
        let persistenceURL = persistenceURL
        persistenceGeneration += 1
        let generation = persistenceGeneration
        beginPersistenceOperation()
        persistenceQueue.async { [weak self] in
            let didDelete = LauncherClipboardStore.deleteHistory(at: persistenceURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.persistenceGeneration == generation else { return }
                if didDelete == false {
                    self.errorMessage = "Не удалось очистить историю буфера."
                }
            }
        }
    }

    private func beginPersistenceOperation() {
        pendingPersistenceOperations += 1
    }

    private func finishPersistenceOperation() {
        pendingPersistenceOperations -= 1
        guard pendingPersistenceOperations == 0 else { return }
        let waiters = persistenceWaiters
        persistenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    @discardableResult
    private func trimItems(now: Date) -> Bool {
        let originalItems = items
        items = Self.trimmedItems(
            originalItems,
            itemLimit: itemLimit,
            retentionDays: retentionDays,
            now: now
        )
        return originalItems != items
    }

    private func normalizedImageData() -> Data? {
        if let tiffData = pasteboard.data(forType: .tiff), Self.isSafeImageData(tiffData) {
            return tiffData
        }
        guard let pngData = pasteboard.data(forType: .png), Self.isSafeImageData(pngData),
              let image = NSImage(data: pngData), let tiffData = image.tiffRepresentation,
              Self.isSafeImageData(tiffData) else {
            return nil
        }
        return tiffData
    }

    private func shouldIgnore(_ pasteboardItems: [NSPasteboardItem]) -> Bool {
        let typeNames = pasteboardItems.flatMap(\.types).map { $0.rawValue.lowercased() }
        return typeNames.contains { type in
            switch type {
            case "org.nspasteboard.concealedtype",
                 "org.nspasteboard.transienttype",
                 "org.nspasteboard.autogeneratedtype",
                 "com.apple.password-manager",
                 "com.apple.passwordmanager":
                return true
            default:
                return type.contains("1password") ||
                    type.contains("lastpass") ||
                    type.contains("bitwarden") ||
                    type.contains("keepass") ||
                    type.contains("passwordmanager")
            }
        }
    }

    nonisolated private static func readHistory(
        at url: URL,
        itemLimit: Int,
        retentionDays: Int,
        now: Date
    ) -> ClipboardLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return .success(items: [], requiresRewrite: false)
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue >= 0,
                  size.intValue <= maximumPersistedFileBytes else {
                return .failure
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumPersistedFileBytes else { return .failure }
            let decoded = try JSONDecoder().decode([LauncherClipboardItem].self, from: data)
            guard decoded.count <= maximumItemCount else { return .failure }
            let retained = trimmedItems(
                decoded,
                itemLimit: itemLimit,
                retentionDays: retentionDays,
                now: now
            )
            return .success(items: retained, requiresRewrite: retained != decoded)
        } catch {
            return .failure
        }
    }

    nonisolated private static func write(_ items: [LauncherClipboardItem], to url: URL) -> Bool {
        do {
            let fileManager = FileManager.default
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directoryURL.path)
            let data = try JSONEncoder().encode(items)
            guard data.count <= maximumPersistedFileBytes else { return false }
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func deleteHistory(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func trimmedItems(
        _ items: [LauncherClipboardItem],
        itemLimit: Int,
        retentionDays: Int,
        now: Date
    ) -> [LauncherClipboardItem] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var retained: [LauncherClipboardItem] = []
        var knownIDs = Set<UUID>()
        var totalBytes = 0

        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let itemBytes = byteCount(text: item.text, imageData: item.imageData)
            guard knownIDs.insert(item.id).inserted,
                  (item.text?.isEmpty == false) || item.imageData != nil,
                  item.createdAt >= cutoff,
                  item.createdAt <= now.addingTimeInterval(60),
                  itemBytes <= maximumItemBytes,
                  item.imageData.map(isSafeImageData) ?? true,
                  retained.count < itemLimit,
                  totalBytes + itemBytes <= maximumTotalBytes else {
                continue
            }
            retained.append(item)
            totalBytes += itemBytes
        }
        return retained
    }

    nonisolated private static func isSafeImageData(_ data: Data) -> Bool {
        guard data.isEmpty == false,
              data.count <= maximumItemBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        let pixelWidth = Int64(width.intValue)
        let pixelHeight = Int64(height.intValue)
        guard pixelWidth > 0, pixelHeight > 0, pixelWidth <= maximumImagePixels else { return false }
        return pixelHeight <= maximumImagePixels / pixelWidth
    }

    nonisolated private static func byteCount(text: String?, imageData: Data?) -> Int {
        (text?.lengthOfBytes(using: .utf8) ?? 0) + (imageData?.count ?? 0)
    }

    nonisolated private static func defaultPersistenceURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("Nool Notch", isDirectory: true)
            .appendingPathComponent("launcher-clipboard.json", isDirectory: false)
    }
}

private enum ClipboardLoadResult: Sendable {
    case success(items: [LauncherClipboardItem], requiresRewrite: Bool)
    case failure
}
