# AI Sessions Panel Design

Date: 2026-09-02

## Summary

Replace the top-level `Лимиты` panel with an `AI` panel containing two
subsections: `Лимиты` and `Сессии`. The limits subsection preserves the current
quota UI. The sessions subsection shows active and recent Codex Desktop tasks,
their current state, workspace, and last activity. Selecting a row opens that
exact task in Codex.

The session subsystem must be independent of Codex-specific storage and
protocols. Codex Desktop is the first source; later releases may add Codex CLI,
Claude Code, Cursor, or other agents without changing the panel UI or the store
contract.

## Goals

- Rename the top-level `Лимиты` panel to `AI`.
- Add `Лимиты` and `Сессии` subsections inside `AI`.
- Preserve the existing quota cards and quota settings.
- Show all active Codex Desktop sessions and the 10 most recent inactive
  non-archived sessions.
- Show normalized status, task title, workspace, and relative last activity.
- Open the selected task in Codex from a session row.
- Keep session presentation and orchestration independent of Codex internals.
- Preserve the window geometry invariants and avoid resizing when switching
  between the two AI subsections.

## Non-goals for the first release

- Codex CLI or other agent sources.
- Installing or modifying Codex hooks, `hooks.json`, or `config.toml`.
- Answering questions or approving tool requests from Nool Notch.
- Stopping, archiving, renaming, or otherwise mutating Codex tasks.
- Displaying full prompts, assistant replies, or transcript history.
- Showing archived tasks.
- Showing subagents as separate rows.
- Persisting a duplicate session database inside Nool Notch.

## User experience

The top-level panel switcher contains `AI` instead of `Лимиты`. Inside the AI
panel, a compact segmented control switches between `Лимиты` and `Сессии`.

The limits subsection remains the default after migration. The most recently
selected AI subsection is persisted after the user changes it.

The sessions subsection is a vertically scrolling, single-column list. Each row
contains:

- a colored normalized status and its Russian label;
- the task title;
- the repository name or final component of the working directory;
- relative last activity.

Rows are ordered by attention priority and recency:

1. waiting for approval;
2. waiting for user input;
3. running;
4. failed;
5. completed or otherwise inactive, newest first.

Every active or attention-required session is shown. After those rows, the list
contains at most 10 inactive sessions. Archived sessions are excluded. The first
release has no pagination or `Показать ещё` action.

Selecting a row asks its source to open the exact task. For Codex Desktop this
uses `codex://threads/<percent-encoded-thread-id>`. Nool Notch collapses only
after `NSWorkspace` accepts the URL open request. If exact navigation is not
available, the source may activate the Codex application as a fallback and the
UI shows a non-blocking failure state when neither action succeeds.

The top-level `AI` badge shows the number of sessions waiting for approval or
user input. When that number is zero, it falls back to the existing low-quota
warning count.

The AI panel uses the existing standard expanded window size for both
subsections. Switching `Лимиты` and `Сессии` must not change the `NSPanel`
frame. `NotchWindowCoordinator` remains the only owner of external window
geometry.

## Domain model and source boundary

The generic model belongs to the `NotchApp` target for this release. Moving it
to another package is unnecessary until a second consumer exists.

`AISession` contains only source-neutral data:

- composite identity consisting of `sourceID` and source-owned `sessionID`;
- agent kind and display name;
- task title;
- optional workspace path and display name;
- normalized `AISessionStatus`;
- last activity date;
- optional model display name;
- whether the data is currently live or stale.

`AISessionStatus` supports:

- `running`;
- `waitingForApproval`;
- `waitingForInput`;
- `completed`;
- `failed`;
- `unknown`.

Codex thread IDs, SQLite rows, JSON-RPC dictionaries, rollout paths, and URL
construction do not escape the Codex adapter.

`AISessionSource` exposes:

- stable source identity and display metadata;
- an asynchronous stream of complete source snapshots;
- an `open(sessionID:)` operation;
- explicit start and stop lifecycle through creation and cancellation of the
  snapshot stream.

Each source snapshot contains its complete current session set and source
health: `live`, `stale`, or `unavailable`. Complete snapshots make deletion and
reconciliation deterministic and avoid leaking source-specific event semantics
into the shared store.

`AISessionStore` consumes one stream task per registered source. It:

- merges sessions by composite identity;
- replaces only the snapshot belonging to the emitting source;
- preserves other sources when one source fails;
- applies the shared ordering and inactive-session limit;
- publishes source health and the attention badge count;
- routes open requests back to the owning source.

The store remains active for the lifetime of the application, not only while
the sessions subsection is visible. This keeps badges and status transitions
current while the user views another panel.

## Codex Desktop adapter

`CodexDesktopSessionSource` is the only component aware of Codex Desktop. It
combines a read-only state reader with a live app-server client.

### Initial and fallback state

`CodexStateReader` opens `$CODEX_HOME/state_5.sqlite`, falling back to
`~/.codex/state_5.sqlite`, in read-only mode. It introspects the `threads` table
before querying so a missing or changed optional column degrades cleanly rather
than crashing the app.

Candidate rows must be non-archived Desktop threads. Desktop provenance is
determined from supported source fields and rollout metadata; explicit CLI
sessions are not reclassified as Desktop sessions. Candidates are ordered by
the most recent available millisecond or second timestamp. The reader fetches
a bounded candidate set, retains all sessions whose rollout indicates an
unfinished turn, and then retains the 10 newest inactive sessions.

The state reader uses database fields such as `title`, `name`, `preview`,
`cwd`, `model`, and `rollout_path` when present. It reads only a bounded tail of
the rollout JSONL to find the latest turn lifecycle marker needed to distinguish
running from completed. It does not load or publish conversation bodies.

The read-only scan runs:

- once when the source starts;
- when Codex launches or terminates;
- after an app-server disconnect;
- periodically at a modest interval while the application is running.

Scanning and parsing occur off the main actor. Only normalized snapshots are
published back to UI state.

### Live state

When an application with bundle identifier `com.openai.codex` is running, the
source derives the bundled executable path from that application's bundle URL:
`Contents/Resources/codex`. This supports both `Codex.app` and installations
whose bundle is named `ChatGPT.app`. Known application paths are fallback
candidates only.

`CodexAppServerClient` starts:

```text
codex app-server --listen stdio://
```

It implements only the required newline-delimited JSON-RPC framing,
initialization handshake, response parsing, and lifecycle management. It maps:

- `thread/started`;
- `thread/status/changed`;
- `thread/closed`;
- active flags such as `waitingOnApproval` and `waitingOnUserInput`.

The first release never sends user-input answers or approval decisions. A
server-to-client request may update the normalized waiting status, but the
adapter does not expose its contents to the UI and does not act on the request.

Live events override the fallback status for matching thread IDs. State-reader
metadata continues to supply titles and workspace information when live events
omit them.

The client observes Codex launch and termination through `NSWorkspace`. An
unexpected child-process exit changes source health to `stale`, preserves the
last successful snapshot, triggers a read-only refresh, and reconnects with
capped exponential backoff while Codex remains running. Intentional shutdown
cancels the reconnect task and terminates the child process.

## Integration with existing application state

`PanelID.limits` becomes `PanelID.ai`, with title `AI` and an AI-oriented system
icon. `AppPreferences` performs a compatibility migration from the legacy raw
value `limits` to `ai` for:

- last selected panel;
- panel order;
- hidden panel IDs;
- startup panel.

After reading a legacy value, preferences write the canonical `ai` value on the
next mutation. Existing quota preference keys under `limits.*` do not change.

`AISection` contains `limits` and `sessions`. The selected section is stored in
UserDefaults under an `ai.*` key and defaults to `limits`.

`NotchViewModel` owns or receives the shared `AISessionStore`, exposes the
selected AI subsection and read-only session presentation state, and routes row
selection to the store. Networking, SQLite, subprocess transport, and URL
construction remain outside SwiftUI views.

`ExpandedNotch` renders `AIPanel` for `.ai`. `AIPanel` owns the subsection
switcher and embeds the existing `LimitsPanel` or the new `AISessionsPanel`.
The current top-level carousel behavior remains unchanged.

## Error handling and privacy

- A missing Codex database produces an unavailable empty state, not an app
  failure.
- A schema mismatch, locked database, malformed row, or malformed JSONL line is
  skipped defensively and reflected in source health.
- A live connection failure never clears the last successful fallback snapshot.
- Failure in the Codex source cannot affect quota, Jira, calendar, music, or
  future session sources.
- SQLite is opened read-only; the adapter never writes to Codex-owned files.
- The app-server subprocess is launched without secrets on its command line.
- Logs must not contain prompts, replies, tokens, full rollout content, or
  credential material.
- The UI displays only the workspace's final path component. Full local paths
  are not copied to logs or exported diagnostics.
- Opening a task is the only external action initiated by this feature and
  occurs only after an explicit row click.

## Proposed files

New files:

- `Sources/NotchApp/AISession.swift`
- `Sources/NotchApp/AISessionSource.swift`
- `Sources/NotchApp/AISessionStore.swift`
- `Sources/NotchApp/CodexDesktopSessionSource.swift`
- `Sources/NotchApp/CodexStateReader.swift`
- `Sources/NotchApp/CodexAppServerClient.swift`
- `Sources/NotchApp/AIPanel.swift`
- `Sources/NotchApp/AISessionsPanel.swift`

Existing files expected to change:

- `Package.swift` for the system SQLite library link if required;
- `Sources/NotchApp/NotchSharedUI.swift`;
- `Sources/NotchApp/ExpandedNotch.swift`;
- `Sources/NotchApp/NotchViewModel.swift`;
- `Sources/NotchApp/AppPreferences.swift`;
- focused files under `Tests/NotchAppTests`;
- `CHANGELOG.md` under `Unreleased`.

The exact file split may be reduced during planning if a type is too small to
justify a standalone file, but the source, store, transport, persistence, and
view responsibilities must remain separate.

## Verification

Automated verification covers:

- legacy `limits` preference migration in all panel preference fields;
- AI subsection default and persistence;
- SQLite schema compatibility and filtering using temporary fixture databases;
- bounded rollout-tail parsing for running and completed turns;
- newline JSON-RPC parsing, partial-frame buffering, EOF handling, and process
  shutdown;
- Codex status and active-flag normalization;
- snapshot replacement, cross-source isolation, deduplication, ordering, and
  the 10-inactive-session limit;
- attention badge precedence over quota warnings;
- exact Codex URL construction and fallback behavior;
- source health transitions and preservation of stale data.

Repository checks:

```sh
git diff --check
xcrun swift build
xcrun swift test
```

Manual AppKit acceptance:

1. Launch Codex Desktop with at least two recent tasks.
2. Open the notch and select `AI → Сессии`.
3. Confirm active status updates while a task starts, works, waits, and finishes.
4. Confirm the list contains active tasks and no more than 10 inactive tasks.
5. Select a row and confirm Codex opens the correct task.
6. Confirm the notch collapses after the navigation request succeeds.
7. Switch repeatedly between `Лимиты` and `Сессии`; confirm the window remains
   top-centered and does not resize or jump.
8. Terminate and relaunch Codex; confirm stale/unavailable state and live
   reconnection without losing the rest of the Nool Notch UI.
9. Relaunch Nool Notch; confirm the migrated panel order and selected AI
   subsection persist.

## Reference

The source discovery and app-server approach is informed by the MIT-licensed
[CodeIsland](https://github.com/wxtsky/CodeIsland) project, inspected at commit
`63013bfb5c4e948f7dfed3677ddcb1c930af9afa`. Nool Notch will implement only the
minimal contracts described here. Any substantial copied implementation must
retain the license attribution required by the upstream license.

## Acceptance criteria

The feature is complete when the existing limits UI is available under
`AI → Лимиты`, Codex Desktop sessions appear under `AI → Сессии` with live or
clearly stale status, a row opens the exact corresponding Codex task, legacy
panel preferences survive migration, failures remain isolated, and the manual
window-geometry scenario shows no resize or positional jump.
