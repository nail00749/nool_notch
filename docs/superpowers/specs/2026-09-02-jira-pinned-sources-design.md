# Jira Pinned Sources Design

## Goal

Add a persistent Jira mode for sources that must remain available independently of the current user assignment filter. Users can pin projects, boards, and individual issues in Settings, then access them from an additional mode inside the existing Jira panel.

The initial motivating case is the `NPA` board used for shared worklogs. A pinned board must expose every issue returned by that board's Jira filter, regardless of assignee, resolution, or status. A pinned project must expose every issue in that project. A pinned issue is displayed as one direct row.

## Non-goals

- Do not replace or change the existing "Мои" Jira mode.
- Do not introduce arbitrary user-authored JQL.
- Do not create a new top-level Notch panel.
- Do not mirror Jira data into durable local storage.
- Do not silently remove inaccessible or deleted pins.

## User experience

### Settings

The Jira settings page keeps the existing connection card and adds two cards when Jira is configured:

1. **Projects and boards**
   - Load projects available through the Jira platform API.
   - Load boards visible to the current user through the Jira Software Agile API.
   - Search the combined catalog by key, name, type, or board ID.
   - Pin or unpin an entry.
   - Display the source type so a project and board with the same name remain distinguishable.

2. **Issues**
   - Accept an issue key such as `NPA-123`.
   - Resolve the issue before pinning it so invalid or inaccessible keys produce an immediate error.
   - List pinned issues with remove and ordering controls.

Pinned sources are ordered. New entries are appended, and Settings allows moving them up or down.

### Jira panel

The existing Jira panel gains a `Мои / Закреплённые` mode switch. `Мои` preserves the current behavior and query.

`Закреплённые` contains a horizontally scrollable source switcher:

- `Задачи` appears when at least one individual issue is pinned.
- Every pinned project and board receives a separate source entry in stored order.
- The selected source is session state; the durable configuration contains only the pins and their order.

The issue list reuses the existing Jira issue row, including browser navigation, key copying, transitions, and worklog submission.

An empty pinned mode explains how to add sources in Settings. Removing the selected source selects the nearest remaining source. If no sources remain, the empty state is shown.

## Data model and persistence

Use explicit source types rather than storing JQL:

- `project(key, name)`
- `board(id, name, boardType)`
- `issue(key, summary)`

Persist ordered project/board pins and ordered issue pins in `AppPreferences`. Encode them as version-tolerant JSON data in `UserDefaults`. Unknown or malformed entries are ignored without discarding valid entries.

Persist stable Jira identifiers and display metadata. Jira issue payloads and source result lists remain in-memory cache only.

## Jira API

Extend `JiraClientProtocol` and `JiraClient` with these read operations:

- list projects using `GET /rest/api/2/project`;
- list all visible boards using paginated `GET /rest/agile/1.0/board`;
- load all issues for a board using paginated `GET /rest/agile/1.0/board/{boardId}/issue`;
- load all issues for a project using paginated Jira search with `project = "KEY"` and no assignee, resolution, or status clauses;
- resolve one issue using `GET /rest/api/2/issue/{issueKey}` with the fields required by the existing row.

Every paginated operation continues until the API-reported total is reached or a page contains no additional items. Requests preserve Jira installations hosted under a base path.

The board endpoint defines board membership through the board's saved Jira filter. Therefore "all board issues" means every issue returned by that filter that the authenticated user has permission to view.

## Provider state and loading

Keep pinned data separate from the existing `JiraProviderState.list` so pinned failures cannot replace or erase "Мои" results.

The pinned state contains:

- catalog load state for Settings;
- ordered configured pins;
- selected pinned source;
- per-source load state and in-memory cache;
- per-source refresh generation for stale-result rejection.

Only the selected pinned source loads automatically. Previously loaded results remain cached for fast switching. Manual refresh invalidates and reloads only the selected source. A connection change invalidates all catalog and issue caches while preserving configured pins.

Board and project pagination publishes accumulated results between pages so the list becomes usable before the entire source has loaded. Duplicate issue keys are removed while preserving API order.

Pinned individual issues are loaded as a small batch of independent requests. One inaccessible issue becomes an error row without hiding other pinned issues.

## Errors and permissions

- Unauthorized responses use the existing Jira connection recovery behavior.
- Forbidden, missing, or deleted sources retain their pin and show a local source error with retry and remove actions.
- A failure in one pinned source does not alter other source caches or the existing "Мои" list.
- Catalog failure does not prevent already configured pins from being used.
- Jira only returns boards and issues visible to the authenticated account; the app does not attempt to bypass Jira permissions.

## Interaction and window behavior

Settings pickers and Jira source controls use the existing tracked transient-surface lifecycle. Opening or dismissing their popovers must not race the Notch collapse animation.

Changing Jira modes or pinned sources does not resize the outer panel. Both modes use the existing Jira expanded window size.

## Verification

Automated coverage should include:

- preference round trips and malformed-entry recovery;
- board catalog and board issue pagination;
- project JQL containing only the project constraint and ordering, without assignee, resolution, or status filters;
- issue-key resolution and base-path preservation;
- provider cache isolation, stale-result rejection, retry behavior, and connection invalidation;
- source ordering and removal fallback;
- existing "Мои" query and worklog behavior remaining unchanged;
- transient UI integration for any new Settings picker.

Manual acceptance:

1. Pin the `NPA` board and at least one issue in Settings.
2. Open Jira and switch from `Мои` to `Закреплённые`.
3. Select `NPA` and confirm issues assigned to different users and completed issues returned by the board filter are visible.
4. Select `Задачи` and confirm each explicitly pinned issue appears once.
5. Submit a worklog from both source types.
6. Switch back to `Мои` and confirm its project filtering is unchanged.
7. Dismiss a worklog popover by clicking the desktop and confirm the Notch remains top-pinned throughout collapse.

## Release

After automated verification and the manual acceptance pass, commit the complete feature and current Notch fixes, push the branch, and publish the requested Homebrew release using the repository's existing release process.
