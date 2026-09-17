# Launcher AI implementation

Spec: ../specs/2026-09-17-launcher-ai-design.md

- [x] Define provider-neutral message, model, status and streaming contracts.
- [x] Add Codex app-server adapter with account/model discovery, ephemeral no-tools
  turns, request denials and cancellation; verify with subprocess/protocol fixtures.
- [x] Add Claude print adapter with subscription check, safe mode, tools disabled,
  stdin prompting and NDJSON stream decoding; verify with subprocess fixtures.
- [x] Add availability-gated Apple adapter and chat store; verify stale-event,
  bounded-context and new-chat behavior using fake providers.
- [x] Integrate fifth tab, composer, transcript/model controls and opt-in settings.
- [x] Update docs/changelog; run focused tests/build, independent review and available
  provider smoke checks; restart using stable signing. Record unavailable live checks.

Primary agent owns architecture, shared contracts, UI, Apple adapter and integration.
Two bounded workers own separate CLI adapters; no overlapping edits or nested agents.

Validation (2026-09-17):
- `swift test --filter 'AIChat|Launcher'`: 55 tests, zero failures.
- `run-app.sh`: build/restart succeeded using existing signing mode;
  `codesign --verify --deep --strict Build/NotchApp.app` passed.
- Apple FoundationModels answered a fixed harmless smoke prompt on this Mac.
- Codex returned subscribed model IDs and answered a fixed harmless smoke prompt.
  Effective config confirmed every requested feature disabled, no notification
  command, web search disabled and all inherited MCP servers individually disabled.
- Claude auth status is logged out here; subprocess fixtures cover its stream,
  errors, timeout, no-tools arguments and cancellation during auth. Live Claude
  generation remains unverified until the user signs in.
- Independent source review has no remaining material findings.
- Native accessibility inspection reached the AI panel with Codex/model selectors,
  enabled provider, empty transcript and focused composer. CUA repeatedly lost its
  native pipe; a later send attempt was stopped because the window changed.
  Full visual, keyboard and send/stop/reopen interaction acceptance remains manual.
