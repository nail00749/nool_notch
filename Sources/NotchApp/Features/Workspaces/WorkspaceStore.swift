import Combine
import Foundation

enum WorkspaceSaveResult: Equatable {
    case saved
    case rejected(String)
}

@MainActor
final class WorkspaceStore: ObservableObject {
    private static let defaultsKey = "nool.workspaces.v1"
    private let defaults: UserDefaults

    @Published private(set) var workspaces: [SavedWorkspace]
    @Published private(set) var lastLaunchReport: WorkspaceLaunchReport?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([SavedWorkspace].self, from: $0) } ?? []
        var seen: Set<UUID> = []
        var names: Set<String> = []
        workspaces = decoded.compactMap { candidate in
            guard let workspace = candidate.validated(), seen.insert(workspace.id).inserted else { return nil }
            let key = workspace.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard names.insert(key).inserted else { return nil }
            return workspace
        }
        .prefix(SavedWorkspace.maximumCount)
        .map { $0 }
        if workspaces != decoded { persist() }
    }

    func workspace(id: UUID) -> SavedWorkspace? { workspaces.first { $0.id == id } }

    @discardableResult
    func save(_ candidate: SavedWorkspace) -> WorkspaceSaveResult {
        guard let workspace = candidate.validated() else {
            return .rejected("Введите название и добавьте от 1 до 20 приложений, папок или сайтов.")
        }
        let duplicateName = workspaces.contains {
            $0.id != workspace.id && $0.name.localizedCaseInsensitiveCompare(workspace.name) == .orderedSame
        }
        guard !duplicateName else { return .rejected("Рабочее пространство с таким названием уже существует.") }
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            guard workspaces.count < SavedWorkspace.maximumCount else {
                return .rejected("Можно сохранить не более 20 рабочих пространств.")
            }
            workspaces.append(workspace)
        }
        workspaces.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        return .saved
    }

    func remove(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        workspaces.removeAll { $0.id == id }
        persist()
    }

    func record(_ report: WorkspaceLaunchReport) { lastLaunchReport = report }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
