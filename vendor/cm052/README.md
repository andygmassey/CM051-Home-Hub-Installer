# CM052 – PWG AI Conversation Ingest

Unifies chat history from the user's hub channels (iMessage, WhatsApp,
email, Telegram) into a single conversation list, and wires each
finalised conversation to CM048 for fact extraction into the PWG.

## What this is and isn't

- **Is:** a source-agnostic unifier. It reads ZeroClaw's gateway
  sessions DB plus per-channel JSONLs and yields a normalised
  `Conversation` stream.
- **Is:** a continuation-router stub. v0.1 always returns the user's
  local assistant as the route. v0.2 consults a BYOM-keys registry
  per conversation provenance.
- **Is not:** a chat UI. The desktop UI is a re-skinned ZeroClaw
  Tauri app (separate ticket). The iOS UI is a native SwiftUI client
  in CM031 (separate ticket).
- **Is not:** a chat-history store. ZeroClaw's gateway already stores
  transcripts; this project reads them, it does not own them.
- **Is:** an external-LLM ingest as of v0.2 -- the Claude Code
  watcher reads `~/.claude/projects/*/<sid>.jsonl` and the ChatGPT
  export adapter recursively scans `~/Documents/Ostler/imports/chatgpt/`
  for `conversations.json` files, both normalising into the
  source-agnostic `Conversation` schema and emitting via the
  unifier. Only the Claude Desktop LevelDB adapter remains
  stubbed at this revision; see `PLAN.md`.
- **Is:** the dual-storage origin point. External-LLM
  conversations land twice -- as CM048 facts (gist) AND as a
  human-readable episodic markdown artefact under
  `~/Documents/Ostler/AI Conversations/<YYYY-MM-DD>/<id>.md`. PWG
  MCP `get_conversation(id)` reads the artefact back so any AI
  client can recover the unabridged source after a vector hit.

## Read first

1. `CLAUDE.md` in this directory – locked decisions, security rules
2. `PLAN.md` – phased build plan, v0.1 scope, v0.2 backlog
3. `../HR015 - Gaming PC/PRODUCTISATION_CHECKLIST.md`
   – commit-time gate
4. `../CM048 - PWG Conversation Processing/CLAUDE.md`
   – the downstream pipeline this wires into

## Quickstart

```bash
python -m venv .venv && . .venv/bin/activate
pip install -e '.[dev]'
pytest
```

## Productisation hook

Install the pre-commit PII guard before your first commit:

```bash
"../HR015 - Gaming PC/.githooks/install.sh"
```

Run from inside the repo. The hook is symlinked from HR015 so all
sibling PWG repos share one source of truth.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `CM052_USER_HUB_DIR` | `~/.zeroclaw/workspace/sessions/` | Source dir for both launch adapters |
| `CM052_USER_EMAIL` | (no default) | Required for transcript rendering. Fails fast with config-key hint if unset. |
| `CM052_ASSISTANT_NAME` | `Assistant` | Speaker label for `role=assistant` lines |
| `CM052_OUTBOX_DIR` | `~/.pwg/cm052/outbox` | Where the wire stages transcript pairs before POST |
| `CM052_CM048_ENDPOINT` | `http://localhost:8089/api/v1/conversation/process` | CM048 fact-extraction endpoint |
| `CM052_LOCAL_ASSISTANT_WS_URL` | `ws://localhost:8089/ws/chat` | Local-assistant WebSocket the routing stub returns |
| `CM052_CLAUDE_CODE_PROJECTS_DIR` | `~/.claude/projects` | Source dir the Claude Code watcher tails |
| `CM052_CLAUDE_CODE_DEBOUNCE_SECS` | `300` | Idle window before a session JSONL is treated as finalised |
| `OSTLER_CHATGPT_IMPORT_DIR` | `~/Documents/Ostler/imports/chatgpt` | Drop folder the ChatGPT export adapter recursively scans for `conversations.json` |
| `OSTLER_AI_CONVERSATIONS_DIR` | `~/Documents/Ostler/AI Conversations` | Episodic store for external-LLM conversations (dual-storage rule) |
