# AI Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the top-level limits panel with an AI panel that preserves quotas and adds a source-neutral live Codex Desktop session list with click-to-open navigation.

**Architecture:** A generic `AISessionSource` publishes complete snapshots into a main-actor `AISessionStore`. `CodexDesktopSessionSource` combines read-only Codex SQLite/rollout discovery with a minimal app-server JSON-RPC client; SwiftUI consumes only normalized state through `NotchViewModel`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Combine, SQLite3, Foundation `Process`, newline-delimited JSON-RPC, UserDefaults.

**Spec:** `docs/superpowers/specs/2026-09-02-ai-sessions-design.md`

## Global Constraints

- First release supports Codex Desktop only, but the store and UI must remain independent of Codex-specific types.
- Codex files are read-only; do not modify hooks, Codex configuration, task state, approvals, or user-input requests.
- Do not publish or log prompt/reply bodies, credentials, tokens, or full local paths.
- Show every active/attention session plus at most 10 inactive non-archived sessions.
- Keep the same expanded window size for `AI → Лимиты` and `AI → Сессии`; only `NotchWindowCoordinator` owns `NSPanel.frame`.
- Preserve legacy panel preferences by mapping stored raw value `limits` to `ai`; retain existing quota keys under `limits.*`.
- Per user direction, implement first without a TDD cycle; add focused regression tests after coherent production slices and leave final visual acceptance to the user.

---

### Task 1: Source-neutral session model and store

**Files:**
- Create: `Sources/NotchApp/AISession.swift`
- Create: `Sources/NotchApp/AISessionSource.swift`
- Create: `Sources/NotchApp/AISessionStore.swift`
- Create: `Tests/NotchAppTests/AISessionStoreTests.swift`

**Interfaces:**
- Produces `AISessionID`, `AISession`, `AISessionStatus`, `AISessionSourceHealth`, and `AISessionSourceSnapshot`.
- Produces `AISessionSource.snapshots() -> AsyncStream<AISessionSourceSnapshot>` and `open(sessionID:) async -> Bool`.
- Produces `@MainActor AISessionStore` with published `sessions`, `sourceHealth`, `attentionCount`, `start()`, and `open(_:)`.

- [x] **Step 1: Implement normalized domain types.**

```swift
struct AISessionID: Hashable, Sendable {
    let sourceID: String
    let sessionID: String
}

enum AISessionStatus: Sendable {
    case running, waitingForApproval, waitingForInput
    case completed, failed, unknown
}
```

- [x] **Step 2: Implement the async snapshot source contract and store lifecycle.** Register sources by stable ID, consume one task per source, replace only that source's snapshot, preserve other sources, and route open requests to the owning source.
- [x] **Step 3: Implement deterministic presentation.** Sort approval, input, running, failed, then inactive by descending activity; keep all active/attention rows and only the first 10 inactive rows.
- [x] **Step 4: Add post-implementation tests.** Cover merge isolation, same raw ID from different sources, snapshot replacement, sort priority, inactive limit, attention count, and open routing with a fake `AISessionSource`.
- [x] **Step 5: Run the focused test.**

```sh
xcrun swift test --filter AISessionStoreTests
```

Expected: all store tests pass.

### Task 2: Codex read-only discovery and live adapter

**Files:**
- Modify: `Package.swift`
- Create: `Sources/NotchApp/CodexStateReader.swift`
- Create: `Sources/NotchApp/CodexAppServerClient.swift`
- Create: `Sources/NotchApp/CodexDesktopSessionSource.swift`
- Create: `Tests/NotchAppTests/CodexDesktopSessionTests.swift`

**Interfaces:**
- Consumes the source contract from Task 1.
- Produces `CodexStateReader.loadSessions(now:) -> [AISession]` using `$CODEX_HOME/state_5.sqlite` or `~/.codex/state_5.sqlite`.
- Produces `CodexAppServerClient` with `start()`, `stop()`, handshake, line framing, and typed callback messages.
- Produces `CodexDesktopSessionSource: AISessionSource` with source ID `codex-desktop`.

- [x] **Step 1: Link SQLite3 and implement a read-only query.** Open with `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`, introspect `threads`, accept optional columns, filter archived/CLI rows, and bind all values rather than interpolating user data.
- [x] **Step 2: Implement bounded rollout-tail status parsing.** Read only the final bounded byte range and map the newest complete lifecycle marker to running/completed without retaining event content.
- [x] **Step 3: Implement minimal newline JSON-RPC transport.** Discover the executable from the running `com.openai.codex` bundle, launch `codex app-server --listen stdio://`, drain stdout/stderr safely, buffer partial lines, and terminate cleanly.
- [x] **Step 4: Implement live status reconciliation.** Map `thread/started`, `thread/status/changed`, and `thread/closed`; give live status precedence while keeping database title/workspace metadata; never answer server requests.
- [x] **Step 5: Implement source lifecycle and recovery.** Observe Codex launch/terminate, scan periodically off the main actor, preserve stale snapshots on failure, and reconnect with capped backoff.
- [x] **Step 6: Implement click-to-open.** Percent-encode the thread ID into `codex://threads/<id>`, call an injected opener seam, and fall back to activating bundle ID `com.openai.codex`.
- [x] **Step 7: Add post-implementation tests.** Use temporary SQLite and rollout fixtures for filtering/status; test JSON-RPC complete/partial lines, status mapping, executable discovery, URL construction, and stale snapshot preservation without launching the real Codex process.
- [x] **Step 8: Run focused adapter tests.**

```sh
xcrun swift test --filter CodexDesktopSessionTests
```

Expected: all adapter tests pass without writing under `~/.codex`.

### Task 3: AI preferences, view model, and panel UI

**Files:**
- Modify: `Sources/NotchApp/NotchSharedUI.swift`
- Modify: `Sources/NotchApp/AppPreferences.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`
- Modify: `Sources/NotchApp/ExpandedNotch.swift`
- Create: `Sources/NotchApp/AIPanel.swift`
- Create: `Sources/NotchApp/AISessionsPanel.swift`
- Modify: `Tests/NotchAppTests/AppPreferencesTests.swift`
- Modify: `Tests/NotchAppTests/TestDoubles.swift`
- Modify: focused view-model tests as compilation and behavior require.

**Interfaces:**
- Consumes `AISessionStore` and `CodexDesktopSessionSource` from Tasks 1-2.
- Produces `PanelID.ai`, `AISection.limits`, `AISection.sessions`, persisted `selectedAISection`, session rows, badge precedence, and row-open/collapse behavior.

- [x] **Step 1: Add preference migration.** Decode `limits` as `.ai` for scalar, array, and set panel preferences, write only `ai`, preserve `limits.*` quota keys, and persist `AISection` under `ai.selectedSection` with default `.limits`.
- [x] **Step 2: Integrate the store into `NotchViewModel`.** Start it once during initialization, expose normalized sessions/health/attention, update `lastUpdatedAt(for:)`, give attention count badge precedence over quota warnings, and add `openAISession(_:)` that collapses only after success.
- [x] **Step 3: Replace the panel identity.** Change switch statements and fallback values from `.limits` to `.ai`; keep quota refresh behavior active for the AI panel.
- [x] **Step 4: Build `AIPanel`.** Add an accessible compact segmented switch and embed the unchanged `LimitsPanel` or the sessions view inside one fixed-size container.
- [x] **Step 5: Build `AISessionsPanel`.** Render Russian status labels/colors, title, workspace basename, relative activity, source health, loading/empty/error states, and full-row click targets.
- [x] **Step 6: Add post-implementation preference/view-model tests.** Cover all legacy `limits` migrations, AI-section round trip/default, badge precedence, and successful-versus-failed open collapse.
- [x] **Step 7: Run focused integration tests.**

```sh
xcrun swift test --filter AppPreferencesTests
xcrun swift test --filter NotchViewModelProviderTests
```

Expected: preference migration and model behavior pass.

### Task 4: Changelog, complete verification, and live handoff

**Files:**
- Modify: `CHANGELOG.md`
- Modify: implementation plan checkboxes as tasks complete.

**Interfaces:**
- Consumes all preceding tasks.
- Produces a buildable feature ready for the user's manual AppKit validation.

- [x] **Step 1: Add the user-visible change under `Unreleased`.** Mention `AI → Лимиты / Сессии`, live Codex Desktop status, exact task opening, and the source abstraction.
- [x] **Step 2: Run repository hygiene and build.**

```sh
git diff --check
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: no whitespace errors and a successful debug build.

- [x] **Step 3: Run the complete Swift test suite.**

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test
```

Observed: the AI/session tests and every suite outside the pre-existing
`JiraProviderTests` failures pass. The full run still reports the same 21
baseline Jira provider failures and is recorded as a known unrelated gate.

- [x] **Step 4: Build and relaunch for manual validation.**

```sh
./scripts/run-app.sh
```

Expected: `Build/NotchApp.app` launches with the `AI` panel. If signing would require ad-hoc mode, stop and leave relaunch to the user rather than changing signing identity.

- [x] **Step 5: Hand off the manual acceptance sequence.** Verify session status transitions, the 10-inactive limit, exact task navigation, preference persistence, Codex reconnect, and no frame jump when switching or collapsing.

- [x] **Step 6: Commit only after build/test evidence is known.**

```sh
git add Package.swift Sources/NotchApp Tests/NotchAppTests CHANGELOG.md docs/superpowers/plans/2026-09-02-ai-sessions.md
git commit -m "feat(ai): add Codex desktop sessions"
```
