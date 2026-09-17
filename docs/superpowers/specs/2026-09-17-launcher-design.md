# Nool Launcher

Approved in chat on 2026-09-17: a universal launcher inside the existing Nool process.

## Interaction

A separate floating SwiftUI/AppKit panel, 680 points wide where the screen permits,
opens above the center of the screen under the pointer. A configurable global shortcut
defaults to Option-Space. Repeating it toggles the panel. Search receives focus on show.
Arrow keys select, Return activates, Escape and outside clicks dismiss. Tab cycles
All, Applications, Files and Clipboard. Closing returns focus to the previous app;
launching a result leaves focus with its destination. Settings provide another open action.

## Sources

- Applications: background discovery of installed applications, cached names and fuzzy
  matching, launch/focus through NSWorkspace.
- Files: asynchronous NSMetadataQuery using Spotlight within user-selected folders.
  Defaults are Desktop, Documents and Downloads. Open or reveal in Finder; show search
  progress and unavailable/empty results without blocking applications or calculator.
- Clipboard: opt-in local persistent history of text and images; search text, copy or
  paste into the previously active app. Default limit 100 items / 7 days, maximum
  5 MB per entry and 50 MB total. Ignore transient/concealed/password-manager types.
  Clear and disable controls are available; disabling clears retained history.
  Accessibility is requested only on explicit Paste. Failure leaves a copied item
  and a visible explanation; never synthesize paste into an unverified app.
- Calculator: bounded arithmetic parser supporting parentheses, unary signs,
  addition/subtraction, multiplication/division and exponentiation. Reject malformed
  input, non-finite results and excessive complexity. Return copies a valid result.

## Architecture and constraints

macOS 14+, Swift 6, no third-party dependencies. New code lives in
Sources/NotchApp/Launcher. LauncherWindowCoordinator owns only the new NSPanel frame;
NotchWindowCoordinator retains sole ownership of all existing notch panel frames.
LauncherModel merges independent sources and owns query/selection state. Views invoke
actions through callbacks. App delegate owns the launcher lifetime. LauncherSettings
uses its own UserDefaults keys. Existing settings host the new settings page.

No network requests for launcher data. No reading Notification Center or private APIs.
Do not log clipboard contents, local file inventories or user queries. Preserve all
pre-existing dirty changes and signing identity.

## Verification

Focused tests cover ranking, expression parsing, file query construction/cancellation,
clipboard retention/privacy and selection. Run swift build, relevant Swift tests and
git diff --check. An independent reviewer checks the added diff. Restart the signed
app and exercise hotkey, keyboard navigation, search, focus return, clipboard paste
and notch/popover coexistence. Distinguish completed automated checks from manual
acceptance that could not be exercised.
