import Combine
import Foundation

/// Coordinates code-review snapshots for the repository workspaces represented
/// by Agent Inbox sessions. It has no navigation side effects.
@MainActor
final class CodeReviewStore: ObservableObject {
    @Published private(set) var codeReviewStates: [AISessionID: CodeReviewLoadState] = [:]
    @Published private(set) var newReviewActivityCounts: [AISessionID: Int] = [:]
    @Published private(set) var codeReviewsUpdatedAt: Date?

    private let provider: any CodeReviewProviding
    private var sessions: [AISession] = []
    private var isVisible = false
    private var codeReviewTasks: [AISessionID: Task<Void, Never>] = [:]
    private var codeReviewGenerations: [AISessionID: UUID] = [:]
    private var codeReviewWorkspacePaths: [AISessionID: String] = [:]
    private var pollingTask: Task<Void, Never>?
    private var pollingGeneration: UUID?
    private var lifecycleGeneration = UUID()
    private var reviewActivityBaselines: [AISessionID: (requestID: String, ids: Set<String>)] = [:]

    init(provider: any CodeReviewProviding = LocalCodeReviewProvider()) {
        self.provider = provider
    }

    var codeReviewSessions: [AISession] {
        let repositories = sessions.filter { $0.workspacePath?.isEmpty == false }
        let ordered = repositories.filter(\.status.isActive)
            + repositories.filter { $0.status.isActive == false }.prefix(3)
        var seenWorkspaces: Set<String> = []
        return ordered.filter { session in
            guard let workspacePath = session.workspacePath else { return false }
            return seenWorkspaces.insert(workspacePath).inserted
        }
    }

    func updateSessions(_ sessions: [AISession]) {
        self.sessions = sessions
        reconcileCodeReviews()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible

        if visible {
            refreshCodeReviews()
            startPolling()
        } else {
            stopPolling()
            cancelInFlightReviews()
        }
    }

    func refreshCodeReviews() {
        for session in codeReviewSessions {
            refreshCodeReview(for: session)
        }
    }

    func codeReviewState(for session: AISession) -> CodeReviewLoadState {
        if let direct = codeReviewStates[session.id] {
            return direct
        }
        guard let representativeID = codeReviewRepresentativeID(for: session) else {
            return .idle
        }
        return codeReviewStates[representativeID] ?? .idle
    }

    func newReviewActivityCount(for session: AISession) -> Int {
        if let direct = newReviewActivityCounts[session.id] {
            return direct
        }
        guard let representativeID = codeReviewRepresentativeID(for: session) else {
            return 0
        }
        return newReviewActivityCounts[representativeID, default: 0]
    }

    func acknowledgeReviewActivity(for session: AISession) {
        let representativeID = codeReviewRepresentativeID(for: session) ?? session.id
        newReviewActivityCounts[representativeID] = 0
    }

    func stop() {
        lifecycleGeneration = UUID()
        isVisible = false
        stopPolling()
        cancelInFlightReviews()
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        let generation = UUID()
        pollingGeneration = generation
        pollingTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard Task.isCancelled == false,
                      let self,
                      self.isVisible,
                      self.pollingGeneration == generation else {
                    return
                }
                self.refreshCodeReviews()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        pollingGeneration = nil
    }

    private func cancelInFlightReviews() {
        for task in codeReviewTasks.values {
            task.cancel()
        }
        codeReviewTasks.removeAll()
        codeReviewGenerations.removeAll()
    }

    private func refreshCodeReview(for session: AISession) {
        guard let workspacePath = session.workspacePath,
              workspacePath.isEmpty == false,
              codeReviewTasks[session.id] == nil else { return }

        let previous = codeReviewStates[session.id]?.snapshot
        codeReviewStates[session.id] = .loading(previous: previous)
        codeReviewWorkspacePaths[session.id] = workspacePath
        let generation = UUID()
        let lifecycleGeneration = self.lifecycleGeneration
        codeReviewGenerations[session.id] = generation
        let provider = self.provider

        codeReviewTasks[session.id] = Task { @MainActor [weak self, provider] in
            let result = await provider.load(workspacePath: workspacePath)
            guard Task.isCancelled == false,
                  let self,
                  self.lifecycleGeneration == lifecycleGeneration,
                  self.codeReviewGenerations[session.id] == generation else {
                return
            }

            self.codeReviewTasks[session.id] = nil
            self.codeReviewGenerations[session.id] = nil
            guard self.sessions.contains(where: {
                      $0.id == session.id && $0.workspacePath == workspacePath
                  }) else {
                return
            }

            switch result {
            case .success(let snapshot):
                self.recordReviewActivity(snapshot.request, for: session.id)
                self.codeReviewStates[session.id] = .loaded(snapshot)
                self.codeReviewsUpdatedAt = .now
            case .failure(let error):
                self.codeReviewStates[session.id] = .failed(error, previous: previous)
            }
        }
    }

    private func recordReviewActivity(_ request: CodeReviewRequest?, for sessionID: AISessionID) {
        guard let request else {
            reviewActivityBaselines.removeValue(forKey: sessionID)
            newReviewActivityCounts.removeValue(forKey: sessionID)
            return
        }
        guard let baseline = reviewActivityBaselines[sessionID], baseline.requestID == request.id else {
            reviewActivityBaselines[sessionID] = (request.id, request.reviewerActivityIDs)
            newReviewActivityCounts[sessionID] = 0
            return
        }
        let newIDs = request.reviewerActivityIDs.subtracting(baseline.ids)
        if newIDs.isEmpty == false {
            newReviewActivityCounts[sessionID, default: 0] += newIDs.count
        }
        reviewActivityBaselines[sessionID] = (
            request.id,
            baseline.ids.union(request.reviewerActivityIDs)
        )
    }

    private func codeReviewRepresentativeID(for session: AISession) -> AISessionID? {
        guard let workspacePath = session.workspacePath else { return nil }
        return codeReviewSessions.first {
            $0.workspacePath == workspacePath
        }?.id
    }

    private func reconcileCodeReviews() {
        let visibleSessions = codeReviewSessions
        let visibleIDs = Set(visibleSessions.map(\.id))
        for id in Array(codeReviewStates.keys) where visibleIDs.contains(id) == false {
            codeReviewTasks[id]?.cancel()
            codeReviewTasks.removeValue(forKey: id)
            codeReviewGenerations.removeValue(forKey: id)
            codeReviewStates.removeValue(forKey: id)
            codeReviewWorkspacePaths.removeValue(forKey: id)
            reviewActivityBaselines.removeValue(forKey: id)
            newReviewActivityCounts.removeValue(forKey: id)
        }

        for session in visibleSessions {
            guard let workspacePath = session.workspacePath, workspacePath.isEmpty == false else {
                continue
            }
            guard let loadedPath = codeReviewWorkspacePaths[session.id],
                  loadedPath != workspacePath else { continue }
            codeReviewTasks[session.id]?.cancel()
            codeReviewTasks.removeValue(forKey: session.id)
            codeReviewGenerations.removeValue(forKey: session.id)
            codeReviewStates.removeValue(forKey: session.id)
            codeReviewWorkspacePaths.removeValue(forKey: session.id)
            reviewActivityBaselines.removeValue(forKey: session.id)
            newReviewActivityCounts.removeValue(forKey: session.id)
        }

        guard isVisible else { return }
        for session in visibleSessions where codeReviewStates[session.id] == nil {
            refreshCodeReview(for: session)
        }
    }
}
