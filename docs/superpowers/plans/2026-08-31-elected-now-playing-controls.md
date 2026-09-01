# Elected Now Playing Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Music controls to macOS's elected Now Playing player and give the Music panel a non-clipping window size.

**Architecture:** Extend the existing dynamic `MediaRemoteBridge` with elected-player lookup and player-targeted sends, wrapped by a callback-safe testable transport. Centralize compact/standard/Music/Calendar sizing in `NotchWindowSizingPolicy` so SwiftUI content and the AppKit window use the same deterministic size.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, private MediaRemote loaded with `dlopen`/`dlsym`.

**Spec:** `docs/superpowers/specs/2026-08-31-elected-now-playing-controls-design.md`

## Global Constraints

- Deployment target remains macOS 14; add no dependencies or static private-framework linkage.
- Do not use bundle IDs, coordinates, keyboard shortcuts, synthetic media keys, or Accessibility control actions.
- Accessibility remains only a metadata fallback.
- A delivered command requires the targeted-send callback to report `sendError == 0`.
- Preserve existing Limits, Calendar, Settings, metadata, artwork, polling, and hover behavior.
- This directory is not a Git checkout, so commit steps are intentionally omitted.

---

### Task 1: Elected-player MediaRemote transport

**Files:**
- Modify: `Tests/NotchAppTests/NowPlayingProviderTests.swift`
- Modify: `Sources/NotchApp/NowPlayingProvider.swift`

**Interfaces:**
- Produces: `NowPlayingControlCommand.mediaRemoteCommand: UInt32` with ordinals 2, 4, and 5.
- Produces: `NowPlayingCommandDelivery` cases `.delivered`, `.unavailable`, `.noPlayer`, `.rejected(UInt32)`, and `.timedOut`.
- Produces: `ElectedPlayerCommandTransport.init(timeout:getElectedPlayerPath:sendCommand:)` and `send(_:completion:)`.
- Extends: `MediaRemoteBridge.getElectedPlayerPath(completion:) -> Bool` and `send(command:to:completion:) -> Bool`.

- [ ] **Step 1: Replace obsolete shortcut tests with failing targeted-routing tests**

Add XCTest cases that inject an `NSObject` path, capture the raw command and path passed to `sendCommand`, and assert `.delivered`; add separate cases for nil path, nonzero `sendError`, unavailable symbols, and timeout. Use literal expected ordinals 2, 4, and 5.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter NowPlayingProviderTests
```

Expected: compilation fails because `ElectedPlayerCommandTransport` and `NowPlayingCommandDelivery` do not exist. This is the intended feature-missing failure.

- [ ] **Step 3: Implement the minimal targeted transport and MediaRemote ABI bridge**

Remove `NowPlayingCommandRouter`, `PlayerShortcutEvent`, and `PlayerShortcutTransport`. Add the command mapping and a main-actor transport whose one-shot resolver ignores late callbacks after timeout. Resolve these symbols dynamically:

```text
MRMediaRemoteGetElectedPlayerPath
MRMediaRemoteSendCommandToPlayer
```

Call targeted send as `(command, nil, path, 0, .main, callback)` and map callback error zero to `.delivered`. Update `NowPlayingProvider.executeControlCommand` to schedule its existing 350 ms refresh only after `.delivered`; do not call `AccessibilityNowPlayingSource.perform`.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter NowPlayingProviderTests
```

Expected: all `NowPlayingProviderTests` pass with no shortcut-event assertions remaining.

---

### Task 2: Shared Music window sizing

**Files:**
- Modify: `Tests/NotchAppTests/NotchInteractionTests.swift`
- Modify: `Sources/NotchApp/NotchSharedUI.swift`
- Modify: `Sources/NotchApp/NotchRootView.swift`
- Modify: `Sources/NotchApp/ExpandedNotch.swift`
- Modify: `Sources/NotchApp/NotchWindowCoordinator.swift`

**Interfaces:**
- Produces: `NotchLayoutMetrics.expandedMusicSize` equal to 500×380 with a physical notch and 500×404 without one.
- Produces: `NotchWindowSizingPolicy.size(metrics:isExpanded:selectedPanel:calendarViewMode:isShowingSettings:) -> CGSize`.
- Consumes: existing `PanelID`, `CalendarViewMode`, compact/standard/Calendar metrics.

- [ ] **Step 1: Add failing Music sizing tests**

Add literal assertions for notched and no-notch `expandedMusicSize`. Add policy tests proving expanded Music uses that size, Music Settings uses standard size, Calendar month preserves Calendar size, Limits preserves standard size, and collapsed state preserves compact size.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter NotchInteractionTests
```

Expected: compilation fails because `expandedMusicSize` and the unified `size(...)` policy do not exist.

- [ ] **Step 3: Implement the minimal sizing policy and use it at all three size consumers**

Add deterministic Music metrics and the pure sizing function. Replace the duplicated Calendar-only branches in `NotchRootView.currentSize`, `ExpandedNotch.expandedSize`, and `NotchWindowCoordinator.animateWindow` with calls to that function using the same current metrics.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter NotchInteractionTests
```

Expected: all interaction/layout tests pass, including unchanged standard and Calendar literals.

---

### Task 3: Verification and live acceptance

**Files:**
- Verify: all modified source and test files
- Verify: `Build/NotchApp.app`

**Interfaces:**
- Consumes: the elected-player transport and unified sizing policy from Tasks 1 and 2.
- Produces: automated and current runtime evidence for the acceptance criteria.

- [ ] **Step 1: Run the full suite**

Run:

```bash
swift test
```

Expected: zero failures.

- [ ] **Step 2: Build, bundle, sign, and launch the app**

Run the existing `scripts/run-app.sh`, then verify the signed bundle with:

```bash
codesign --verify --deep --strict Build/NotchApp.app
```

Expected: build and launch succeed; strict signature verification exits zero.

- [ ] **Step 3: Verify the visible Music layout and controls**

In the stable expanded Music state, confirm the title and gear are fully visible. With Yandex Music elected and playing, click Pause, Next, and Previous through the NotchApp controls and confirm the player state/track changes after every action.

- [ ] **Step 4: Stop at the acceptance boundary**

Report any command that did not receive current live proof as unverified. Do not add retries, alternate transports, new controls, or unrelated UI changes.
