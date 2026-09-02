import Foundation

@MainActor
final class JiraProvider: JiraProviding {
    private struct InFlightWorklog {
        let lifecycle: UInt
        let task: Task<Result<Void, JiraAPIError>, Never>
    }

    var onChange: ((JiraProviderState) -> Void)?

    private let client: JiraClientProtocol
    private let credentialStore: JiraCredentialStoring
    private let preferences: AppPreferencesStoring
    private let pollingInterval: TimeInterval
    private let pollingSleeper: @MainActor (TimeInterval) async -> Void

    private var state = JiraProviderState()
    private var isStarted = false
    private var isVisible = false
    private var refreshGeneration: UInt = 0
    private var pollingGeneration: UInt = 0
    private var lifecycleGeneration: UInt = 0
    private var transitionGenerations: [String: UInt] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var transitionTasks: [String: Task<Void, Never>] = [:]
    private var worklogTasks: [String: InFlightWorklog] = [:]
    private var pinnedCatalogTask: Task<Void, Never>?
    private var pinnedSourceTask: Task<Void, Never>?
    private var pinnedCatalogGeneration: UInt = 0
    private var pinnedSourceGeneration: UInt = 0

    init(
        client: JiraClientProtocol,
        credentialStore: JiraCredentialStoring,
        preferences: AppPreferencesStoring,
        pollingInterval: TimeInterval = 60,
        pollingSleeper: @escaping @MainActor (TimeInterval) async -> Void = { interval in
            try? await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.preferences = preferences
        self.pollingInterval = pollingInterval
        self.pollingSleeper = pollingSleeper
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        state.selectedProjectKeys = preferences.jiraSelectedProjectKeys
        state.pinned.containers = preferences.jiraPinnedContainers
        state.pinned.issues = preferences.jiraPinnedIssues
        normalizePinnedSelection()
        do {
            let baseURLText = preferences.jiraBaseURLString
            let token = try credentialStore.loadToken()
            if let baseURLText, parseBaseURL(baseURLText) == nil {
                state.connection = .failed(.invalidBaseURL)
            } else if baseURLText == nil || token == nil {
                state.connection = .notConfigured
            } else {
                state.connection = .ready
            }
        } catch {
            state.connection = .failed(.network)
        }
        publish()

        if isVisible, isConfigured {
            refresh()
            startPolling()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelRefreshAndPolling()
        cancelTransitionTasks()
        cancelPinnedTasks()
    }

    func setVisible(_ isVisible: Bool) {
        guard self.isVisible != isVisible else { return }
        self.isVisible = isVisible

        guard isVisible else {
            cancelRefreshAndPolling()
            return
        }
        guard isStarted, isConfigured else { return }
        refresh()
        startPolling()
    }

    func refresh() {
        guard isStarted, isVisible, isConfigured else { return }

        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else { return }
            configuration = resolved
        } catch {
            publishListFailure(Self.normalizedError(error))
            return
        }

        refreshTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let previous = currentIssues
        state.list = .loading(previous: previous)
        publish()

        let selectedKeys = state.selectedProjectKeys
        refreshTask = Task { [weak self, client] in
            do {
                let allIssuesPage = try await client.issues(
                    baseURL: configuration.baseURL,
                    token: configuration.token,
                    projectKeys: []
                )
                let projects = Self.taskProjects(from: allIssuesPage.issues)
                let availableKeys = Set(projects.map(\.key))
                let validSelectedKeys = selectedKeys.intersection(availableKeys)
                let page: JiraSearchPage
                if validSelectedKeys.isEmpty {
                    page = allIssuesPage
                } else {
                    page = try await client.issues(
                        baseURL: configuration.baseURL,
                        token: configuration.token,
                        projectKeys: validSelectedKeys
                    )
                }
                guard let self,
                      self.isStarted,
                      self.isVisible,
                      self.refreshGeneration == generation else { return }
                self.state.projects = projects
                if self.state.selectedProjectKeys != validSelectedKeys {
                    self.state.selectedProjectKeys = validSelectedKeys
                    self.preferences.jiraSelectedProjectKeys = validSelectedKeys
                }
                self.state.list = .loaded(issues: page.issues, total: page.total)
                self.publish()
            } catch {
                guard let self,
                      self.isStarted,
                      self.isVisible,
                      self.refreshGeneration == generation else { return }
                self.publishListFailure(Self.normalizedError(error), previous: previous)
            }
        }
    }

    func checkConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        guard let baseURL = parseBaseURL(baseURLText) else {
            return .failure(.invalidBaseURL)
        }
        do {
            return .success(try await client.currentUser(baseURL: baseURL, token: token))
        } catch {
            return .failure(Self.normalizedError(error))
        }
    }

    func connect(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError> {
        guard let baseURL = parseBaseURL(baseURLText) else {
            return .failure(.invalidBaseURL)
        }

        let user: JiraUser
        do {
            user = try await client.currentUser(baseURL: baseURL, token: token)
        } catch {
            return .failure(Self.normalizedError(error))
        }

        do {
            try credentialStore.saveToken(token)
        } catch {
            return .failure(.network)
        }

        cancelRefreshAndPolling()
        cancelTransitionTasks()
        cancelPinnedTasks()

        preferences.jiraBaseURLString = baseURLText
        state.selectedProjectKeys = preferences.jiraSelectedProjectKeys
        state.connection = .connected(user)
        publish()

        if isStarted, isVisible {
            refresh()
            startPolling()
        }
        return .success(user)
    }

    func disconnect() {
        cancelRefreshAndPolling()
        cancelTransitionTasks()
        cancelPinnedTasks()
        do {
            try credentialStore.deleteToken()
        } catch {
            state.connection = .failed(.network)
            publish()
            return
        }
        preferences.jiraBaseURLString = nil
        preferences.jiraSelectedProjectKeys = []
        state = JiraProviderState(
            pinned: JiraPinnedState(
                containers: preferences.jiraPinnedContainers,
                issues: preferences.jiraPinnedIssues
            )
        )
        normalizePinnedSelection()
        publish()
    }

    func setSelectedProjectKeys(_ keys: Set<String>) {
        preferences.jiraSelectedProjectKeys = keys
        state.selectedProjectKeys = keys
        publish()
        if isStarted, isVisible, isConfigured {
            refresh()
        }
    }

    func refreshPinnedCatalog() {
        guard isStarted, isConfigured else { return }

        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else { return }
            configuration = resolved
        } catch {
            state.pinned.catalog = .failed(
                error: Self.normalizedError(error),
                previousProjects: state.pinned.catalog.projects,
                previousBoards: state.pinned.catalog.boards
            )
            publish()
            return
        }

        pinnedCatalogTask?.cancel()
        pinnedCatalogGeneration &+= 1
        let generation = pinnedCatalogGeneration
        let previousProjects = state.pinned.catalog.projects
        let previousBoards = state.pinned.catalog.boards
        state.pinned.catalog = .loading(
            previousProjects: previousProjects,
            previousBoards: previousBoards
        )
        publish()

        pinnedCatalogTask = Task { [weak self, client] in
            do {
                let projects = try await client.projects(
                    baseURL: configuration.baseURL,
                    token: configuration.token
                )
                let boards = try await client.boards(
                    baseURL: configuration.baseURL,
                    token: configuration.token
                )
                guard let self,
                      self.pinnedCatalogGeneration == generation else { return }
                self.state.pinned.catalog = .loaded(projects: projects, boards: boards)
                self.pinnedCatalogTask = nil
                self.publish()
            } catch {
                guard let self,
                      self.pinnedCatalogGeneration == generation else { return }
                let normalized = Self.normalizedError(error)
                self.state.pinned.catalog = .failed(
                    error: normalized,
                    previousProjects: previousProjects,
                    previousBoards: previousBoards
                )
                self.pinnedCatalogTask = nil
                self.invalidateAuthorizationIfNeeded(normalized)
                self.publish()
            }
        }
    }

    func togglePinnedContainer(_ container: JiraPinnedContainer) {
        if let index = state.pinned.containers.firstIndex(where: { $0.id == container.id }) {
            state.pinned.containers.remove(at: index)
            state.pinned.sourceStates[.container(container.id)] = nil
        } else {
            state.pinned.containers.append(container)
        }
        preferences.jiraPinnedContainers = state.pinned.containers
        normalizePinnedSelection()
        publish()
    }

    func movePinnedContainer(_ container: JiraPinnedContainer, by offset: Int) {
        guard let index = state.pinned.containers.firstIndex(where: { $0.id == container.id }) else {
            return
        }
        let destination = index + offset
        guard state.pinned.containers.indices.contains(destination) else { return }
        state.pinned.containers.swapAt(index, destination)
        preferences.jiraPinnedContainers = state.pinned.containers
        publish()
    }

    func pinIssue(key: String) async {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedKey.isEmpty == false else {
            state.pinned.pinIssueError = .invalidResponse
            publish()
            return
        }
        if let existing = state.pinned.issues.first(where: { $0.key == normalizedKey }) {
            state.pinned.selectedSource = .issues
            state.pinned.pinIssueError = nil
            publish()
            _ = existing
            loadPinnedSource(.issues, force: false)
            return
        }

        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else {
                state.pinned.pinIssueError = .notConfigured
                publish()
                return
            }
            configuration = resolved
        } catch {
            state.pinned.pinIssueError = Self.normalizedError(error)
            publish()
            return
        }

        state.pinned.isPinningIssue = true
        state.pinned.pinIssueError = nil
        publish()
        do {
            let issue = try await client.issue(
                baseURL: configuration.baseURL,
                token: configuration.token,
                issueKey: normalizedKey
            )
            let pin = JiraPinnedIssue(key: issue.key, summary: issue.summary)
            state.pinned.issues.append(pin)
            preferences.jiraPinnedIssues = state.pinned.issues
            state.pinned.selectedSource = .issues
            state.pinned.sourceStates[.issues] = .idle
            state.pinned.isPinningIssue = false
            publish()
            loadPinnedSource(.issues, force: true)
        } catch {
            let normalized = Self.normalizedError(error)
            state.pinned.isPinningIssue = false
            state.pinned.pinIssueError = normalized
            invalidateAuthorizationIfNeeded(normalized)
            publish()
        }
    }

    func removePinnedIssue(_ issue: JiraPinnedIssue) {
        state.pinned.issues.removeAll { $0.key == issue.key }
        preferences.jiraPinnedIssues = state.pinned.issues
        state.pinned.sourceStates[.issues] = .idle
        normalizePinnedSelection()
        publish()
        if state.pinned.selectedSource == .issues {
            loadPinnedSource(.issues, force: true)
        }
    }

    func movePinnedIssue(_ issue: JiraPinnedIssue, by offset: Int) {
        guard let index = state.pinned.issues.firstIndex(where: { $0.key == issue.key }) else {
            return
        }
        let destination = index + offset
        guard state.pinned.issues.indices.contains(destination) else { return }
        state.pinned.issues.swapAt(index, destination)
        preferences.jiraPinnedIssues = state.pinned.issues
        state.pinned.sourceStates[.issues] = .idle
        publish()
    }

    func selectPinnedSource(_ source: JiraPinnedSourceID) {
        guard state.pinned.availableSources.contains(source) else { return }
        state.pinned.selectedSource = source
        publish()
        loadPinnedSource(source, force: false)
    }

    func refreshPinnedSource() {
        guard let source = state.pinned.selectedSource else { return }
        loadPinnedSource(source, force: true)
    }

    func loadTransitions(for issueKey: String) async {
        let previous = previousTransitions(for: issueKey)
        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else {
                publishTransitionFailure(.notConfigured, previous: previous, issueKey: issueKey)
                return
            }
            configuration = resolved
        } catch {
            publishTransitionFailure(
                Self.normalizedError(error),
                previous: previous,
                issueKey: issueKey
            )
            return
        }

        transitionTasks[issueKey]?.cancel()
        let generation = nextTransitionGeneration(for: issueKey)
        let lifecycle = lifecycleGeneration
        state.transitionsByIssueKey[issueKey] = .loading
        publish()

        let task = Task { [weak self, client] in
            defer { self?.clearTransitionTask(for: issueKey, generation: generation) }
            do {
                let transitions = try await client.transitions(
                    baseURL: configuration.baseURL,
                    token: configuration.token,
                    issueKey: issueKey
                )
                guard let self,
                      self.lifecycleGeneration == lifecycle,
                      self.transitionGenerations[issueKey] == generation else { return }
                self.state.transitionsByIssueKey[issueKey] = .loaded(transitions)
                self.publish()
            } catch {
                guard let self,
                      self.lifecycleGeneration == lifecycle,
                      self.transitionGenerations[issueKey] == generation else { return }
                self.publishTransitionFailure(
                    Self.normalizedError(error),
                    previous: previous,
                    issueKey: issueKey
                )
            }
        }
        transitionTasks[issueKey] = task
        await task.value
    }

    func performTransition(issueKey: String, transition: JiraTransition) async {
        let previous = previousTransitions(for: issueKey)
        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else {
                publishTransitionFailure(.notConfigured, previous: previous, issueKey: issueKey)
                return
            }
            configuration = resolved
        } catch {
            publishTransitionFailure(
                Self.normalizedError(error),
                previous: previous,
                issueKey: issueKey
            )
            return
        }

        transitionTasks[issueKey]?.cancel()
        let generation = nextTransitionGeneration(for: issueKey)
        let lifecycle = lifecycleGeneration
        state.transitionsByIssueKey[issueKey] = .submitting(previous ?? [])
        publish()

        let task = Task { [weak self, client] in
            defer { self?.clearTransitionTask(for: issueKey, generation: generation) }
            do {
                try await client.performTransition(
                    baseURL: configuration.baseURL,
                    token: configuration.token,
                    issueKey: issueKey,
                    transitionID: transition.id
                )
                guard let self,
                      self.lifecycleGeneration == lifecycle,
                      self.transitionGenerations[issueKey] == generation else { return }
                self.replaceIssueStatus(issueKey: issueKey, status: transition.toStatus)
                self.state.transitionsByIssueKey[issueKey] = .idle
                self.publish()
                self.refresh()
            } catch {
                guard let self,
                      self.lifecycleGeneration == lifecycle,
                      self.transitionGenerations[issueKey] == generation else { return }
                self.publishTransitionFailure(
                    Self.normalizedError(error),
                    previous: previous,
                    issueKey: issueKey
                )
            }
        }
        transitionTasks[issueKey] = task
        await task.value
    }

    func addWorklog(
        issueKey: String,
        draft: JiraWorklogDraft
    ) async -> Result<Void, JiraAPIError> {
        guard draft.isValid,
              let timeSpentSeconds = draft.timeSpentSeconds else {
            return .failure(.invalidWorklog)
        }

        let lifecycle = lifecycleGeneration
        if let inFlightWorklog = worklogTasks[issueKey],
           inFlightWorklog.lifecycle == lifecycle {
            return await inFlightWorklog.task.value
        }

        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else {
                return .failure(.notConfigured)
            }
            configuration = resolved
        } catch {
            return .failure(Self.normalizedError(error))
        }

        let normalizedDescription = draft.normalizedDescription
        let task = Task<Result<Void, JiraAPIError>, Never> { [client] in
            do {
                try await client.addWorklog(
                    baseURL: configuration.baseURL,
                    token: configuration.token,
                    issueKey: issueKey,
                    timeSpentSeconds: timeSpentSeconds,
                    comment: normalizedDescription
                )
                return .success(())
            } catch {
                return .failure(Self.normalizedError(error))
            }
        }
        worklogTasks[issueKey] = InFlightWorklog(lifecycle: lifecycle, task: task)

        let result = await task.value
        if worklogTasks[issueKey]?.lifecycle == lifecycle {
            worklogTasks[issueKey] = nil
        }
        if lifecycleGeneration == lifecycle,
           case .failure(.unauthorized) = result {
            invalidateAuthorizationIfNeeded(.unauthorized)
            publish()
        }
        return result
    }

    private var isConfigured: Bool {
        switch state.connection {
        case .ready, .connected:
            true
        default:
            false
        }
    }

    private var currentIssues: [JiraIssue]? {
        switch state.list {
        case let .loaded(issues, _):
            issues
        case let .loading(previous), let .failed(_, previous):
            previous
        case .idle:
            nil
        }
    }

    private func parseBaseURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url else { return nil }
        return url
    }

    private func configuredCredentials() throws -> (baseURL: URL, token: String)? {
        guard let baseURLText = preferences.jiraBaseURLString,
              let token = try credentialStore.loadToken() else { return nil }
        guard let baseURL = parseBaseURL(baseURLText) else {
            throw JiraAPIError.invalidBaseURL
        }
        return (baseURL, token)
    }

    private func loadPinnedSource(_ source: JiraPinnedSourceID, force: Bool) {
        guard isStarted, isConfigured else { return }
        if force == false,
           case .loaded = state.pinned.sourceStates[source] {
            return
        }

        let configuration: (baseURL: URL, token: String)
        do {
            guard let resolved = try configuredCredentials() else { return }
            configuration = resolved
        } catch {
            state.pinned.sourceStates[source] = .failed(
                error: Self.normalizedError(error),
                previous: state.pinned.sourceStates[source]?.issues
            )
            publish()
            return
        }

        pinnedSourceTask?.cancel()
        pinnedSourceGeneration &+= 1
        let generation = pinnedSourceGeneration
        let previous = state.pinned.sourceStates[source]?.issues
        let pinnedIssues = state.pinned.issues
        let container = state.pinned.containers.first { candidate in
            source == .container(candidate.id)
        }
        state.pinned.sourceStates[source] = .loading(previous: previous)
        publish()

        pinnedSourceTask = Task { [weak self, client] in
            do {
                let page: JiraSearchPage
                switch source {
                case .issues:
                    var resolved: [JiraIssue] = []
                    var firstError: JiraAPIError?
                    for pin in pinnedIssues {
                        do {
                            resolved.append(
                                try await client.issue(
                                    baseURL: configuration.baseURL,
                                    token: configuration.token,
                                    issueKey: pin.key
                                )
                            )
                        } catch {
                            if firstError == nil {
                                firstError = Self.normalizedError(error)
                            }
                        }
                    }
                    if resolved.isEmpty, let firstError, pinnedIssues.isEmpty == false {
                        throw firstError
                    }
                    page = JiraSearchPage(issues: resolved, total: pinnedIssues.count)
                case .container:
                    guard let container else { return }
                    switch container.kind {
                    case .project:
                        page = try await client.projectIssues(
                            baseURL: configuration.baseURL,
                            token: configuration.token,
                            projectKey: container.reference
                        )
                    case .board:
                        page = try await client.boardIssues(
                            baseURL: configuration.baseURL,
                            token: configuration.token,
                            boardID: container.reference
                        )
                    }
                }

                guard let self,
                      self.pinnedSourceGeneration == generation,
                      self.state.pinned.availableSources.contains(source) else { return }
                self.state.pinned.sourceStates[source] = .loaded(
                    issues: page.issues,
                    total: page.total
                )
                self.pinnedSourceTask = nil
                self.publish()
            } catch {
                guard let self,
                      self.pinnedSourceGeneration == generation else { return }
                let normalized = Self.normalizedError(error)
                self.state.pinned.sourceStates[source] = .failed(
                    error: normalized,
                    previous: previous
                )
                self.pinnedSourceTask = nil
                self.invalidateAuthorizationIfNeeded(normalized)
                self.publish()
            }
        }
    }

    private func normalizePinnedSelection() {
        let sources = state.pinned.availableSources
        if let selected = state.pinned.selectedSource, sources.contains(selected) {
            return
        }
        state.pinned.selectedSource = sources.first
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingGeneration &+= 1
        let generation = pollingGeneration
        let interval = pollingInterval
        let sleeper = pollingSleeper
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleeper(interval)
                guard !Task.isCancelled,
                      let self,
                      self.pollingGeneration == generation,
                      self.isStarted,
                      self.isVisible,
                      self.isConfigured else {
                    return
                }
                self.refresh()
            }
        }
    }

    private func cancelRefreshAndPolling() {
        refreshTask?.cancel()
        refreshTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        refreshGeneration &+= 1
        pollingGeneration &+= 1
    }

    private func cancelPinnedTasks() {
        pinnedCatalogTask?.cancel()
        pinnedCatalogTask = nil
        pinnedSourceTask?.cancel()
        pinnedSourceTask = nil
        pinnedCatalogGeneration &+= 1
        pinnedSourceGeneration &+= 1
        state.pinned.catalog = .idle
        state.pinned.sourceStates = [:]
    }

    private func cancelTransitionTasks() {
        lifecycleGeneration &+= 1
        for task in transitionTasks.values {
            task.cancel()
        }
        transitionTasks.removeAll()
        transitionGenerations.removeAll()
    }

    private func publishListFailure(_ error: JiraAPIError) {
        publishListFailure(error, previous: currentIssues)
    }

    private func publishListFailure(_ error: JiraAPIError, previous: [JiraIssue]?) {
        state.list = .failed(error: error, previous: previous)
        invalidateAuthorizationIfNeeded(error)
        publish()
    }

    private func previousTransitions(for issueKey: String) -> [JiraTransition]? {
        switch state.transitionsByIssueKey[issueKey] {
        case let .loaded(transitions), let .submitting(transitions):
            transitions
        case let .failed(_, previous):
            previous
        case .idle, .loading, .none:
            nil
        }
    }

    private func nextTransitionGeneration(for issueKey: String) -> UInt {
        let generation = (transitionGenerations[issueKey] ?? 0) &+ 1
        transitionGenerations[issueKey] = generation
        return generation
    }

    private func clearTransitionTask(for issueKey: String, generation: UInt) {
        guard transitionGenerations[issueKey] == generation else { return }
        transitionTasks[issueKey] = nil
    }

    private func publishTransitionFailure(
        _ error: JiraAPIError,
        previous: [JiraTransition]?,
        issueKey: String
    ) {
        state.transitionsByIssueKey[issueKey] = .failed(error: error, previous: previous)
        invalidateAuthorizationIfNeeded(error)
        publish()
    }

    private func invalidateAuthorizationIfNeeded(_ error: JiraAPIError) {
        guard error == .unauthorized else { return }
        state.connection = .failed(.unauthorized)
        cancelRefreshAndPolling()
        cancelTransitionTasks()
    }

    private func replaceIssueStatus(issueKey: String, status: JiraStatus) {
        func replacing(in issues: [JiraIssue]?) -> [JiraIssue]? {
            issues?.map { issue in
                guard issue.key == issueKey else { return issue }
                return JiraIssue(
                    id: issue.id,
                    key: issue.key,
                    summary: issue.summary,
                    projectKey: issue.projectKey,
                    projectName: issue.projectName,
                    status: status,
                    priorityName: issue.priorityName,
                    dueDate: issue.dueDate,
                    updatedAt: issue.updatedAt
                )
            }
        }

        switch state.list {
        case let .loaded(issues, total):
            state.list = .loaded(issues: replacing(in: issues) ?? issues, total: total)
        case let .loading(previous):
            state.list = .loading(previous: replacing(in: previous))
        case let .failed(error, previous):
            state.list = .failed(error: error, previous: replacing(in: previous))
        case .idle:
            break
        }

        for (source, loadState) in state.pinned.sourceStates {
            switch loadState {
            case let .loaded(issues, total):
                state.pinned.sourceStates[source] = .loaded(
                    issues: replacing(in: issues) ?? issues,
                    total: total
                )
            case let .loading(previous):
                state.pinned.sourceStates[source] = .loading(
                    previous: replacing(in: previous)
                )
            case let .failed(error, previous):
                state.pinned.sourceStates[source] = .failed(
                    error: error,
                    previous: replacing(in: previous)
                )
            case .idle:
                break
            }
        }
    }

    private static func taskProjects(from issues: [JiraIssue]) -> [JiraProject] {
        var projectsByKey: [String: JiraProject] = [:]
        for issue in issues {
            projectsByKey[issue.projectKey] = JiraProject(
                id: issue.projectKey,
                key: issue.projectKey,
                name: issue.projectName
            )
        }
        return projectsByKey.values.sorted { $0.key < $1.key }
    }

    private func publish() {
        onChange?(state)
    }

    private static func normalizedError(_ error: Error) -> JiraAPIError {
        error as? JiraAPIError ?? .network
    }
}
