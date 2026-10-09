import AppKit
import Foundation

@MainActor
protocol WorkspaceOpening: AnyObject {
    func openApplication(at url: URL) async -> Bool
    func open(_ url: URL) -> Bool
    func waitUntilApplicationsReady(_ entries: [WorkspaceEntry], timeout: TimeInterval) async -> Set<UUID>
}

@MainActor
final class SystemWorkspaceOpener: WorkspaceOpening {
    func openApplication(at url: URL) async -> Bool {
        let gate = WorkspaceOpenGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else { gate.resolve(false); return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                    gate.resolve(app != nil && error == nil)
                }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    gate.resolve(false)
                }
            }
        } onCancel: {
            gate.resolve(false)
        }
    }

    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    func waitUntilApplicationsReady(_ entries: [WorkspaceEntry], timeout: TimeInterval) async -> Set<UUID> {
        let deadline = Date().addingTimeInterval(timeout)
        var ready: Set<UUID> = []
        repeat {
            let running = NSWorkspace.shared.runningApplications
            for entry in entries where !ready.contains(entry.id) {
                let matches = running.filter { app in
                    if let bundleIdentifier = entry.bundleIdentifier { return app.bundleIdentifier == bundleIdentifier }
                    return app.bundleURL?.standardizedFileURL == entry.resolvedURL?.standardizedFileURL
                }
                if matches.contains(where: { $0.isFinishedLaunching && !$0.isTerminated }) { ready.insert(entry.id) }
            }
            if ready.count == entries.count || Date() >= deadline || Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while true
        return ready
    }
}

private final class WorkspaceOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var resolvedValue: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let resolvedValue {
            lock.unlock()
            continuation.resume(returning: resolvedValue)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard resolvedValue == nil else { lock.unlock(); return }
        resolvedValue = value
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

@MainActor
final class WorkspaceLauncher {
    private let opener: WorkspaceOpening
    private(set) var isLaunching = false
    private var cancellationGeneration = 0

    init(opener: WorkspaceOpening = SystemWorkspaceOpener()) { self.opener = opener }

    func launch(_ workspace: SavedWorkspace,
                restoreLayout: ((UUID) async -> String)? = nil) async -> WorkspaceLaunchReport {
        guard !isLaunching else {
            return WorkspaceLaunchReport(workspaceName: workspace.name, status: .busy, openedCount: 0,
                                         totalCount: workspace.entries.count, failures: [], readinessWarnings: [],
                                         layoutMessage: nil)
        }
        isLaunching = true
        defer { isLaunching = false }
        let generation = cancellationGeneration

        var openedCount = 0
        var failures: [WorkspaceLaunchFailure] = []
        var launchedApplications: [WorkspaceEntry] = []

        for entry in workspace.entries {
            guard !Task.isCancelled, generation == cancellationGeneration else {
                return WorkspaceLaunchReport(workspaceName: workspace.name, status: .cancelled,
                                             openedCount: openedCount, totalCount: workspace.entries.count,
                                             failures: failures, readinessWarnings: [], layoutMessage: nil)
            }
            guard let url = entry.resolvedURL else {
                failures.append(.init(entryTitle: entry.title, reason: "адрес больше недоступен"))
                continue
            }
            let access = entry.kind == .folder ? SecurityScopedResource(url: url) : nil
            guard entry.matchesResolvedType(url) else {
                access?.endAccess()
                failures.append(.init(entryTitle: entry.title, reason: "тип ресурса изменился или он недоступен"))
                continue
            }
            let opened: Bool
            if entry.kind == .application {
                opened = await opener.openApplication(at: url)
                if opened { launchedApplications.append(entry) }
            } else {
                opened = opener.open(url)
            }
            access?.endAccess()
            if opened { openedCount += 1 }
            else { failures.append(.init(entryTitle: entry.title, reason: "не удалось открыть")) }
        }

        guard !Task.isCancelled, generation == cancellationGeneration else {
            return WorkspaceLaunchReport(workspaceName: workspace.name, status: .cancelled,
                                         openedCount: openedCount, totalCount: workspace.entries.count,
                                         failures: failures, readinessWarnings: [], layoutMessage: nil)
        }
        let ready = await opener.waitUntilApplicationsReady(launchedApplications, timeout: 4)
        let readinessWarnings = launchedApplications.filter { !ready.contains($0.id) }.map(\.title)

        guard !Task.isCancelled, generation == cancellationGeneration else {
            return WorkspaceLaunchReport(workspaceName: workspace.name, status: .cancelled,
                                         openedCount: openedCount, totalCount: workspace.entries.count,
                                         failures: failures, readinessWarnings: readinessWarnings, layoutMessage: nil)
        }
        let layoutMessage: String?
        if let id = workspace.windowLayoutID, let restoreLayout {
            layoutMessage = await restoreLayout(id)
        } else {
            layoutMessage = nil
        }
        return WorkspaceLaunchReport(workspaceName: workspace.name, status: .completed,
                                     openedCount: openedCount, totalCount: workspace.entries.count,
                                     failures: failures, readinessWarnings: readinessWarnings,
                                     layoutMessage: layoutMessage)
    }

    func stop() { cancellationGeneration += 1 }
}
