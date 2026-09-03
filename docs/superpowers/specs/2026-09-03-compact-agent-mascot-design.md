# Compact Agent Mascot Design

Date: 2026-09-03

## Summary

Add an original native 3D mascot named Nool to the right of the collapsed
notch when an AI session finishes, fails, waits for approval, or waits for
user input. The mascot gives a visible but compact signal while the user is
working outside Codex. Clicking it opens the notch directly on
`AI -> Сессии`.

The mascot is modeled in Blender, converted to a local SceneKit asset, and
rendered by a transparent `SCNView`. The app does not copy the ChatGPT mascot,
load remote assets, add a third-party 3D dependency, or expose session contents.

## Goals

- Surface actionable AI-session state while the notch is collapsed.
- Show waiting states until they resolve.
- Show newly failed work until the user acknowledges it.
- Celebrate newly completed work for 15 seconds.
- Keep the physical notch visually pinned to the exact top center.
- Open the existing sessions panel from the mascot.
- Keep the signal model independent of Codex Desktop so future session sources
  receive the same behavior.
- Respect Reduce Motion.

## Non-goals

- Approving requests or answering an agent from the mascot.
- Showing prompt, response, approval, or failure text in compact mode.
- Displaying historical completed or failed sessions when Nool Notch starts.
- Persisting notifications between app launches.
- User-selectable characters, skins, sounds, or notification settings.
- SVG, Lottie, or third-party runtime animation dependencies.
- A separate AppKit window for the mascot.

## User experience

When a signal arrives, the compact black surface widens first. Nool then appears
in the new 50-point right lane after the 300 ms window resize has completed. The
surface also grows 12 points downward to give the 3D character more vertical
space. Its pose and indicator communicate the highest-priority current signal:

1. `waitingForApproval`: yellow `!`, periodic wave;
2. `waitingForInput`: cyan `?`, periodic wave;
3. newly `failed`: red `!`, short alert pose;
4. newly `completed`: mint check, happy wave for 15 seconds.

Waiting states remain visible until their session status changes. A failed
signal remains visible until the mascot is clicked. A completed signal expires
after 15 seconds. When several sessions qualify, the highest-priority signal
drives the mascot; opening the sessions panel exposes the complete ordered
list.

The animation uses a calm base pose plus one or two wave frames. The wave
plays periodically rather than continuously. With Reduce Motion enabled, the
mascot displays a static alert pose and indicator without movement.

Clicking the mascot selects the top-level `AI` panel, selects its `Сессии`
subsection, and expands the notch. Clicking the central compact notch keeps its
existing behavior. The transparent balancing area introduced for geometry is
not interactive.

If the user has hidden the top-level `AI` panel in Settings, the mascot is
suppressed. The notification feature must not silently change saved panel
visibility; restoring the AI panel makes current waiting signals eligible
again.

## Signal state and lifecycle

Introduce a source-neutral `CompactAgentSignal` presentation model containing
the normalized signal kind and the selected `AISessionID`. The signal is
derived after `AISessionStore` has already merged all registered sources, so
no Codex-specific status or identifier enters the compact UI.

A small `CompactAgentSignalController` owns transition history and ephemeral
timers:

- The first received session snapshot seeds known statuses.
- Waiting-for-approval and waiting-for-input sessions from the first snapshot
  are actionable and may appear immediately.
- Completed and failed sessions already present in the first snapshot do not
  generate notifications.
- A later active-to-completed transition creates a 15-second completion event.
- A later transition into failed creates an acknowledgement-required event.
- Status changes replace the remembered status for the same composite session
  identity.
- Disappearing sessions are removed from current waiting candidates, while an
  already-created completion timer may finish normally.
- A newer or higher-priority event deterministically replaces the presented
  signal.

Click acknowledgement removes the selected terminal failed event before
opening the sessions panel. Waiting states are not acknowledged permanently;
if the session still waits after the notch collapses, the mascot appears again.
Completion timers and all in-memory transition history reset on app launch.

The controller must not keep prompt text, response text, credentials, or full
workspace paths. It needs only composite session ID, normalized status, and
the existing activity timestamp used for deterministic ordering.

## Compact layout and window geometry

The mascot stays inside the existing `NotchPanel`. A second window would add
ordering, Spaces, hover, and animation synchronization risks and is not needed.

When a mascot is visible, the compact content uses three horizontal lanes:

```text
[black 50 pt extension] [centered notch] [black 50 pt mascot lane]
```

The left black extension has the same width as the right mascot lane. The outer
panel and compact black surface grow symmetrically, so their center and the
physical notch center remain identical throughout the animation. When the
mascot disappears, both extensions disappear together.

The compact height grows by 12 points only while a mascot signal is present.
Because the panel origin is recomputed from the screen's top edge, the extra
height extends downward without moving the top anchor.

Compact-to-compact mascot resizing uses the same interruptible 360 ms timing
curve in AppKit and SwiftUI. The panel frame, black surface, and content lanes
therefore expand and contract as one continuous top-anchored transition. The
mascot enters only after the expansion finishes and fades out while the panel
contracts.

`NotchWindowCoordinator` remains the only owner of `NSPanel.frame`.
`NSHostingView.sizingOptions` remains empty. The layout policy receives only a
boolean indicating whether the mascot lane is present and includes the paired
lane width in the compact size. `NotchRootView` notifies the coordinator when
that visibility changes, just as it already does for playback-dependent compact
size changes.

The central notch and mascot are separate SwiftUI buttons inside the compact
layout; one button is never nested inside another. Only their visible regions
participate in hit testing. The mascot has at least a 40 by 40 point hit area.

## Native 3D animation

`CompactAgentMascot` embeds a transparent, non-interactive `SCNView` that loads
the local `.usdc` asset exported from the project's Blender mascot. SceneKit
animates the named `NoolPhotoYork_Wave_Pivot` node while SwiftUI owns the semantic status
bubble and click target.

The 3D character retains a neutral cyan and mint body so it remains recognizable
across states. A tiny adjacent status glyph carries the semantic color; color
is not the only differentiator.

Animation runs only while the mascot is visible. The SceneKit action pauses in
a neutral pose when Reduce Motion is enabled.

## Integration

`NotchViewModel` subscribes to the existing `AISessionStore` output, passes
complete normalized snapshots to the signal controller, and publishes the
current compact signal. It also exposes one command that acknowledges the
selected terminal signal, selects `.ai` and `.sessions`, cancels any scheduled
collapse, and expands the notch.

`CompactNotch` renders the centered notch button and the optional mascot button.
`NotchRootView` includes mascot visibility in compact sizing and forwards its
changes to the coordinator. `NotchWindowSizingPolicy` and `NotchLayoutMetrics`
calculate the symmetric compact frame without moving the center anchor.

No changes are required in `CodexDesktopSessionSource` or future
`AISessionSource` implementations.

## Error handling

- Unknown session states do not show the mascot.
- Stale or unavailable source health does not invent a completion event.
- If opening the AI panel is possible but the selected session has disappeared,
  the sessions list still opens normally.
- Timer cancellation or replacement leaves the next highest-priority waiting
  signal visible.
- The mascot never expands or resizes the window by changing hosting-view
  intrinsic content size; all size changes go through the coordinator.

## Expected files

New files:

- `Sources/NotchApp/CompactAgentSignal.swift`
- `Sources/NotchApp/CompactAgentMascot.swift`
- `Sources/NotchApp/Resources/CompactAgentMascot/NoolMascot.usdc`

Existing files expected to change:

- `Sources/NotchApp/AISession.swift` only if a shared ordering helper is needed;
- `Sources/NotchApp/NotchViewModel.swift`;
- `Sources/NotchApp/CompactNotch.swift`;
- `Sources/NotchApp/NotchRootView.swift`;
- `Sources/NotchApp/NotchSharedUI.swift`;
- `Sources/NotchApp/NotchWindowCoordinator.swift` if its sizing callback needs
  the explicit compact mascot flag;
- `CHANGELOG.md` under `Unreleased`.

## Verification

Per the requested manual-first workflow, this feature does not add TDD or new
automated tests in its first iteration.

Repository checks:

```sh
git diff --check
xcrun swift build
```

Manual AppKit acceptance:

1. Launch Nool Notch while historical completed and failed sessions exist;
   confirm they do not summon the mascot.
2. Put a live task into approval wait and input wait; confirm the matching
   persistent mascot states.
3. Finish an active task; confirm the happy wave appears for 15 seconds and
   then disappears.
4. Fail an active task; confirm the alert remains until the mascot is clicked.
5. Click the mascot; confirm the notch opens directly at `AI -> Сессии`.
6. Exercise two simultaneous attention states and confirm priority order.
7. Repeat with Reduce Motion enabled and confirm the pose is static.
8. Watch the physical notch while the mascot appears and disappears; confirm
   the notch stays top-centered without a one-frame jump.
9. Confirm central-notch hover/click, music wings, quota display, collapse, and
   tracked popovers still behave normally.

## Release note

The implementation commit must add a user-facing `Added` entry to
`CHANGELOG.md`. Release and Homebrew publication remain separate explicit
operations after manual acceptance.
