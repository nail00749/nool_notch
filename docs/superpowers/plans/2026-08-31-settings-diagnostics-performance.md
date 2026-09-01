# Settings, Diagnostics, and Idle Performance Implementation Plan

**Status:** Complete and verified on 2026-08-31. Final gate: 28 Swift tests, signing regression, strict codesign verification, live settings/music/persistence checks, and compact-idle CPU at 0.6–1.0% after the 30-second gate.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-notch settings and player diagnostics, inject Calendar/Now Playing providers, persist interaction preferences, and reduce compact idle CPU below 2%.

**Architecture:** `NotchViewModel` remains the state owner but receives narrow provider and preferences protocols. The in-notch settings screen is transient UI state layered over the existing three panels; Now Playing exposes diagnostics and an adaptive polling mode. Performance work removes frame-driven SwiftUI rendering and detaches the persistent Ollama web view when it is not authenticating.

**Tech Stack:** Swift 6, SwiftUI, AppKit, EventKit, ApplicationServices Accessibility, WebKit, XCTest, Swift Package Manager, macOS 14+.

**Spec:** `docs/plans/2026-08-31-settings-diagnostics-performance-design.md`

## Global Constraints

- Keep `Лимиты`, `Календарь`, and `Музыка` as the only primary panels.
- Keep MediaRemote first and the generic Accessibility fallback second.
- No player-specific API, external dependencies, monitor migration, notch-layout changes, or codesign changes.
- Persist hover delay in `0...1` with default `0.5` and step `0.1`; persist only primary `PanelID` values.
- Artwork URL loading must use HTTPS, a 3-second timeout, a 5 MB maximum, and must not block the main actor.
- Compact idle CPU acceptance target is `<2%` after 30 seconds on the current Mac.
- This workspace is not a Git checkout, so commit steps are intentionally omitted.

---

### Task 1: Preferences and configurable hover delay

**Files:**
- Create: `Sources/NotchApp/AppPreferences.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Modify: `Sources/NotchApp/NotchRootView.swift`
- Modify: `Sources/NotchApp/NotchSharedUI.swift`
- Test: `Tests/NotchAppTests/AppPreferencesTests.swift`
- Test: `Tests/NotchAppTests/NotchInteractionTests.swift`

**Interfaces:**
- Produces: `@MainActor protocol AppPreferencesStoring`, `UserDefaultsAppPreferences`, `NotchViewModel.hoverExpansionDelay`, `NotchViewModel.setHoverExpansionDelay(_:)`.
- Preserves: existing collapse guard and startup hover gate.

- [ ] **Step 1: Write failing preferences and hover tests**

```swift
@MainActor
func testPreferencesClampDelayAndRestorePrimaryPanel() {
    let suite = UserDefaults(suiteName: UUID().uuidString)!
    let preferences = UserDefaultsAppPreferences(defaults: suite)
    preferences.hoverExpansionDelay = 2
    preferences.lastSelectedPanel = .music
    XCTAssertEqual(preferences.hoverExpansionDelay, 1)
    XCTAssertEqual(UserDefaultsAppPreferences(defaults: suite).lastSelectedPanel, .music)
}

func testHoverExpansionUsesConfiguredDelay() {
    XCTAssertEqual(NotchHoverPolicy.expansionDelay(configuredDelay: 0.46), 0.5)
    XCTAssertEqual(NotchHoverPolicy.expansionDelay(configuredDelay: -1), 0)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/private/tmp/notch-plan-clang SWIFT_MODULECACHE_PATH=/private/tmp/notch-plan-swift swift test --filter 'AppPreferencesTests|NotchInteractionTests/testHoverExpansionUsesConfiguredDelay'`

Expected: compilation failure because the preferences types and expansion-delay API do not exist.

- [ ] **Step 3: Implement preferences and delayed expansion**

```swift
@MainActor
protocol AppPreferencesStoring: AnyObject {
    var hoverExpansionDelay: TimeInterval { get set }
    var lastSelectedPanel: PanelID { get set }
}

@MainActor
final class UserDefaultsAppPreferences: AppPreferencesStoring {
    static let defaultHoverExpansionDelay: TimeInterval = 0.5
    // Clamp writes to 0...1 and decode PanelID(rawValue:) with .limits fallback.
}
```

Initialize `selectedPanel` and `hoverExpansionDelay` from the injected store. Save only from explicit setters. In `NotchRootView`, keep a cancellable expansion task: start it on compact hover, cancel it on leave, and recheck the cursor against the compact window frame before expanding.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

### Task 2: Calendar and Now Playing injection boundaries

**Files:**
- Create: `Sources/NotchApp/ProviderProtocols.swift`
- Modify: `Sources/NotchApp/CalendarEventProvider.swift`
- Modify: `Sources/NotchApp/NowPlayingProvider.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Create: `Tests/NotchAppTests/TestDoubles.swift`
- Create: `Tests/NotchAppTests/NotchViewModelProviderTests.swift`

**Interfaces:**
- Produces: `CalendarProviding`, `NowPlayingProviding`, `NowPlayingPollingMode`, `NowPlayingDiagnostics`, `NowPlayingSourceKind`.
- Consumes: `AppPreferencesStoring` from Task 1.

- [ ] **Step 1: Write fake-provider ViewModel tests**

```swift
@MainActor
func testInjectedNowPlayingProviderDrivesViewModel() {
    let nowPlaying = FakeNowPlayingProvider()
    let model = NotchViewModel(
        providers: [],
        calendarProvider: FakeCalendarProvider(),
        nowPlayingProvider: nowPlaying,
        preferences: MemoryAppPreferences()
    )
    nowPlaying.send(snapshot: .fixture(title: "Track"))
    XCTAssertEqual(model.nowPlayingSnapshot?.title, "Track")
    XCTAssertTrue(nowPlaying.didStart)
}
```

Also assert that a fake calendar `.denied` and loaded month values reach `calendarState` and `calendarEventsByMonth`.

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter NotchViewModelProviderTests` with the Xcode-beta/cache environment from Task 1.

Expected: initializer/protocol symbols are missing.

- [ ] **Step 3: Add the narrow protocols and inject defaults**

```swift
@MainActor
protocol CalendarProviding: AnyObject {
    func loadUpcomingEvents() async -> CalendarLoadState
    func loadEvents(for month: Date) async -> [CalendarEvent]
}

@MainActor
protocol NowPlayingProviding: AnyObject {
    var onChange: ((NowPlayingSnapshot?) -> Void)? { get set }
    var onAccessStateChange: ((Bool) -> Void)? { get set }
    var onDiagnosticsChange: ((NowPlayingDiagnostics) -> Void)? { get set }
    func start()
    func stop()
    func refresh()
    func setPollingMode(_ mode: NowPlayingPollingMode)
    func togglePlayPause()
    func previousTrack()
    func nextTrack()
}
```

Make both concrete providers conform. Change `NotchViewModel.init` to accept production defaults without changing caller behavior.

`TestDoubles.swift` defines `MemoryAppPreferences`, `FakeCalendarProvider`, `FakeNowPlayingProvider`, and `NowPlayingSnapshot.fixture(...)`; later tasks reuse these exact doubles.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: provider fake tests pass.

### Task 3: Diagnostics, adaptive polling, and semantic publication

**Files:**
- Modify: `Sources/NotchApp/ProviderProtocols.swift`
- Modify: `Sources/NotchApp/NowPlayingProvider.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Create: `Tests/NotchAppTests/NowPlayingProviderTests.swift`
- Extend: `Tests/NotchAppTests/NotchViewModelProviderTests.swift`

**Interfaces:**
- `NowPlayingPollingMode.visibleMusic.interval == 1`, `.background.interval == 5`.
- `NowPlayingDiagnostics(source:applicationName:requiresAccessibilityAccess:lastSuccessfulUpdate:)` is `Equatable`.
- `NowPlayingSnapshot.isSemanticallyEquivalent(to:)` ignores expected clock drift but detects metadata, playback, seek, duration, and artwork changes.

- [ ] **Step 1: Write failing policy and publication tests**

```swift
func testPollingIntervals() {
    XCTAssertEqual(NowPlayingPollingMode.visibleMusic.interval, 1)
    XCTAssertEqual(NowPlayingPollingMode.background.interval, 5)
}

func testExpectedElapsedClockDriftIsSemanticallyEqualButSeekIsNot() {
    let reference = Date(timeIntervalSinceReferenceDate: 1_000)
    let original = NowPlayingSnapshot.fixture(elapsed: 10, updatedAt: reference)
    let normal = NowPlayingSnapshot.fixture(elapsed: 11, updatedAt: reference.addingTimeInterval(1))
    let seek = NowPlayingSnapshot.fixture(elapsed: 40, updatedAt: reference.addingTimeInterval(1))
    XCTAssertTrue(original.isSemanticallyEquivalent(to: normal))
    XCTAssertFalse(original.isSemanticallyEquivalent(to: seek))
}
```

Use a controllable provider test seam to assert that assigning a semantically equal snapshot invokes `onChange` once and a real change invokes it again.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'NowPlayingProviderTests|NotchViewModelProviderTests'` with the shared environment.

- [ ] **Step 3: Implement adaptive mode and diagnostics**

Route every snapshot assignment through `publishSnapshot(_:, source:)`; publish only when the semantic payload changes. Update diagnostics on source/access/application changes and on a newly published successful snapshot. Restart the polling task when mode changes. In the ViewModel set `.visibleMusic` only when expanded, on `.music`, and not showing settings; otherwise set `.background`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2.

### Task 4: In-notch settings and permission recovery

**Files:**
- Create: `Sources/NotchApp/InNotchSettingsView.swift`
- Modify: `Sources/NotchApp/ExpandedNotch.swift`
- Modify: `Sources/NotchApp/MusicPanel.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Modify: `Sources/NotchApp/NotchRootView.swift`
- Test: `Tests/NotchAppTests/NotchViewModelProviderTests.swift`

**Interfaces:**
- Produces: `NotchViewModel.isShowingSettings`, `showSettings()`, `hideSettings()`, `openAccessibilitySettings()`.
- Existing standalone visual-settings window remains reachable from the context menu as `Настройки оформления`; it is not merged into the in-notch screen.

- [ ] **Step 1: Write failing settings-state tests**

```swift
@MainActor
func testSettingsAreTransientAndPreservePrimaryPanel() {
    let preferences = MemoryAppPreferences(lastSelectedPanel: .music)
    let model = makeModel(preferences: preferences)
    model.showSettings()
    XCTAssertTrue(model.isShowingSettings)
    XCTAssertEqual(model.selectedPanel, .music)
    model.hideSettings()
    XCTAssertEqual(preferences.lastSelectedPanel, .music)
}
```

Assert that showing settings switches Now Playing to background polling and returning to visible Music restores foreground polling.

- [ ] **Step 2: Run focused test and verify RED**

Run: `swift test --filter NotchViewModelProviderTests` with the shared environment.

- [ ] **Step 3: Build the approved settings UI**

`ExpandedNotch` header shows a gear when displaying a panel and a back button/title when settings are visible. Hide `PanelSwitcher` and panel content while settings are open. `InNotchSettingsView` uses a `ScrollView`, a 0...1 step-0.1 slider, automatic-last-tab explanation, diagnostic rows, refresh, and open-settings buttons. Observe `NSApplication.didBecomeActiveNotification` to refresh permission state after returning.

Add the same open-settings action beside Refresh in `MusicEmptyState` when Accessibility is required. Use the current macOS Privacy & Security deep link and fall back to opening the Privacy & Security root if the first URL cannot be opened.

- [ ] **Step 4: Run focused tests and Swift build**

Run: focused tests plus `swift build` with the shared environment. Expected: PASS.

### Task 5: Remove continuous idle rendering

**Files:**
- Modify: `Sources/NotchApp/CompactNotch.swift`
- Modify: `Sources/NotchApp/NotchSettingsView.swift`
- Modify: `Sources/NotchApp/OllamaQuotaProvider.swift`
- Create: `Tests/NotchAppTests/IdlePerformancePolicyTests.swift`

**Interfaces:**
- Produces: static `CompactQuotaBorder` glow and test-visible `OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating:)`.
- Preserves existing UserDefaults keys and color/intensity values.

- [ ] **Step 1: Write failing policy/source-regression tests**

```swift
func testWebViewOnlyAttachesDuringAuthentication() {
    XCTAssertFalse(OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating: false))
    XCTAssertTrue(OllamaWebViewAttachmentPolicy.shouldAttach(isAuthenticating: true))
}
```

Add a source regression assertion that `CompactNotch.swift` contains no `TimelineView(.animation`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter IdlePerformancePolicyTests`.

- [ ] **Step 3: Implement static border and detachable WebView**

Remove `TimelineView`, `pulseValue`, and frame-dependent calculations. Render one static glow using the stored intensity. In visual settings relabel the backward-compatible `pulsesLine` control to `Свечение линии` and remove the now-inert speed slider.

Create `attachWebViewForAuthentication()` and `detachWebView()` helpers. `prepare` loads without attaching; `beginAuthentication` attaches; successful page reading and window close detach and stop loading while retaining the WKWebView and default data store.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run focused tests and `swift build`.

### Task 6: Accessibility artwork and Codex error text

**Files:**
- Modify: `Sources/NotchApp/AccessibilityNowPlayingSource.swift`
- Create: `Sources/NotchApp/AccessibilityArtworkLoader.swift`
- Modify: `Sources/NotchApp/NowPlayingProvider.swift`
- Modify: `Sources/NotchApp/CodexQuotaProvider.swift`
- Create: `Tests/NotchAppTests/AccessibilityArtworkLoaderTests.swift`
- Create: `Tests/NotchAppTests/CodexQuotaProviderTests.swift`

**Interfaces:**
- Produces: `AccessibilityArtworkLoader.load(url:) async throws -> Data`, an internal `load(url:fetch:)` overload whose fetch closure returns `(Data, URLResponse)` for deterministic tests, and `CodexQuotaProvider.unavailableMessage(for:)`.
- Artwork callback triggers a semantic snapshot publication only when new bytes arrive.

- [ ] **Step 1: Write failing loader and message tests**

```swift
func testArtworkRejectsHTTPAndOversizedResponses() async {
    do {
        _ = try await AccessibilityArtworkLoader.load(url: URL(string: "http://example.com/a.jpg")!)
        XCTFail("Expected insecure URL rejection")
    } catch {
        XCTAssertEqual(error as? AccessibilityArtworkError, .insecureURL)
    }
}

func testCodexUnavailableMessageInterpolatesError() {
    XCTAssertEqual(CodexQuotaProvider.unavailableMessage(for: StubError()), "Codex app-server: test failure")
}
```

Use an injected `URLSession`/transport in artwork tests to return valid image bytes and a response over 5 MB without external network access.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter 'AccessibilityArtworkLoaderTests|CodexQuotaProviderTests'`.

- [ ] **Step 3: Implement bounded artwork loading and message helper**

Discover an AX image element in the cached metadata subtree. Use inline image data immediately; otherwise pass an HTTPS URL to the loader. Cache data by track ID, cancel the previous artwork task on track change, and refresh through a callback. Reject non-image responses, non-HTTPS URLs, timeouts, and bodies over 5 MB without clearing valid track metadata.

Use `"Codex app-server: \(error.localizedDescription)"` through the tested helper.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2 and the entire unit suite.

### Task 7: Deploy and verify the complete slice

**Files:**
- Update checkboxes/status: `docs/superpowers/plans/2026-08-31-settings-diagnostics-performance.md`
- No new production scope.

- [ ] **Step 1: Run all automated gates once**

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/private/tmp/notch-final-clang \
SWIFT_MODULECACHE_PATH=/private/tmp/notch-final-swift \
swift test
./Tests/Signing/sign-app.test.sh
```

- [ ] **Step 2: Build, sign, and relaunch**

Run: `./scripts/run-app.sh`, then `codesign --verify --deep --strict Build/NotchApp.app`.

- [ ] **Step 3: Verify live UI and behavior**

Open the notch, use the gear/back flow, change hover delay, inspect diagnostics, refresh, open the permission pane, select Music, relaunch, and verify Music is restored. Confirm Yandex Music metadata/controls and that permission recovery still works.

- [ ] **Step 4: Verify idle CPU acceptance**

Collapse the app, move the cursor away, wait 30 seconds, sample the NotchApp process with `ps` and `/usr/bin/sample`. Acceptance: app-process CPU is approximately below 2%, no repeating `CompactQuotaBorder TimelineView`, and Now Playing/Accessibility activity matches the 5-second background cadence.

- [ ] **Step 5: Stop at the approved boundary**

Report test counts, actual CPU measurement, UI/runtime evidence, files changed, and any residual uncertainty. Do not add monitor switching, new panels, or player-specific APIs.
