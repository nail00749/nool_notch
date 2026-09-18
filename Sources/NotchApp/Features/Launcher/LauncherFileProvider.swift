import Combine
import Foundation

@MainActor
final class LauncherFileProvider: ObservableObject {
    static let maximumResultCount = 80
    private static let debounceNanoseconds: UInt64 = 180_000_000
    private static let queryTimeoutNanoseconds: UInt64 = 3_000_000_000

    @Published private(set) var results: [LauncherResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?
    private var querySession: MetadataQuerySession?
    private var activeSearchID: UUID?

    func search(query: String, folders: [URL]) {
        stop()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            results = []
            errorMessage = nil
            return
        }

        let scopes = Self.searchScopes(for: folders)
        guard scopes.isEmpty == false else {
            results = []
            errorMessage = "Выберите хотя бы одну папку для поиска файлов."
            return
        }

        isSearching = true
        errorMessage = nil
        let searchID = UUID()
        activeSearchID = searchID
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false, let self else { return }
            await self.runSearch(query: trimmedQuery, scopes: scopes, searchID: searchID)
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        querySession?.cancel()
        querySession = nil
        activeSearchID = nil
        isSearching = false
        results = []
    }

    static func predicate(for query: String) -> NSPredicate {
        NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, query)
    }

    static func searchScopes(for folders: [URL]) -> [URL] {
        var seen: Set<String> = []
        return folders.compactMap { folder in
            guard folder.isFileURL else { return nil }
            let standardFolder = folder.standardizedFileURL
            guard seen.insert(standardFolder.path).inserted else { return nil }
            return standardFolder
        }
    }

    nonisolated static func availableSearchScopes(for scopes: [URL]) throws -> [URL] {
        var availableScopes: [URL] = []
        for url in scopes {
            try Task.checkCancellation()
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            availableScopes.append(url)
        }
        return availableScopes
    }

    private func runSearch(query: String, scopes: [URL], searchID: UUID) async {
        guard Task.isCancelled == false else { return }

        let scopeValidation = Task.detached(priority: .userInitiated) {
            try Self.availableSearchScopes(for: scopes)
        }
        let availableScopes: [URL]
        do {
            availableScopes = try await withTaskCancellationHandler(
                operation: { try await scopeValidation.value },
                onCancel: { scopeValidation.cancel() }
            )
        } catch is CancellationError {
            return
        } catch {
            finishWithError("Не удалось проверить выбранные папки.", searchID: searchID)
            return
        }

        guard Task.isCancelled == false, activeSearchID == searchID, searchTask != nil else { return }
        guard availableScopes.isEmpty == false else {
            finishWithError("Выбранные папки больше не доступны.", searchID: searchID)
            return
        }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = availableScopes
        metadataQuery.predicate = Self.predicate(for: query)
        metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

        let session = MetadataQuerySession(
            query: metadataQuery,
            maximumResultCount: Self.maximumResultCount,
            timeoutNanoseconds: Self.queryTimeoutNanoseconds
        )
        querySession = session
        let outcome = await session.collect()

        guard Task.isCancelled == false,
              activeSearchID == searchID,
              querySession === session,
              searchTask != nil else { return }
        querySession = nil
        searchTask = nil
        activeSearchID = nil
        isSearching = false
        switch outcome {
        case .results(let found):
            results = found
            errorMessage = found.isEmpty ? "Ничего не найдено в выбранных папках." : nil
        case .startFailed:
            errorMessage = "Не удалось запустить поиск файлов."
        case .timedOut:
            errorMessage = "Поиск файлов занял слишком много времени."
        case .cancelled:
            break
        }
    }

    private func finishWithError(_ message: String, searchID: UUID) {
        guard activeSearchID == searchID, searchTask != nil else { return }
        searchTask = nil
        activeSearchID = nil
        isSearching = false
        errorMessage = message
    }
}

@MainActor
private final class MetadataQuerySession {
    enum Outcome {
        case results([LauncherResult])
        case startFailed
        case timedOut
        case cancelled
    }

    private let query: NSMetadataQuery
    private let maximumResultCount: Int
    private let timeoutNanoseconds: UInt64
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var completionObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(query: NSMetadataQuery, maximumResultCount: Int, timeoutNanoseconds: UInt64) {
        self.query = query
        self.maximumResultCount = maximumResultCount
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func collect() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            completionObserver = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finish(.results([]))
                }
            }

            guard query.start() else {
                finish(.startFailed)
                return
            }
            let timeoutNanoseconds = self.timeoutNanoseconds
            timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                self?.finish(.timedOut)
            }
        }
    }

    func cancel() {
        query.stop()
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        guard isFinished == false else { return }
        isFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        query.disableUpdates()
        let results: [LauncherResult] = if case .results = outcome { makeResults() } else { [] }
        query.stop()
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
            self.completionObserver = nil
        }
        let resolvedOutcome: Outcome
        if case .results = outcome {
            resolvedOutcome = .results(results)
        } else {
            resolvedOutcome = outcome
        }
        continuation?.resume(returning: resolvedOutcome)
        continuation = nil
    }

    private func makeResults() -> [LauncherResult] {
        var seen: Set<String> = []
        var results: [LauncherResult] = []

        for index in 0..<min(query.resultCount, maximumResultCount) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  url.isFileURL else { continue }
            let standardURL = url.standardizedFileURL
            guard seen.insert(standardURL.path).inserted else { continue }
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String)
                ?? standardURL.lastPathComponent
            results.append(LauncherResult(
                id: "file:\(standardURL.path)",
                title: name,
                subtitle: standardURL.deletingLastPathComponent().path,
                payload: .file(standardURL)
            ))
        }

        return results
    }
}
