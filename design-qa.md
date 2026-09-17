# Quota panel presentation design QA

Date: 2026-09-15

## Source truth

- Approved generated direction: local design reference (`1536x1024`),
  not included in the repository.
- Finder Stack interaction reference: local screenshot (`1142x1872`),
  not included in the repository.
- Implementation contract:
  `docs/superpowers/specs/2026-09-15-quota-panel-presentation-modes-design.md`.

## Rendered implementation

- Native macOS app built and restarted from `Build/NotchApp.app`.
- Settings viewport: `560x520`; verified in the `Limits` section with the
  `Stack` mode and `Bottom right` placement selected.
- Runtime display used for geometry evidence: built-in display `1800x1169`.
- The computer-use bridge returned the native settings screenshot inline but
  does not expose a local screenshot path. A final motion capture of the
  separate transparent edge `NSPanel` could not be persisted because the
  bridge rejects coordinate actions once the pointer destination belongs to
  the higher-level Nool trigger window.

## Comparison evidence

- The settings render shows three mutually exclusive cards: `In notch`,
  `Wave`, and `Stack`, followed by the four-corner selector only for `Stack`.
- The corner item implementation follows the approved visual hierarchy:
  branded ring, dark inward-facing pill, provider name, percentage, and reset
  hint.
- AppKit runtime inspection confirmed that the selected corner creates one
  independent `8x56` trigger window. Unit geometry covers target, trigger, and
  collapsed frames for all four corners.
- The hidden anchor remains at the exact physical corner. On reveal, the first
  card settles `12 pt` inward on both axes; subsequent cards fan another `12 pt`
  inward and `72 pt` vertically rather than forming a plain list.

## Findings and iterations

1. The first implementation used `NSScreen.visibleFrame`, which lifted the
   bottom stack by the complete Dock reservation and no longer read as a corner
   interaction.
2. After visual feedback, trigger, target, and collapsed frames were moved to
   the full physical `NSScreen.frame`; the two-point marker and collapsed card
   touch the selected corner exactly, while the revealed card settles `12 pt`
   inward.
3. This is an intentional presentation choice: top corners may overlay the menu
   bar and bottom corners may enter the Dock band while the stack is revealed.

## Final result

Blocked only for persisted pixel/motion comparison: the native computer-use
bridge cannot capture the hover-only transparent `NSPanel` in this setup.
Settings layout, runtime trigger creation, physical-edge anchor geometry, state
transitions, reduced motion behavior, and automated interaction policies were verified. One manual
mouse-hover pass on the running app remains the acceptance check for the exact
fan motion and visual spacing.
