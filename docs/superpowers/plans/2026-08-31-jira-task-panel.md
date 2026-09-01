# Jira Task Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native Jira Server/Data Center tab that securely connects with a PAT, lists the current user's unresolved issues with project filters, opens issues in Jira, and executes server-provided workflow transitions.

**Architecture:** A stateless REST client owns Jira API request/response contracts, a Keychain store owns the PAT, and a main-actor provider owns connection/list/filter/transition lifecycle. `NotchViewModel` mirrors provider state and visibility while SwiftUI views remain declarative consumers. The first slice stops at read/filter/open/transition; no generic integration framework or future Jira features are added.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation `URLSession`, Security/Keychain, XCTest, Jira Server/Data Center REST API v2, macOS 14+

**Spec:** `docs/superpowers/specs/2026-08-31-jira-task-panel-design.md`

## Global Constraints

- Jira type is Server/Data Center with `Authorization: Bearer <PAT>` and REST API v2.
- PAT is stored only as a macOS Keychain generic password; it never enters UserDefaults or logs.
- Base URL may include a path prefix; every endpoint and browser URL must preserve it.
- Authorization may be sent only to the configured scheme/host/port; cross-origin redirects are rejected.
- Base task filter is `assignee = currentUser() AND resolution IS EMPTY`; project keys come from Jira and are escaped.
- Search returns at most 50 issues, ordered by priority then updated time.
- Workflow names are never hardcoded; transitions are fetched per issue and state-changing POSTs are never retried automatically.
- Jira polling runs every 60 seconds only while expanded Jira is visible and in-notch Settings are closed.
- Reuse the existing Music expanded-size budget; preserve Limits, Calendar, Music, Settings, signing, and hover behavior.
- No external dependencies, arbitrary JQL, comments, issue editing, attachments, worklogs, boards/sprints, multiple Jira instances, offline cache, SSO cookies, or TLS bypass.
- The directory is not a Git checkout, so this plan has no commit steps; preserve all unrelated files and edits directly.

---

### Task 1: Jira domain and non-secret preferences

**Files:**
- Create: `Sources/NotchApp/JiraModels.swift`
- Modify: `Sources/NotchApp/AppPreferences.swift`
- Modify: `Tests/NotchAppTests/AppPreferencesTests.swift`
- Modify: `Tests/NotchAppTests/TestDoubles.swift`
- Test: `Tests/NotchAppTests/JiraModelsTests.swift`

**Interfaces:**
- Produces `JiraProject`, `JiraStatus`, `JiraIssue`, `JiraTransition`, `JiraUser`, `JiraSearchPage`, `JiraAPIError`, `JiraConnectionState`, `JiraListState`, `JiraTransitionState`, and `JiraProviderState` as `Equatable`/`Sendable` value types.
- Produces `JiraIssue.browserURL(baseURL: URL) -> URL?`.
- Extends `AppPreferencesStoring` with `jiraBaseURLString: String?` and `jiraSelectedProjectKeys: Set<String>`.

- [ ] **Step 1: Write failing preference and URL tests**

Add literal behavior tests:

```swift
func testPreferencesRoundTripJiraBaseURLAndProjectSelection() {
    let suiteName = "NotchAppTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = UserDefaultsAppPreferences(defaults: defaults)
    preferences.jiraBaseURLString = "https://jira.example.test/company"
    preferences.jiraSelectedProjectKeys = ["WEB", "APP"]

    let restored = UserDefaultsAppPreferences(defaults: defaults)
    XCTAssertEqual(restored.jiraBaseURLString, "https://jira.example.test/company")
    XCTAssertEqual(restored.jiraSelectedProjectKeys, ["APP", "WEB"])
}

func testIssueBrowserURLPreservesJiraBasePath() throws {
    let issue = JiraIssue.fixture(key: "APP-184")
    let baseURL = try XCTUnwrap(URL(string: "https://jira.example.test/company"))

    XCTAssertEqual(
        issue.browserURL(baseURL: baseURL)?.absoluteString,
        "https://jira.example.test/company/browse/APP-184"
    )
}
```

Production breaks caught: dropping project persistence, leaking selection order into storage semantics, or resolving `/browse` from the host root instead of the Jira path prefix.

- [ ] **Step 2: Run RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notchapp-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/notchapp-swiftpm-cache \
swift test --disable-sandbox --filter 'AppPreferencesTests|JiraModelsTests'
```

Expected: compile failure because Jira preference properties, models, and `browserURL` do not exist.

- [ ] **Step 3: Implement minimal domain and preferences**

Define focused values with no networking behavior:

```swift
struct JiraProject: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let name: String
}

struct JiraStatus: Equatable, Sendable {
    let id: String
    let name: String
    let categoryKey: String
}

struct JiraIssue: Identifiable, Equatable, Sendable {
    let id: String
    let key: String
    let summary: String
    let projectKey: String
    let projectName: String
    let status: JiraStatus
    let priorityName: String?
    let dueDate: Date?
    let updatedAt: Date

    func browserURL(baseURL: URL) -> URL? {
        baseURL.appending(path: "browse").appending(path: key)
    }
}

struct JiraTransition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let toStatus: JiraStatus
}

struct JiraUser: Equatable, Sendable {
    let displayName: String
}

struct JiraSearchPage: Equatable, Sendable {
    let issues: [JiraIssue]
    let total: Int
}

enum JiraAPIError: Error, Equatable, Sendable {
    case invalidBaseURL
    case notConfigured
    case unauthorized
    case forbidden
    case rateLimited
    case server(Int)
    case http(Int)
    case invalidResponse
    case decoding
    case network
}

enum JiraConnectionState: Equatable, Sendable {
    case notConfigured
    case ready
    case validating
    case validated(JiraUser)
    case connected(JiraUser)
    case failed(JiraAPIError)
}

enum JiraListState: Equatable, Sendable {
    case idle
    case loading(previous: [JiraIssue])
    case loaded(issues: [JiraIssue], total: Int)
    case failed(error: JiraAPIError, previous: [JiraIssue])
}

enum JiraTransitionState: Equatable, Sendable {
    case idle
    case loading
    case loaded([JiraTransition])
    case submitting([JiraTransition])
    case failed(error: JiraAPIError, previous: [JiraTransition])
}

struct JiraProviderState: Equatable, Sendable {
    var connection: JiraConnectionState
    var projects: [JiraProject]
    var selectedProjectKeys: Set<String>
    var list: JiraListState
    var transitionsByIssueKey: [String: JiraTransitionState]
}
```

Use UserDefaults keys `jira.baseURL` and `jira.selectedProjectKeys`. Store selected keys as a sorted string array; expose them as `Set<String>`. Removing the Base URL sets `nil`; no token property is added to `AppPreferencesStoring`.

- [ ] **Step 4: Run GREEN**

Run the Task 1 test command. Expected: all selected tests pass with no warning or Keychain access.

### Task 2: PAT storage in Keychain

**Files:**
- Create: `Sources/NotchApp/JiraCredentialStore.swift`
- Test: `Tests/NotchAppTests/JiraCredentialStoreTests.swift`

**Interfaces:**
- Produces main-actor protocol `JiraCredentialStoring` with `loadToken() throws -> String?`, `saveToken(_:) throws`, and `deleteToken() throws`.
- Produces `KeychainJiraCredentialStore(service:account:)`; production defaults are service `com.nailuyltyev.NotchApp.jira` and account `personal-access-token`.
- Produces safe `JiraCredentialError` cases that contain no token or raw Keychain payload.

- [ ] **Step 1: Write the real Keychain lifecycle test**

```swift
@MainActor
func testKeychainStoreSavesReplacesAndDeletesToken() throws {
    let service = "NotchAppTests.Jira.\(UUID().uuidString)"
    let store = KeychainJiraCredentialStore(service: service, account: "test-token")
    defer { try? store.deleteToken() }

    XCTAssertNil(try store.loadToken())
    try store.saveToken("first-secret")
    XCTAssertEqual(try store.loadToken(), "first-secret")
    try store.saveToken("replacement-secret")
    XCTAssertEqual(try store.loadToken(), "replacement-secret")
    try store.deleteToken()
    XCTAssertNil(try store.loadToken())
}
```

Production breaks caught: writing the token under an unreadable query, failing to replace an existing item, or leaving the item after disconnect.

- [ ] **Step 2: Run RED**

Run the standard Swift environment with `swift test --disable-sandbox --filter JiraCredentialStoreTests`. Expected: compile failure because the credential store is missing.

- [ ] **Step 3: Implement the Keychain boundary**

Use `SecItemCopyMatching`, `SecItemAdd`, `SecItemUpdate`, and `SecItemDelete` with:

```swift
kSecClass: kSecClassGenericPassword
kSecAttrService: service
kSecAttrAccount: account
kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

Encode/decode only UTF-8 token data. Treat `errSecItemNotFound` as `nil`/successful deletion; map all other `OSStatus` values to sanitized `JiraCredentialError.keychain(status:)` without including query values.

- [ ] **Step 4: Run GREEN**

Run `swift test --disable-sandbox --filter JiraCredentialStoreTests`. Expected: one Keychain lifecycle test passes and cleans up its UUID-scoped item.

### Task 3: Jira REST v2 client and same-origin transport

**Files:**
- Create: `Sources/NotchApp/JiraClient.swift`
- Test: `Tests/NotchAppTests/JiraClientTests.swift`

**Interfaces:**
- Produces `@MainActor protocol JiraClientProtocol` with:

```swift
func currentUser(baseURL: URL, token: String) async throws -> JiraUser
func projects(baseURL: URL, token: String) async throws -> [JiraProject]
func issues(baseURL: URL, token: String, projectKeys: Set<String>) async throws -> JiraSearchPage
func transitions(baseURL: URL, token: String, issueKey: String) async throws -> [JiraTransition]
func performTransition(baseURL: URL, token: String, issueKey: String, transitionID: String) async throws
```

- Produces `@MainActor protocol JiraHTTPTransport` returning `(Data, HTTPURLResponse)` for a `URLRequest`.
- Produces `JiraURLSessionTransport`, `JiraSameOriginRedirectPolicy`, and `JiraClient`.

- [ ] **Step 1: Write failing request-contract tests**

Use an injected transport that returns complete Jira-shaped fixtures and records the real `URLRequest`. Assert hand-derived literals:

```swift
func testSearchPreservesBasePathAndBuildsFilteredJQL() async throws {
    let transport = RecordingJiraTransport(responseJSON: searchFixture)
    let client = JiraClient(transport: transport)

    _ = try await client.issues(
        baseURL: URL(string: "https://jira.example.test/company")!,
        token: "secret-value",
        projectKeys: ["WEB", "APP"]
    )

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://jira.example.test/company/rest/api/2/search")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-value")
    let body = try JSONDecoder().decode(SearchRequestProbe.self, from: XCTUnwrap(request.httpBody))
    XCTAssertEqual(
        body.jql,
        "assignee = currentUser() AND resolution IS EMPTY AND project IN (\"APP\", \"WEB\") ORDER BY priority DESC, updated DESC"
    )
    XCTAssertEqual(body.maxResults, 50)
}
```

Add these independent request/response contract tests (each test records one request or decodes one fixture and asserts the listed literal outcome):

| Test | Exact assertion |
|---|---|
| `testSearchWithoutProjectsOmitsProjectClause()` | JQL equals `assignee = currentUser() AND resolution IS EMPTY ORDER BY priority DESC, updated DESC` |
| `testCurrentUserPreservesBasePath()` | GET URL equals `https://jira.example.test/company/rest/api/2/myself` |
| `testProjectsPreservesBasePath()` | GET URL equals `https://jira.example.test/company/rest/api/2/project` |
| `testTransitionsEncodeIssueKey()` | GET URL path ends in `/issue/APP-184%2Fchild/transitions` |
| `testPerformTransitionPostsSelectedIDOnce()` | POST body decodes to transition ID `31` and the transport records one request |
| `testIssueDecodingAllowsMissingPriorityAndDueDate()` | decoded issue has `priority == nil` and `dueDate == nil` |
| `testIssueDecodingPreservesCustomStatus()` | decoded status name/category equal the custom fixture literals |
| `testHTTPFailuresMapToSafeErrors()` | 401/403/429/503 map to `.unauthorized`/`.forbidden`/`.rateLimited`/`.server(503)` |
| `testMalformedSuccessfulJSONThrowsDecoding()` | HTTP 200 with invalid Jira JSON throws `.decoding` |

Add the redirect-policy assertion separately:

```swift
XCTAssertFalse(
    JiraSameOriginRedirectPolicy.allows(
        from: URL(string: "https://jira.example.test/company")!,
        to: URL(string: "https://evil.example/collect")!
    )
)
```

Production breaks caught: losing a base path, wrong auth/method/body, unsafe project interpolation, treating error pages as data, or forwarding credentials to another origin.

- [ ] **Step 2: Run RED**

Run `swift test --disable-sandbox --filter JiraClientTests` with the standard Swift environment. Expected: compile failure for missing client/transport contracts.

- [ ] **Step 3: Implement minimal REST client**

Build endpoint paths by appending `rest/api/2/...` components to the configured Base URL. Sort project keys before quoting; escape `\\` and `"`. Use JSONEncoder for search and transition bodies and a JSONDecoder configured for Jira ISO-8601 timestamps plus `yyyy-MM-dd` due dates.

Map status codes exactly:

```swift
200..<300 -> decode or success
401 -> .unauthorized
403 -> .forbidden
429 -> .rateLimited
500...599 -> .server(statusCode)
other -> .http(statusCode)
```

`JiraURLSessionTransport` uses an ephemeral session and a task redirect delegate that follows only `JiraSameOriginRedirectPolicy`. Same origin means lowercased scheme/host and effective port match. A rejected redirect returns no follow-up request, so the Authorization header cannot cross origins.

- [ ] **Step 4: Run GREEN**

Run `swift test --disable-sandbox --filter JiraClientTests`. Expected: all request, decoding, error, and redirect-policy tests pass.

### Task 4: Jira provider lifecycle, filtering, and transitions

**Files:**
- Create: `Sources/NotchApp/JiraProvider.swift`
- Modify: `Sources/NotchApp/ProviderProtocols.swift`
- Test: `Tests/NotchAppTests/JiraProviderTests.swift`
- Modify: `Tests/NotchAppTests/TestDoubles.swift`

**Interfaces:**
- Produces `@MainActor protocol JiraProviding`:

```swift
var onChange: ((JiraProviderState) -> Void)? { get set }
func start()
func stop()
func setVisible(_ isVisible: Bool)
func refresh()
func checkConnection(baseURLText: String, token: String) async -> Result<JiraUser, JiraAPIError>
func connect(baseURLText: String, token: String) async -> Result<JiraUser, JiraAPIError>
func disconnect()
func setSelectedProjectKeys(_ keys: Set<String>)
func loadTransitions(for issueKey: String) async
func performTransition(issueKey: String, transition: JiraTransition) async
```

- Produces `JiraProvider(client:credentialStore:preferences:pollInterval:)` with a 60-second production interval.

- [ ] **Step 1: Write failing provider behavior tests**

Use a deterministic fake Jira client, in-memory credential store, and `MemoryAppPreferences`. Cover these observable mutations independently:

```swift
func testVisibleConfiguredProviderLoadsProjectsAndIssues() async {
    let harness = JiraProviderHarness.configured()
    harness.client.projectsResult = .success([.fixture(key: "APP")])
    harness.client.issueResults = [.success(.fixture(issueKey: "APP-184"))]

    harness.provider.start()
    harness.provider.setVisible(true)
    await harness.settle()

    XCTAssertEqual(harness.states.last?.projects.map(\.key), ["APP"])
    XCTAssertEqual(harness.states.last?.list.issueKeys, ["APP-184"])
}
```

Add these independent provider tests and assertions:

| Test | Observable proof |
|---|---|
| `testUnconfiguredStartDoesNotUseNetwork()` | last connection is `.notConfigured`; every fake-client call count is zero |
| `testHiddenProviderDoesNotRefresh()` | `setVisible(false)` followed by clock advancement records zero issue requests |
| `testSelectingProjectsPersistsAndRefreshesExactKeys()` | preferences and the last issue request both contain `Set(["APP", "WEB"])` |
| `testNewestRefreshWins()` | after completing the second request before the first, published issues remain the second response |
| `testLeavingPanelCancelsPolling()` | after `setVisible(false)` and clock advancement, issue request count does not increase |
| `testCheckConnectionDoesNotPersistCredentials()` | returned user succeeds while Base URL remains nil and credential-store save count is zero |
| `testConnectRevalidatesBeforePersisting()` | `currentUser` is called once, then PAT/Base URL are saved and connected state is published |
| `testDisconnectDeletesConfigurationAndCancelsWork()` | token/Base URL/keys are absent, state is `.notConfigured`, and no later poll occurs |
| `testFailedTransitionPreservesStatusAndDoesNotRetry()` | issue status is unchanged and transition POST count is one |
| `testSuccessfulTransitionUpdatesThenReconciles()` | row first publishes `transition.toStatus`; issue request count then increases once |
| `testTransitionStateIsScopedByIssueKey()` | loading/error entry changes only for `APP-184`; `WEB-72` remains unchanged |

Production breaks caught: background polling, secret persistence during a check, stale response overwrite, wrong project filter, duplicate state-changing request, or destroying loaded data after one row fails.

- [ ] **Step 2: Run RED**

Run `swift test --disable-sandbox --filter JiraProviderTests` with the standard Swift environment. Expected: compile failure because `JiraProviding`/`JiraProvider` do not exist.

- [ ] **Step 3: Implement provider state machine**

On `start`, load Base URL, selected keys, and token existence without networking. `setVisible(true)` starts immediate refresh plus a cancellable polling task; `setVisible(false)` cancels refresh and polling. Refresh retains an incrementing generation and publishes only when the current generation completes.

`checkConnection` accepts HTTPS only, requires a host, and rejects URL user-info, query, or fragment before any request; this prevents Bearer PAT disclosure and keeps persisted Base URL non-secret. It calls `currentUser` and never writes preferences/Keychain. `connect` repeats validation, then saves PAT/Base URL, loads projects/issues, and publishes connected state. A 401 moves the connection to `.failed(.unauthorized)` and stops automatic polling until a successful reconnect. `disconnect` cancels tasks, deletes credentials and non-secret settings, and returns to `.notConfigured`.

For transitions, resolve token/configuration, mark only the issue key loading/submitting, call the client once, then either preserve the row with a scoped error or replace its status with `transition.toStatus` and trigger a non-destructive refresh.

- [ ] **Step 4: Run GREEN**

Run `swift test --disable-sandbox --filter JiraProviderTests`. Expected: all provider state, cancellation, polling, credential, filtering, and transition tests pass.

### Task 5: Panel registry, ViewModel, Settings, and Jira queue UI

**Files:**
- Modify: `Sources/NotchApp/NotchSharedUI.swift`
- Modify: `Sources/NotchCore/QuotaModels.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Modify: `Sources/NotchApp/ExpandedNotch.swift`
- Modify: `Sources/NotchApp/InNotchSettingsView.swift`
- Create: `Sources/NotchApp/JiraPanel.swift`
- Create: `Sources/NotchApp/JiraConnectionSettingsView.swift`
- Modify: `Tests/NotchAppTests/NotchInteractionTests.swift`
- Modify: `Tests/NotchAppTests/NotchViewModelProviderTests.swift`
- Modify: `Tests/NotchAppTests/TestDoubles.swift`

**Interfaces:**
- Adds `PanelID.jira`, title `Jira`, icon `checkmark.square` in both existing registries.
- `NotchWindowSizingPolicy.size` returns `metrics.expandedMusicSize` for visible Jira as well as Music.
- `NotchViewModel` exposes `jiraState`, injects `any JiraProviding`, and delegates check/connect/disconnect/refresh/filter/transition actions.
- `JiraPanel` renders provider state and `JiraConnectionSettingsView` owns only transient Base URL/PAT form values.

- [ ] **Step 1: Write failing integration tests**

Extend literals in current tests:

```swift
func testJiraUsesQueueHeightWithoutChangingOtherPanels() {
    let metrics = NotchLayout.metrics(
        safeAreaTop: 38,
        leftAuxiliaryArea: CGRect(x: 0, y: 1_131, width: 790, height: 38),
        rightAuxiliaryArea: CGRect(x: 1_010, y: 1_131, width: 790, height: 38)
    )
    XCTAssertEqual(
        NotchWindowSizingPolicy.size(
            metrics: metrics,
            isExpanded: true,
            selectedPanel: .jira,
            calendarViewMode: .list,
            isShowingSettings: false
        ),
        CGSize(width: 500, height: 380)
    )
}

func testViewModelMakesJiraVisibleOnlyForExpandedJiraPanel() {
    let jira = FakeJiraProvider()
    let model = makeModel(jiraProvider: jira)

    XCTAssertEqual(jira.visibility, [false])
    model.selectPanel(.jira)
    model.isExpanded = true
    XCTAssertEqual(jira.visibility.last, true)
    model.showSettings()
    XCTAssertEqual(jira.visibility.last, false)
}
```

Also verify `.jira` round-trips as last selected panel, provider state reaches the model, project selection delegates, and existing Music polling remains unchanged.

Production breaks caught: missing registry case, wrong window budget, Jira polling while hidden/settings are open, or model/provider state disconnect.

- [ ] **Step 2: Run RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notchapp-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/notchapp-swiftpm-cache \
swift test --disable-sandbox --filter 'NotchInteractionTests|NotchViewModelProviderTests|AppPreferencesTests'
```

Expected: compile failures for `.jira`, Jira injection, and Jira state/actions.

- [ ] **Step 3: Implement panel registry and ViewModel wiring**

Rename `updateNowPlayingActivity` to `updateProviderActivity` and have it independently calculate Music polling mode and Jira visibility. Call it from expansion, panel selection, Settings show/hide, and initialization. Subscribe to `jiraProvider.onChange`, call `start`, and expose thin intent methods; do not move Jira HTTP/state logic into the model.

Add `.jira` to the `ExpandedNotch` switch. Treat Jira like Music in the centralized sizing policy so root content and AppKit coordinator remain consistent without extra branches elsewhere.

- [ ] **Step 4: Implement approved queue and settings UI**

`JiraPanel` uses:

```swift
VStack(spacing: 10) {
    projectChipScroll
    listOrStateContent
}
```

Render horizontally scrolling multi-select project chips, a refresh button, and a vertical task ScrollView. Each row has a semantic category rail, monospaced issue key, two-line summary, optional priority/due date, and a separate status button. Row tap opens `issue.browserURL(baseURL:)` with `NSWorkspace`; status tap awaits current transitions and presents a compact popover/menu. Disable only the affected status control while loading/submitting.

`JiraConnectionSettingsView` renders Base URL, SecureField, check/save/disconnect controls, and safe validation text. Keep the PAT in view-local `@State`; successful check enables Save only while the exact draft remains unchanged. Save calls `connect`, which revalidates before persistence. Never display a loaded token.

- [ ] **Step 5: Run GREEN and focused feature tests**

Run the Task 5 command, then:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notchapp-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/notchapp-swiftpm-cache \
swift test --disable-sandbox --filter 'Jira|AppPreferencesTests|NotchInteractionTests|NotchViewModelProviderTests'
```

Expected: Jira client/store/provider/integration tests pass and existing panel/Now Playing assertions remain green.

### Task 6: Full verification and live acceptance

**Files:**
- Verify: all files above
- Verify: `Tests/Signing/sign-app.test.sh`
- Verify: `Build/NotchApp.app`

**Interfaces:**
- Consumes the complete Jira vertical slice; produces no new feature surface.

- [ ] **Step 1: Run the full automated suite**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notchapp-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/notchapp-swiftpm-cache \
swift test --disable-sandbox
Tests/Signing/sign-app.test.sh
```

Expected: every XCTest and the stable-signing regression pass with zero failures.

- [ ] **Step 2: Build, sign, launch, and verify signature**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notchapp-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/notchapp-swiftpm-cache \
scripts/run-app.sh
codesign --verify --deep --strict Build/NotchApp.app
```

Expected: build succeeds, the existing Keychain Apple Development identity signs the app, strict verification exits 0, and the app launches.

- [ ] **Step 3: Verify UI states without credentials**

Open Jira and confirm the header, switcher, footer, `Подключить Jira` state, Settings navigation, and field/button accessibility labels fit without clipping. Confirm Limits, Calendar, Music, and in-notch Settings still use their prior geometry.

- [ ] **Step 4: Perform authorized live Jira acceptance**

Ask the owner to enter Base URL and PAT directly in NotchApp. Confirm connection, projects, unresolved issues, multi-project filtering, browser opening, and safe error copy. Before changing a real issue, obtain the owner's explicit choice of issue and transition; then execute exactly one transition and verify the actual Jira status changed. Do not print or inspect the PAT through tooling.

- [ ] **Step 5: Stop at the approved slice**

Remove temporary diagnostics and test credentials. Do not add comments, editing, boards, arbitrary JQL, notifications, or background polling. Report any live step that could not be verified instead of inferring success from mocked tests.
