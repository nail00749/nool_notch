# Compact Agent Mascot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show an original pixel-art Nool mascot to the right of the collapsed notch when an AI session needs attention, fails, or has just completed.

**Architecture:** A source-neutral main-actor controller converts normalized `AISession` snapshots into one prioritized ephemeral `CompactAgentSignal`. `NotchViewModel` publishes that signal, `CompactNotch` renders an asset-free pixel mascot, and the existing coordinator grows the compact panel symmetrically so the physical notch remains centered.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Combine, `Canvas`, `TimelineView`, existing `AISessionStore` and `NotchWindowCoordinator`.

**Spec:** `docs/superpowers/specs/2026-09-03-compact-agent-mascot-design.md`

## Global Constraints

- Support every normalized `AISessionSource`; do not add Codex-specific logic to compact UI state.
- Do not retain or display prompts, replies, approval content, credentials, or full workspace paths.
- Historical completed and failed sessions present at startup must not create terminal notifications.
- Waiting states persist until resolved, newly failed states persist until acknowledged, and completion states expire after exactly 15 seconds.
- Signal priority is approval, input, failed, then completed; ties use newest activity or observation date.
- Render an original code-owned pixel character without SVG, Lottie, SceneKit, Metal, remote assets, or new dependencies.
- Use a 32-point visible mascot inside a minimum 40-by-40-point target and a 48-point right lane mirrored by a transparent 48-point left lane.
- `NotchWindowCoordinator` remains the only owner of `NSPanel.frame`; keep `NSHostingView.sizingOptions = []`.
- Respect Reduce Motion by showing one static pose without frame animation.
- If the user has hidden the top-level AI panel, suppress the mascot rather than silently changing their saved panel visibility.
- Per explicit user direction, add no TDD cycle and no new automated tests for this first version. Verification is `git diff --check`, `swift build`, relaunch, and user-owned manual AppKit validation.
- Preserve all existing uncommitted Jira work. Do not stash, reset, or include it in a mascot commit without explicit user approval.

---

### Task 1: Source-neutral signal controller

**Files:**
- Create: `Sources/NotchApp/CompactAgentSignal.swift`

**Interfaces:**
- Consumes: complete `[AISession]` presentations from `AISessionStore` plus a `hasReceivedSnapshot` flag.
- Produces: `CompactAgentSignalKind`, `CompactAgentSignal`, and `@MainActor CompactAgentSignalController`.
- Produces exact controller API: `var onChange: ((CompactAgentSignal?) -> Void)?`, `func consume(_ sessions: [AISession], hasReceivedSnapshot: Bool)`, and `func acknowledge(_ signal: CompactAgentSignal)`.

- [x] **Step 1: Define the presentation types and stable signal identity.**

```swift
enum CompactAgentSignalKind: Int, Hashable, Sendable {
    case waitingForApproval
    case waitingForInput
    case failed
    case completed

    var priority: Int { rawValue }
}

struct CompactAgentSignal: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let sessionID: AISessionID
        let kind: CompactAgentSignalKind
    }

    let sessionID: AISessionID
    let kind: CompactAgentSignalKind
    let observedAt: Date
    var id: ID { ID(sessionID: sessionID, kind: kind) }
}
```

- [x] **Step 2: Implement snapshot seeding and transition detection.** Keep `knownStatuses`, `currentSessions`, terminal signals, and completion expiry tasks inside one `@MainActor` controller. Ignore calls while `hasReceivedSnapshot == false`; on the first real snapshot seed status history and derive only live waiting candidates.

```swift
@MainActor
final class CompactAgentSignalController {
    var onChange: ((CompactAgentSignal?) -> Void)?

    private var hasSeeded = false
    private var knownStatuses: [AISessionID: AISessionStatus] = [:]
    private var currentSessions: [AISessionID: AISession] = [:]
    private var terminalSignals: [CompactAgentSignal.ID: CompactAgentSignal] = [:]
    private var completionTasks: [AISessionID: Task<Void, Never>] = [:]
    private var currentSignal: CompactAgentSignal?

    func consume(_ sessions: [AISession], hasReceivedSnapshot: Bool) {
        guard hasReceivedSnapshot else { return }
        let incoming = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        if hasSeeded == false {
            hasSeeded = true
            knownStatuses = incoming.mapValues(\.status)
            currentSessions = incoming
            publishBestSignal()
            return
        }

        for session in sessions {
            let previous = knownStatuses[session.id]
            if session.status == .completed, previous?.isActive == true {
                publishCompletion(for: session)
            } else if session.status == .failed,
                      previous != nil,
                      previous != .failed {
                let signal = CompactAgentSignal(
                    sessionID: session.id,
                    kind: .failed,
                    observedAt: .now
                )
                terminalSignals[signal.id] = signal
            }
        }

        knownStatuses = incoming.mapValues(\.status)
        currentSessions = incoming
        publishBestSignal()
    }
}
```

- [x] **Step 3: Implement prioritized selection.** Generate waiting candidates directly from current sessions, append stored failed/completed terminal signals, then sort by kind priority and descending `observedAt`. Call `onChange` only when the selected signal actually changes.

```swift
private func waitingSignal(for session: AISession) -> CompactAgentSignal? {
    let kind: CompactAgentSignalKind
    switch session.status {
    case .waitingForApproval: kind = .waitingForApproval
    case .waitingForInput: kind = .waitingForInput
    default: return nil
    }
    return CompactAgentSignal(
        sessionID: session.id,
        kind: kind,
        observedAt: session.lastActivity
    )
}

private func publishBestSignal() {
    let candidates = currentSessions.values.compactMap(waitingSignal)
        + Array(terminalSignals.values)
    let next = candidates.sorted {
        if $0.kind.priority != $1.kind.priority {
            return $0.kind.priority < $1.kind.priority
        }
        return $0.observedAt > $1.observedAt
    }.first
    guard next != currentSignal else { return }
    currentSignal = next
    onChange?(next)
}
```

- [x] **Step 4: Implement terminal lifetime and acknowledgement.** For completion, cancel any prior task for that session, store a signal token, sleep for 15 seconds, and remove only the same token so an old task cannot erase a newer event. `acknowledge` removes only a matching failed terminal signal, then recomputes the next candidate.

```swift
private func publishCompletion(for session: AISession) {
    completionTasks[session.id]?.cancel()
    let signal = CompactAgentSignal(
        sessionID: session.id,
        kind: .completed,
        observedAt: .now
    )
    terminalSignals[signal.id] = signal
    completionTasks[session.id] = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard Task.isCancelled == false,
              self?.terminalSignals[signal.id] == signal else { return }
        self?.terminalSignals[signal.id] = nil
        self?.completionTasks[session.id] = nil
        self?.publishBestSignal()
    }
}

func acknowledge(_ signal: CompactAgentSignal) {
    guard signal.kind == .failed,
          terminalSignals[signal.id] == signal else { return }
    terminalSignals[signal.id] = nil
    publishBestSignal()
}
```

- [x] **Step 5: Compile the isolated production slice.**

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: the new source-neutral types compile without changing session adapters.

---

### Task 2: View-model integration and click command

**Files:**
- Modify: `Sources/NotchApp/NotchViewModel.swift`

**Interfaces:**
- Consumes: `CompactAgentSignalController` from Task 1 and existing `AISessionStore.$sessions`.
- Produces: `@Published private(set) var compactAgentSignal: CompactAgentSignal?`.
- Produces: `var visibleCompactAgentSignal: CompactAgentSignal?` and `func openCompactAgentSessions()`.

- [x] **Step 1: Own and bind one controller for the application lifetime.** Initialize it before establishing Combine subscriptions and publish its `onChange` output on the main actor.

```swift
@Published private(set) var compactAgentSignal: CompactAgentSignal?
private let compactAgentSignalController: CompactAgentSignalController

// In init, before aiSessionStore subscriptions:
self.compactAgentSignalController = CompactAgentSignalController()
compactAgentSignalController.onChange = { [weak self] signal in
    self?.compactAgentSignal = signal
}
```

- [x] **Step 2: Feed normalized snapshots through the existing session subscription.** Treat `aiSessionStore.lastUpdatedAt != nil` as proof that at least one real source snapshot has been applied; this prevents the initial Combine `[]` value from seeding terminal history incorrectly.

```swift
aiSessionStore.$sessions
    .sink { [weak self] sessions in
        guard let self else { return }
        self.aiSessions = sessions
        self.compactAgentSignalController.consume(
            sessions,
            hasReceivedSnapshot: self.aiSessionStore.lastUpdatedAt != nil
        )
    }
    .store(in: &cancellables)
```

- [x] **Step 3: Suppress presentation when `.ai` is hidden and implement click routing.** Do not mutate `hiddenPanelIDs`. A visible mascot click acknowledges the selected failed event, cancels scheduled collapse, chooses `.ai` and `.sessions`, and expands.

```swift
var visibleCompactAgentSignal: CompactAgentSignal? {
    visiblePanels.contains(.ai) ? compactAgentSignal : nil
}

func openCompactAgentSessions() {
    guard let signal = visibleCompactAgentSignal else { return }
    compactAgentSignalController.acknowledge(signal)
    cancelScheduledCollapse()
    selectPanel(.ai)
    selectAISection(.sessions)
    isExpanded = true
}
```

- [x] **Step 4: Build after integrating the session lifecycle.**

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: the current AI sessions panel behaves unchanged and the view model exposes one optional compact signal.

---

### Task 3: Original pixel-art Nool view

**Files:**
- Create: `Sources/NotchApp/CompactAgentMascot.swift`

**Interfaces:**
- Consumes: `CompactAgentSignal` and `accessibilityReduceMotion`.
- Produces: `CompactAgentMascot(signal:)`, a 32-by-32-point visual intended for a 40-by-40-point button target.

- [x] **Step 1: Define a compact original palette and semantic glyphs.** Use the existing signal colors for the adjacent glyph while keeping a neutral cyan/mint body. Map approval to `!`, input to `?`, failed to `!`, and completed to a checkmark.

```swift
private extension CompactAgentSignalKind {
    var accentColor: Color {
        switch self {
        case .waitingForApproval: .signalAmber
        case .waitingForInput: .signalCyan
        case .failed: .signalCoral
        case .completed: .signalMint
        }
    }

    var glyph: String {
        switch self {
        case .waitingForInput: "?"
        case .completed: "✓"
        case .waitingForApproval, .failed: "!"
        }
    }
}
```

- [x] **Step 2: Draw the mascot from integral pixel rectangles.** Use a 2-point logical pixel and an internal 16-by-16 grid. Keep the body recognizable in every frame: square head with two eyes, compact torso, two legs, and one arm whose cells differ by pose.

```swift
private struct PixelCell {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let color: Color
}

private func draw(_ cells: [PixelCell], in context: inout GraphicsContext) {
    for cell in cells {
        context.fill(
            Path(CGRect(
                x: cell.x * 2,
                y: cell.y * 2,
                width: cell.width * 2,
                height: cell.height * 2
            )),
            with: .color(cell.color)
        )
    }
}

private let baseCells = [
    PixelCell(x: 4, y: 2, width: 7, height: 1, color: .signalCyan),
    PixelCell(x: 3, y: 3, width: 9, height: 5, color: .signalCyan),
    PixelCell(x: 5, y: 5, width: 1, height: 1, color: .black),
    PixelCell(x: 9, y: 5, width: 1, height: 1, color: .black),
    PixelCell(x: 5, y: 8, width: 5, height: 4, color: .signalMint),
    PixelCell(x: 4, y: 12, width: 2, height: 2, color: .signalMint),
    PixelCell(x: 9, y: 12, width: 2, height: 2, color: .signalMint)
]

private let armFrames = [
    [PixelCell(x: 2, y: 8, width: 2, height: 4, color: .signalMint)],
    [PixelCell(x: 1, y: 6, width: 2, height: 4, color: .signalMint)],
    [PixelCell(x: 1, y: 3, width: 2, height: 4, color: .signalMint)],
    [PixelCell(x: 1, y: 6, width: 2, height: 4, color: .signalMint)]
]
```

- [x] **Step 3: Add a calm periodic wave with two alternate arm poses.** `TimelineView(.periodic(from: .now, by: 0.28))` exists only while the mascot view is mounted. Use the time slot modulo 12 so most frames are calm and three frames form one wave. Reduce Motion always renders frame zero.

```swift
TimelineView(.periodic(from: .now, by: 0.28)) { timeline in
    let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 0.28) % 12
    let frame = reduceMotion ? 0 : (tick >= 9 ? tick - 8 : 0)
    PixelNoolCanvas(frame: frame, kind: signal.kind)
}
```

- [x] **Step 4: Add a semantic status bubble and accessibility copy.** Keep the bubble visually separate from the body and expose one combined label such as `Агент ждёт подтверждения` rather than reading individual decorative pixels.

- [x] **Step 5: Compile the rendering slice.**

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: SwiftUI compiles with no new asset catalog or package dependency.

---

### Task 4: Symmetric compact geometry and separate buttons

**Files:**
- Modify: `Sources/NotchApp/NotchSharedUI.swift`
- Modify: `Sources/NotchApp/CompactNotch.swift`
- Modify: `Sources/NotchApp/NotchRootView.swift`
- Modify: `Sources/NotchApp/NotchWindowCoordinator.swift`

**Interfaces:**
- Consumes: `NotchViewModel.visibleCompactAgentSignal` and `CompactAgentMascot`.
- Changes exact sizing API by adding `showsAgentMascot: Bool = false` to `NotchLayoutMetrics.compactSize`, `NotchLayout.compactSize`, and `NotchWindowSizingPolicy.size`.
- Produces: a total compact width equal to base width plus `96` points when the 48-point mirrored mascot lanes are present.

- [x] **Step 1: Extend layout calculations with a defaulted mascot flag.** Compute the existing base size unchanged, then add paired lanes only to width. Defaults keep all existing call sites source-compatible.

```swift
static let compactAgentMascotLaneWidth: CGFloat = 48

private func baseCompactSize(
    isPlaying: Bool,
    compactHeight: CGFloat
) -> CGSize {
    let interactionHeight = max(NotchLayout.compactInteractionHeight, compactHeight)
    guard physicalNotchSize.width > 0, physicalNotchSize.height > 0 else {
        return CGSize(width: NotchLayout.compactContentWidth, height: interactionHeight)
    }
    guard isPlaying else {
        return CGSize(
            width: physicalNotchSize.width + NotchLayout.compactIdleWingWidth * 2,
            height: max(interactionHeight, physicalNotchSize.height)
        )
    }
    return CGSize(
        width: physicalNotchSize.width + NotchLayout.compactWingWidth * 2,
        height: max(interactionHeight, physicalNotchSize.height)
    )
}

func compactSize(
    isPlaying: Bool,
    compactHeight: CGFloat = NotchLayout.defaultCompactHeight,
    showsAgentMascot: Bool = false
) -> CGSize {
    let baseSize = baseCompactSize(
        isPlaying: isPlaying,
        compactHeight: compactHeight
    )
    guard showsAgentMascot else { return baseSize }
    return CGSize(
        width: baseSize.width + NotchLayout.compactAgentMascotLaneWidth * 2,
        height: baseSize.height
    )
}
```

- [x] **Step 2: Split `CompactNotch` into sibling controls.** Preserve the existing notch button and its black clipped background as `notchButton`. When a signal exists, place a non-hit-testing transparent lane before it and a separate mascot button after it.

```swift
HStack(spacing: 0) {
    if signal != nil {
        Color.clear
            .frame(width: NotchLayout.compactAgentMascotLaneWidth)
            .allowsHitTesting(false)
    }

    notchButton
        .frame(width: baseCompactSize.width, height: baseCompactSize.height)

    if let signal {
        Button(action: model.openCompactAgentSessions) {
            CompactAgentMascot(signal: signal)
                .frame(width: 32, height: 32)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(NotchButtonStyle())
        .frame(width: NotchLayout.compactAgentMascotLaneWidth)
    }
}
```

- [x] **Step 3: Keep the mascot beside rather than inside the black notch surface.** Apply black background, notch corner clipping, quota border, and compositing only to `notchButton`; the outer symmetric `HStack` remains transparent.

- [x] **Step 4: Include mascot visibility everywhere compact size is calculated.** Pass `model.visibleCompactAgentSignal != nil` from `NotchRootView.currentSize`, the compact pointer-collapse frame, `CompactNotch`, and `NotchWindowCoordinator.animateWindow`.

```swift
showsAgentMascot: model.visibleCompactAgentSignal != nil
```

- [x] **Step 5: Trigger coordinator sizing on presentation changes.** Observe the optional signal identity, not animation frame changes, so the panel resizes only when the mascot appears, disappears, or switches semantic event.

```swift
.onChange(of: model.visibleCompactAgentSignal?.id) { _, _ in
    onLayoutChange(model.isExpanded, reduceMotion)
}
```

- [x] **Step 6: Preserve top-center anchoring during width animation.** Keep `NotchWindowCoordinator.origin(for:size:)` unchanged; symmetric width growth means `screenFrame.midX - size.width / 2` retains the same center at every interpolated frame. Do not restore hosting-view automatic sizing.

- [x] **Step 7: Compile the complete geometry integration.**

```sh
git diff --check
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: no whitespace errors and a successful build with existing compact-size call sites preserved by default parameters.

---

### Task 5: Changelog, relaunch, and manual acceptance handoff

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-09-03-compact-agent-mascot.md` only to check completed steps.

**Interfaces:**
- Consumes: complete Tasks 1-4.
- Produces: a locally running build ready for user-owned live status checks.

- [x] **Step 1: Add one user-facing `Added` entry under `Unreleased`.** Keep existing Jira entries untouched.

```markdown
### Added

- В свёрнутой челке появился пиксельный маскот Nool, который сообщает о
  завершении AI-сессии или необходимости внимания и открывает `AI -> Сессии`.
```

If `Unreleased` already has `Added`, append the bullet there rather than creating a duplicate heading.

- [x] **Step 2: Run the approved repository checks without tests.**

```sh
git diff --check
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift build
```

Expected: zero diff-check errors and `Build complete!`. Do not claim that automated tests pass because they are intentionally not run.

- [x] **Step 3: Rebuild, sign with the existing mode, and relaunch.**

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/run-app.sh
```

Expected: `Build/NotchApp.app` is replaced and launched. Do not opt into ad-hoc signing unless separately authorized.

- [x] **Step 4: Hand off the exact manual scenarios.** Ask the user to validate startup suppression, approval, input, completed 15-second expiry, failed acknowledgement, simultaneous-state priority, click routing, Reduce Motion, music/quota compact content, central hover, and no top-center frame jump.

- [x] **Step 5: Inspect final scope without committing unrelated changes.**

```sh
git status -sb
git diff --check
git diff --stat
```

Expected: existing Jira changes remain preserved alongside the mascot implementation and its changelog entry. Do not create the production commit until the user manually accepts and explicitly requests commit/push or release work.
