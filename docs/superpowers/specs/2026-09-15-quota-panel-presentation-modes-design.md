# Quota Panel Presentation Modes Design

Date: 2026-09-15

## Summary

Extend the compact quota presentation with three mutually exclusive modes:

1. the existing quota indicator inside the notch;
2. the existing left or right edge wave;
3. a new Finder-style stack that fans out from any screen corner on hover.

The notch mode remains behaviorally unchanged. Wave and stack placements are
configured independently, and the app remembers the last placement selected
for each mode. Only the selected mode owns an active external trigger or quota
surface.

The corner stack follows the approved visual direction: provider rings emerge
from one corner along a gentle fan, each with its own inward-facing dark label
showing the provider name, remaining percentage, and a short reset hint. It is
an original Nool Notch presentation inspired by the interaction pattern of a
macOS Finder Stack; it does not integrate with or modify the Dock.

## Goals

- Preserve the existing compact quota indicator in the notch without changing
  its layout or interaction.
- Keep the existing edge wave available on the left and right sides.
- Add a corner stack with top-left, top-right, bottom-left, and bottom-right
  placements.
- Reveal the stack on hover and collapse it when the pointer leaves the entire
  stack interaction region.
- Keep notch, wave, and stack hover state independent.
- Give every provider a branded ring and a readable compact summary.
- Make mode and placement understandable and switchable in Settings.
- Preserve the coordinator-owned AppKit geometry invariant.
- Respect Reduce Motion and multi-display selection.

## Non-goals

- Embedding the quota stack in the macOS Dock.
- Calling private Dock, menu bar, or window-server APIs.
- Showing the wave and stack simultaneously.
- Changing quota transport, refresh, authentication, ordering, or visibility
  rules.
- Redesigning the full `AI -> Limits` panel.
- Changing the existing wave detail bubble.
- Adding arbitrary user-controlled spacing, animation curves, ring sizes, or
  custom colors in the first version.

## Settings model

The current flat `Top / Left / Right` control becomes two levels of settings.

### Presentation mode

The first control offers three visual cards:

- `In notch`: the current top compact indicator;
- `Wave`: the edge-attached wave rail;
- `Stack`: the new corner fan.

Each card contains a small deterministic SwiftUI preview rather than a static
raster asset. The selected card uses the existing settings accent and focus
treatment.

### Placement

The second control is conditional:

- `In notch` shows no placement control.
- `Wave` shows `Left` and `Right`.
- `Stack` shows four corner choices: `Top left`, `Top right`, `Bottom left`, and
  `Bottom right`.

Changing presentation mode restores that mode's last selected placement. For
example, switching from a right wave to a bottom-left stack and back restores
the right wave.

Persist three independent values:

- selected presentation mode;
- last wave edge;
- last stack corner.

The preference reader migrates the current atomic values as follows:

- `top` -> `inNotch`;
- `left` -> `wave` plus `left`;
- `right` -> `wave` plus `right`.

Unknown or missing values fall back to the existing `inNotch` behavior, a
right wave edge, and a bottom-right stack corner. Existing stored settings are
never erased solely because the UI moves to the new model.

## Mode behavior

### In-notch mode

This mode is not redesigned. It continues to use the selected compact quota
provider and the existing compact-notch hover and click behavior. Selecting it
orders out any wave or stack windows and their external triggers.

### Wave mode

The current edge trigger, wave rail, provider hover detail, and float-in
animation remain unchanged. The new settings model supplies its left or right
edge. Selecting it orders out every stack window and stack trigger before the
wave trigger becomes active.

### Corner stack mode

At rest, the selected corner shows only a two-point black marker. Its actual
transparent hit target is larger so the interaction is usable, but it is
offset slightly from the exact one-pixel system corner to avoid swallowing a
configured macOS Hot Corner. The marker still reads visually as originating
from the corner.

Hovering the trigger reveals every visible quota provider. Provider order
follows the existing saved quota-provider order. The first provider is nearest
the anchor, and subsequent providers fan progressively farther away:

- top-left fans down and right;
- top-right fans down and left;
- bottom-left fans up and right;
- bottom-right fans up and left.

Each item contains:

- a 42-48 point branded quota ring;
- the provider's existing brand icon;
- an inward-facing dark material label;
- provider display name;
- rounded remaining percentage for the preferred percentage window;
- a short reset hint when a reset date is available.

The label appears to the right of left-corner rings and to the left of
right-corner rings. Text remains horizontal and readable; the complete item may
have a subtle alternating resting rotation of no more than two degrees to
create the Finder-stack character without sacrificing legibility.

When quota data is unavailable, the item stays present with the current
provider icon, `--`, and the existing unavailable or authentication state
expressed in the reset-hint line. Hovering the trigger keeps the existing
stale-data refresh behavior. A refresh changes content in place and must not
restart, close, or reposition the stack animation.

Clicking any provider item opens the existing full quota panel through
`NotchViewModel.openQuotaLimits()`. The stack does not open an additional wave
detail bubble because its visible label already provides the compact summary.

## Hover lifecycle

The corner trigger and all revealed provider items form one logical hover
region even though they use separate windows. The coordinator tracks:

- whether the corner trigger is hovered;
- the set of provider item windows currently hovered;
- whether a collapse task is pending.

Entering the trigger cancels a pending collapse, refreshes stale quota data,
and starts or reverses the reveal. Moving between the trigger and any item, or
between two items, is protected by the same 180 ms grace period used by the
wave. Entering any stack item within the grace period cancels collapse without
jumping or replaying the reveal.

Leaving the complete logical region schedules one collapse. Model updates,
provider snapshot publications, display refreshes, and unrelated notch hover
changes do not bypass the grace period. Re-entering while the stack is
collapsing reverses the current presentation smoothly. Generation tokens guard
all delayed `orderOut` operations so an older animation cannot hide a newly
revealed stack.

Changing the selected mode or display is not a hover transition: it cancels
pending tasks, clears stack hover state, immediately closes obsolete windows,
and builds the trigger for the newly selected configuration.

## Animation

The approved motion is a floating cascade rather than a simultaneous fade.

On reveal:

- all item windows begin at the selected corner anchor;
- each item starts around 0.72 scale, low alpha, and a small rotation;
- items travel to their final fan positions over approximately 320 ms;
- each subsequent provider starts about 35 ms after the previous provider;
- the curve has a strong ease-out coast without bounce or overshoot;
- label and ring move as one object.

On collapse:

- items return toward the anchor in reverse order;
- the cascade lasts approximately 220 ms after the 180 ms hover grace;
- alpha and scale fall with the inward movement;
- windows are ordered out only after their generation-matched animation ends.

The coordinator owns every window frame and alpha animation. SwiftUI may own
the scale and small content rotation inside a fixed coordinator-sized item
window; intrinsic content size must never resize a hosting window.

With Reduce Motion enabled, windows appear at final positions and use a short
simultaneous fade. There is no translation, scale, rotation, stagger, or reverse
cascade.

## Window architecture and hit testing

`NotchWindowCoordinator` remains the sole owner of all `NSPanel.frame` values.
The stack uses:

- one small non-activating transparent trigger panel;
- one non-activating transparent item panel per visible provider.

Separate item panels are preferred over one large transparent fan panel. They
allow the labels to float independently and avoid a large invisible rectangle
blocking clicks in the application underneath. Each item's window frame wraps
only its label, ring, shadow allowance, and reasonable pointer padding.

Stack panels use the same collection behavior and selected-display lifecycle as
the wave panels. They do not become key or main, do not appear in the window
cycle, and remain available in full-screen Spaces consistently with the current
quota edge surfaces.

The coordinator keeps item panels in a dictionary keyed by provider ID. A
provider-order or visibility change reuses matching windows, creates missing
ones, and orders out removed ones. This reconciliation happens without closing
unaffected items or resetting the current hover lifecycle.

Corner geometry is calculated by a pure layout policy from:

- the selected screen frame and safe visible bounds;
- selected corner;
- provider count and saved order;
- item size, fan step, and screen margin.

Final item frames are clamped to the selected display. If the provider count
cannot fit at the preferred spacing, the policy reduces the step to a defined
minimum before clamping; items must not cross onto another display or under the
opposite screen edge.

## Components and responsibilities

### Preferences

`AppPreferences` defines the presentation mode, wave edge, and stack corner
types, performs migration, and persists the three values.

### View model

`NotchViewModel` exposes the selected mode and placements, validates changes,
and publishes configuration updates. It keeps existing provider ordering,
visibility, refresh, and open-panel commands unchanged.

### Settings

`NotchSettingsView` renders the three mode preview cards and the contextual
placement selector. It does not calculate AppKit frames or directly show and
hide panels.

### Stack view

A focused `CompactQuotaCornerStackItem` renders one provider's ring and label.
It receives provider state, corner orientation, presentation progress, click,
and hover callbacks. It does not fetch quota data or know screen coordinates.

### Layout and hover policies

Pure corner-stack layout and visibility policies calculate item placement and
state transitions. They remain independent of AppKit so all four corners,
screen clamping, provider ordering, and hover grace can be unit-tested.

### Window coordinator

`NotchWindowCoordinator` owns trigger and item windows, placement reconciliation,
hover aggregation, animation generation, display changes, and mutually
exclusive mode activation.

## Accessibility

- The trigger exposes an accessibility label equivalent to `Show quota stack`.
- Every item exposes provider name, remaining percentage or unavailability,
  reset hint when known, and an activation hint for opening the full limits
  panel.
- Provider color is never the only state signal; percentage text and status
  copy remain present.
- Settings cards expose selected state and descriptive labels for every corner.
- VoiceOver can expose the stack trigger and provider actions without requiring
  pointer hover. Keyboard users retain the full limits panel path and can
  switch back to the unchanged in-notch mode in Settings.
- Reduce Motion behavior follows the system setting at every reveal and
  collapse, including interrupted transitions.

## Error handling

- Zero visible providers disables and orders out the external trigger and stack.
- Missing percentage or reset values use the existing unavailable presentation
  rather than inventing a number or deadline.
- A failed provider refresh retains the last successful stale snapshot where
  the provider already supports it.
- Removing a provider while hovered clears its hover identity before its panel
  is ordered out.
- Disconnecting or rearranging displays immediately resolves placement against
  the current selected screen and closes obsolete off-screen windows.
- Invalid persisted modes or placements fall back safely without overwriting
  unrelated preferences.

## Expected files

New source is expected to remain focused, for example:

- `Sources/NotchApp/CompactQuotaCornerStack.swift` for stack item rendering,
  layout policy, and stack-specific presentation constants.

Existing files expected to change:

- `Sources/NotchApp/AppPreferences.swift`;
- `Sources/NotchApp/NotchViewModel.swift`;
- `Sources/NotchApp/NotchSettingsView.swift`;
- `Sources/NotchApp/NotchWindowCoordinator.swift`;
- `Tests/NotchAppTests/AppPreferencesTests.swift`;
- `Tests/NotchAppTests/NotchInteractionTests.swift`;
- `Tests/NotchAppTests/NotchViewModelProviderTests.swift` if setter behavior
  needs direct coverage;
- `CHANGELOG.md` under `Unreleased` in the implementation commit.

The existing `CompactQuotaSidebar.swift` remains responsible for the wave and
its detail bubble. Shared provider visuals may be reused, but stack-specific
layout and motion do not move into the wave component.

## Verification

Automated checks:

- preference default, round-trip, legacy migration, and invalid-value fallback;
- selected-mode mutual exclusion;
- all four corner direction and label-orientation mappings;
- multi-display frames with positive and negative screen origins;
- provider ordering, removal, and available-height clamping;
- trigger/item/grace-period visibility decisions;
- interrupted reveal/collapse generation behavior;
- Reduce Motion policy;
- existing wave geometry and top compact presentation regressions;
- `git diff --check`;
- Xcode-beta `xcrun swift build` and full `xcrun swift test`.

Manual AppKit acceptance:

1. Confirm `In notch` looks and behaves exactly as before.
2. Switch between left and right wave; confirm current hover and detail behavior.
3. Test every stack corner and confirm it fans inward in the correct direction.
4. Move slowly and quickly from trigger to items and between items; confirm no
   flicker, premature collapse, or replayed animation.
5. Re-enter during collapse and confirm the stack reverses without a jump.
6. Hover while quota snapshots refresh and confirm labels update in place.
7. Click each provider item and confirm `AI -> Limits` opens.
8. Change provider visibility and order while stack mode is selected.
9. Test on each connected display, including a display with a Dock or menu bar
   adjacent to the selected corner.
10. Confirm the marker does not prevent a configured macOS Hot Corner from
    activating at the exact one-pixel corner.
11. Repeat reveal, collapse, and mode switching with Reduce Motion enabled.
12. Exercise normal notch hover, popovers, and collapse to confirm external
    quota surfaces remain independent.

## Release note

The implementation commit adds an `Added` entry under `CHANGELOG.md` describing
the new corner stack and the new presentation/placement controls. This design
document alone does not change user-visible behavior and needs no changelog
entry.
