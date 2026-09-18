import Combine
import Foundation

struct LauncherSnippet: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let text: String
    let createdAt: Date
}

/// A local collection saved only through an explicit Launcher action. It is
/// deliberately independent from opt-in clipboard monitoring and its history.
@MainActor
final class LauncherSnippetStore: ObservableObject {
    nonisolated static let maximumItemCount = 100
    nonisolated static let maximumTextCharacters = 12_000

    @Published private(set) var items: [LauncherSnippet] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private let persistenceURL: URL?
    private let persistenceQueue = DispatchQueue(label: "app.nool.notch.launcher-snippets.persistence")
    private var persistenceGeneration = 0
    private var pendingPersistenceOperations = 0
    private var persistenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var persistenceBlocked = false

    init(url: URL? = LauncherSnippetStore.defaultPersistenceURL()) {
        persistenceURL = url
        guard let url else { return }
        isLoading = true
        load(from: url)
    }

    @discardableResult
    func save(text: String) -> Bool {
        guard isLoading == false else {
            errorMessage = "Шаблоны ещё загружаются. Повторите через мгновение."
            return false
        }
        guard persistenceBlocked == false else {
            errorMessage = "Не удалось прочитать сохранённые шаблоны. Исходный файл оставлен без изменений."
            return false
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            errorMessage = "Нельзя сохранить пустой шаблон."
            return false
        }
        guard text.count <= Self.maximumTextCharacters else {
            errorMessage = "Текст шаблона не должен превышать \(Self.maximumTextCharacters) символов."
            return false
        }
        if items.contains(where: { $0.text == text }) {
            errorMessage = nil
            return true
        }
        guard items.count < Self.maximumItemCount else {
            errorMessage = "Можно сохранить не более \(Self.maximumItemCount) шаблонов."
            return false
        }

        items.insert(
            LauncherSnippet(id: UUID(), title: Self.title(for: text), text: text, createdAt: .now),
            at: 0
        )
        errorMessage = nil
        enqueuePersistence()
        return true
    }

    func remove(id: UUID) {
        guard isLoading == false else {
            errorMessage = "Шаблоны ещё загружаются. Повторите через мгновение."
            return
        }
        guard persistenceBlocked == false else {
            errorMessage = "Не удалось прочитать сохранённые шаблоны. Исходный файл оставлен без изменений."
            return
        }
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        errorMessage = nil
        enqueuePersistence()
    }

    /// Allows the normal application shutdown path and focused tests to await
    /// all pending load and write work.
    func waitForPersistence() async {
        guard pendingPersistenceOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            persistenceWaiters.append(continuation)
        }
    }

    private func load(from url: URL) {
        beginPersistenceOperation()
        persistenceQueue.async { [weak self] in
            let result = LauncherSnippetDisk.load(from: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                self.isLoading = false
                switch result {
                case .success(let items):
                    self.items = items
                    self.errorMessage = nil
                case .corrupt:
                    self.persistenceBlocked = true
                    self.items = []
                    self.errorMessage = "Не удалось прочитать сохранённые шаблоны. Исходный файл оставлен без изменений."
                }
            }
        }
    }

    private func enqueuePersistence() {
        guard let persistenceURL else { return }
        let snapshot = items
        persistenceGeneration += 1
        let generation = persistenceGeneration
        beginPersistenceOperation()
        persistenceQueue.async { [weak self] in
            let didPersist = LauncherSnippetDisk.write(snapshot, to: persistenceURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishPersistenceOperation() }
                guard self.persistenceGeneration == generation else { return }
                if didPersist == false {
                    self.errorMessage = "Не удалось сохранить шаблоны."
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

    nonisolated fileprivate static func title(for text: String) -> String {
        let firstLine = text.split(
            maxSplits: .max,
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
            .first
            .map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "Шаблон" }
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    private static func defaultPersistenceURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nool Notch", isDirectory: true)
            .appendingPathComponent("launcher-snippets.json", isDirectory: false)
    }
}

private enum LauncherSnippetDisk {
    static let maximumPersistedFileBytes = 8 * 1024 * 1024

    static func load(from url: URL) -> LauncherSnippetLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .success([]) }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue >= 0,
                  size.intValue <= maximumPersistedFileBytes else {
                return .corrupt
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumPersistedFileBytes else { return .corrupt }
            let items = try JSONDecoder().decode([LauncherSnippet].self, from: data)
            guard validate(items) else { return .corrupt }
            return .success(items)
        } catch {
            return .corrupt
        }
    }

    static func write(_ items: [LauncherSnippet], to url: URL) -> Bool {
        guard validate(items) else { return false }
        do {
            let fileManager = FileManager.default
            let directoryURL = url.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directoryURL.path
            )
            let data = try JSONEncoder().encode(items)
            guard data.count <= maximumPersistedFileBytes else { return false }
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    private static func validate(_ items: [LauncherSnippet]) -> Bool {
        guard items.count <= LauncherSnippetStore.maximumItemCount else { return false }
        var knownIDs = Set<UUID>()
        var knownTexts = Set<String>()
        return items.allSatisfy { item in
            knownIDs.insert(item.id).inserted
                && knownTexts.insert(item.text).inserted
                && item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && item.text.count <= LauncherSnippetStore.maximumTextCharacters
                && item.title == LauncherSnippetStore.title(for: item.text)
        }
    }
}

private enum LauncherSnippetLoadResult: Sendable {
    case success([LauncherSnippet])
    case corrupt
}
