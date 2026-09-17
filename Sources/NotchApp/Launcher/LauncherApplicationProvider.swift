import AppKit
import Combine
import Foundation

@MainActor
final class LauncherApplicationProvider: ObservableObject {
    private static let cacheLifetime: TimeInterval = 30

    @Published private(set) var results: [LauncherResult] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var refreshTask: Task<[LauncherResult], Error>?
    private var activeRefreshID: UUID?
    private var lastUpdatedAt: Date?

    func refresh() async {
        if let lastUpdatedAt,
           Date().timeIntervalSince(lastUpdatedAt) < Self.cacheLifetime {
            return
        }

        if let refreshTask {
            do {
                _ = try await refreshTask.value
            } catch is CancellationError {
                // The launcher was closed while the last scan was running. A new
                // invocation should replace that cancelled single-flight task.
                guard Task.isCancelled == false else { return }
                self.refreshTask = nil
                activeRefreshID = nil
                isLoading = false
                await refresh()
            } catch {
                // The owner of the shared task publishes an actionable error.
            }
            return
        }

        let refreshID = UUID()
        let refreshTask = Task.detached(priority: .userInitiated) {
            try Self.discoverApplications()
        }
        self.refreshTask = refreshTask
        activeRefreshID = refreshID
        isLoading = true
        errorMessage = nil

        do {
            let discovered = try await withTaskCancellationHandler(
                operation: { try await refreshTask.value },
                onCancel: { refreshTask.cancel() }
            )
            guard activeRefreshID == refreshID else { return }
            results = discovered
            lastUpdatedAt = .now
        } catch is CancellationError {
            // A launcher that is closing has no need to surface a cancelled scan.
        } catch {
            if activeRefreshID == refreshID {
                errorMessage = "Не удалось загрузить список приложений."
            }
        }

        if activeRefreshID == refreshID {
            self.refreshTask = nil
            activeRefreshID = nil
            isLoading = false
        }
    }

    private nonisolated static func discoverApplications() throws -> [LauncherResult] {
        let fileManager = FileManager.default
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        var applications: [LauncherResult] = []
        var seenPaths: Set<String> = []
        let maximumApplicationCount = 3_000
        let maximumScannedApplicationCount = maximumApplicationCount - 1

        for directory in applicationDirectories where fileManager.fileExists(atPath: directory.path) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let standardURL = url.standardizedFileURL
                guard seenPaths.insert(standardURL.path).inserted else { continue }

                let values = try? standardURL.resourceValues(forKeys: resourceKeys)
                let title = values?.localizedName ?? standardURL.deletingPathExtension().lastPathComponent
                applications.append(LauncherResult(
                    id: "application:\(standardURL.path)",
                    title: title,
                    subtitle: standardURL.path,
                    payload: .application(standardURL)
                ))

                if applications.count >= maximumScannedApplicationCount { break }
            }
            if applications.count >= maximumScannedApplicationCount { break }
        }

        // Finder belongs in CoreServices rather than the normal application roots.
        // Include it directly without recursively walking system helper applications.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let standardFinderURL = finderURL.standardizedFileURL
        if fileManager.fileExists(atPath: standardFinderURL.path),
           seenPaths.insert(standardFinderURL.path).inserted {
            let values = try? standardFinderURL.resourceValues(forKeys: resourceKeys)
            let title = values?.localizedName ?? standardFinderURL.deletingPathExtension().lastPathComponent
            applications.append(LauncherResult(
                id: "application:\(standardFinderURL.path)",
                title: title,
                subtitle: standardFinderURL.path,
                payload: .application(standardFinderURL)
            ))
        }

        return applications.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
