# Jira Pinned Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add persistent pinned Jira projects, boards, and issues with a lazy-loaded `Закреплённые` mode inside the existing Jira panel.

**Architecture:** Keep the existing `Мои` query untouched. Add typed Codable pin models, separate pinned provider state/cache, Jira Platform and Agile API methods, focused Settings UI, and a source switcher inside `JiraPanel`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, URLSession, Jira Data Center REST API, UserDefaults.

**Spec:** `docs/superpowers/specs/2026-09-02-jira-pinned-sources-design.md`

## Global Constraints

- Do not change the existing `Мои` JQL or current project filter behavior.
- Board results contain every issue returned by the board filter that the account may view.
- Project results contain every Jira issue for the selected project without assignee, resolution, or status clauses.
- Load and cache only the selected pinned source.
- Preserve inaccessible pins and isolate errors per source.
- Reuse existing Jira issue-row actions and tracked popover lifecycle.
- Per user direction, skip TDD; compile after each coherent slice and leave live acceptance to the user.

---

### Task 1: Pin models and persistence

**Files:**
- Create: `Sources/NotchApp/JiraPinnedModels.swift`
- Modify: `Sources/NotchApp/AppPreferences.swift`
- Modify: `Tests/NotchAppTests/TestDoubles.swift` only if compilation requires protocol conformance updates

**Interfaces:**
- Produces: `JiraBoard`, `JiraPinnedContainer`, `JiraPinnedIssue`, `JiraPinnedSourceID`, `JiraPinnedSourceState`, `JiraPinnedState`.
- Produces preferences: `jiraPinnedContainers: [JiraPinnedContainer]`, `jiraPinnedIssues: [JiraPinnedIssue]`.

- [ ] Define Codable, Hashable, Identifiable models with stable IDs (`project:<key>`, `board:<id>`, `issue:<key>`).
- [ ] Add version-tolerant JSON persistence helpers to `UserDefaultsAppPreferences`; invalid entries decode as an empty list without affecting other settings.
- [ ] Update in-memory preference test doubles so the project builds.
- [ ] Run `swift build --disable-sandbox` with the Xcode-beta toolchain.

### Task 2: Jira catalog and issue APIs

**Files:**
- Modify: `Sources/NotchApp/JiraClient.swift`

**Interfaces:**
- Produces:
  - `boards(baseURL:token:) async throws -> [JiraBoard]`
  - `boardIssues(baseURL:token:boardID:) async throws -> JiraSearchPage`
  - `projectIssues(baseURL:token:projectKey:) async throws -> JiraSearchPage`
  - `issue(baseURL:token:issueKey:) async throws -> JiraIssue`

- [ ] Generalize search request paging with `startAt`, `maxResults`, and the existing field list.
- [ ] Implement all-board pagination using `GET /rest/agile/1.0/board` and preserve base paths.
- [ ] Implement board issue pagination using `GET /rest/agile/1.0/board/{id}/issue`.
- [ ] Implement project issue pagination using POST search and JQL `project = "KEY" ORDER BY priority DESC, updated DESC`.
- [ ] Implement direct issue resolution using `GET /rest/api/2/issue/{key}`.
- [ ] Deduplicate issue keys while preserving API order and stop safely on empty pages.
- [ ] Run `swift build --disable-sandbox`.

### Task 3: Independent pinned provider state

**Files:**
- Modify: `Sources/NotchApp/ProviderProtocols.swift`
- Modify: `Sources/NotchApp/JiraProvider.swift`
- Modify: `Sources/NotchApp/NotchViewModel.swift`

**Interfaces:**
- Produces provider actions for catalog refresh, pin/unpin/reorder, pinned source selection, pinned refresh, and issue-key pinning.
- Publishes all pinned state inside `JiraProviderState.pinned` without replacing `JiraProviderState.list`.

- [ ] Initialize pins from preferences during provider start and preserve them during disconnect.
- [ ] Load project and board catalogs independently of the current-user issue query.
- [ ] Add per-source generation/task dictionaries and cache states.
- [ ] Load only the selected source; board/project calls use their dedicated client methods and individual issue pins resolve independently.
- [ ] Invalidate caches on connection changes, preserve configured pins, and reject stale task results.
- [ ] Update transitioned issue status in both `Мои` and every cached pinned result containing the issue.
- [ ] Expose narrow forwarding methods on `NotchViewModel`.
- [ ] Run `swift build --disable-sandbox`.

### Task 4: Jira Settings pin management

**Files:**
- Create: `Sources/NotchApp/JiraPinnedSettingsView.swift`
- Modify: `Sources/NotchApp/NotchSettingsView.swift`

**Interfaces:**
- Consumes provider catalog and pin actions from Task 3.
- Produces a Settings card for searchable project/board pins and a card for issue-key pins.

- [ ] Add catalog refresh on Jira Settings appearance after connection.
- [ ] Build one searchable project/board list with explicit type labels and pin toggles.
- [ ] Build normalized issue-key input, validation/loading/error states, and the pinned issue list.
- [ ] Add remove and up/down ordering controls for both lists.
- [ ] Use the existing Settings visual language and 40-point interaction targets.
- [ ] Ensure new popovers, if used, register through `NotchTransientSurface`.
- [ ] Run `swift build --disable-sandbox`.

### Task 5: `Мои / Закреплённые` Jira mode

**Files:**
- Create: `Sources/NotchApp/JiraPinnedPanel.swift`
- Modify: `Sources/NotchApp/JiraPanel.swift`

**Interfaces:**
- Consumes `JiraPinnedState`, selected-source actions, refresh, and existing `JiraIssueRow` behavior.
- Produces `JiraPanelMode` with `.mine` and `.pinned` session state.

- [ ] Add a compact mode switch to the Jira task header without changing the outer panel size.
- [ ] Add horizontally scrollable source controls: `Задачи` first, then stored projects/boards.
- [ ] Render cached/loaded/loading/error/empty states independently per source.
- [ ] Reuse a shared issue-list/row path so worklog, transition, copy, and browser actions remain identical.
- [ ] Auto-select the nearest source after removal and show a Settings action when no pins exist.
- [ ] Manual refresh reloads only the selected pinned source.
- [ ] Run `swift build --disable-sandbox` and `git diff --check`.

### Task 6: Package and manual handoff

**Files:**
- Modify only files required by compiler integration.

- [ ] Run `./scripts/run-app.sh` to build, sign, and relaunch the app.
- [ ] Verify `codesign --verify --deep --strict Build/NotchApp.app`.
- [ ] Hand off the live acceptance sequence from the spec to the user.
- [ ] After acceptance, commit all intended source changes, push the branch, and run the repository's existing Homebrew release workflow.
