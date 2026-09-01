import Foundation

@MainActor
final class JiraProvider: JiraProviding {
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
        do {
            try credentialStore.deleteToken()
        } catch {
            state.connection = .failed(.network)
            publish()
            return
        }
        preferences.jiraBaseURLString = nil
        preferences.jiraSelectedProjectKeys = []
        state = JiraProviderState()
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
