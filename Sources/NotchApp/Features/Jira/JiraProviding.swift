import Foundation

@MainActor
protocol JiraProviding: AnyObject {
    var onChange: ((JiraProviderState) -> Void)? { get set }
    func start()
    func stop()
    func setVisible(_ isVisible: Bool)
    func refresh()
    func checkConnection(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError>
    func connect(
        baseURLText: String,
        token: String
    ) async -> Result<JiraUser, JiraAPIError>
    func disconnect()
    func setSelectedProjectKeys(_ keys: Set<String>)
    func setIssueScope(_ scope: JiraIssueScope)
    func loadMoreIssues()
    func refreshPinnedCatalog()
    func togglePinnedContainer(_ container: JiraPinnedContainer)
    func movePinnedContainer(_ container: JiraPinnedContainer, by offset: Int)
    func pinIssue(key: String) async
    func removePinnedIssue(_ issue: JiraPinnedIssue)
    func movePinnedIssue(_ issue: JiraPinnedIssue, by offset: Int)
    func selectPinnedSource(_ source: JiraPinnedSourceID)
    func refreshPinnedSource()
    func issue(key: String) async -> Result<JiraIssue, JiraAPIError>
    func loadTransitions(for issueKey: String) async
    func performTransition(issueKey: String, transition: JiraTransition) async
    func searchAssignableUsers(
        issueKey: String,
        projectKey: String,
        query: String
    ) async
    func assign(
        issueKey: String,
        selection: JiraAssigneeSelection
    ) async -> Result<Void, JiraAPIError>
    func addWorklog(
        issueKey: String,
        draft: JiraWorklogDraft
    ) async -> Result<Void, JiraAPIError>
}
