# Launcher AI chat

User selected Apple Intelligence plus already-installed Codex and Claude CLI subscription
connections. Add AI as a fifth Launcher tab, with provider/model selection, a chat
transcript, streaming replies, New Chat, Stop and Copy. The active chat and draft survive
window dismissal and restart through local history with search, pinning and deletion.
The accepted extension adds local Ollama, explicit selected-text draft actions,
and document/image attachments through a picker and drag-and-drop.

## Boundaries

- The existing macOS 14 minimum remains. Apple Foundation Models is guarded by macOS
  26 availability and checks SystemLanguageModel availability on use. Never silently
  route an unavailable local model to a cloud provider.
- CLI connections are individually opt-in in AI settings. Discover installed binaries
  in standard locations; never install or log in automatically. Do not read or copy
  their credentials. Codex model discovery comes from model/list; Claude uses supported
  CLI aliases after a successful subscription auth check.
- CLI generation accepts conversation text and explicitly attached images. Disable tools, hooks, skills, MCP, plugins and agent
  features with supported per-process configuration; deny any unexpected server request.
  Use a private temporary cwd, send prompts only through stdin, bound streams/timeouts,
  and terminate owned processes on cancellation/shutdown. Never edit CLI user configs.
- Codex uses ephemeral app-server threads and Claude --no-session-persistence. Nool
  retains no prompts/responses in logs. Cloud prompts reach the explicitly selected
  CLI service; local Apple inference stays on-device.
- Switching provider/model starts a new chat to avoid silently moving a conversation
  between accounts/providers. Stop preserves partial text but excludes it from later
  model context. Closing the window lets a reply finish in memory. New Chat and Quit
  cancel active work and reject late events.
- Limit input to 8,000 characters, transcript to 100 messages/200,000 characters;
  route-specific context bounds keep the latest user message whole or reject before send.

## Components

Sources/NotchApp/Launcher/AI contains common types/provider protocol, four provider
adapters, CLI process helpers, chat state and chat/settings views. LauncherModel owns
one AIChatStore; its lifetime is independent of search query/reset. LauncherWindowCoordinator
focuses the chat composer when AI is active and reserves Return for sending there.

History uses a private local directory, serialized atomic writes, bounded retention
and preservation of corrupt files. Shutdown flushes pending writes. Ollama only
uses the fixed loopback endpoint and installed local models, without tools or pulls.
Selected text uses Accessibility, excludes protected fields, and prepares a draft;
insertion rechecks the selection and frontmost app before replacing text.

Attachments are imported off-main from bounded local regular files. UTF-8 and
PDF text is included as untrusted document content; scanned pages are not OCR'd.
Images are downsampled/reencoded with metadata removed and sent as native image
inputs only to models advertising vision. Apple receives document text only.
The draft shows removable file chips; sending is explicit. History decoding
remains compatible with old messages that have no attachment fields.

## Checks

Use stub processes/providers for stream parsing, cancellation, stale events, tool
denials, limits and subscription discovery; test Apple availability/error mapping.
Run focused Launcher tests and build. Probe availability without submitting private
data. A short fixed smoke prompt can verify each available provider. Restart with
existing signing identity. Independently review subprocess trust and lifecycle.
