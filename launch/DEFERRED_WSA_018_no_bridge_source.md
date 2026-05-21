---
title: DEFERRED – WSA-018 iMessage bridge install path
date: 2026-05-21
status: DEFERRED
tracker: task #406
reason: bridge.py source does not exist on disk; multiple architectural decisions required from Andy
---

# DEFERRED – WSA-018 iMessage bridge install path

## Why deferred

Cannot implement without Andy. Hit three blockers immediately.

### Blocker 1: source code does not exist

```
$ find ~/Documents/Projects -maxdepth 5 \
    \( -name "bridge.py" -o -name "imessage-bridge*" -o -name "imessage_bridge*" \) \
    -type f -o -type d
```

Zero hits across all project repos (CM010-CM055, HR015-HR020, BK005). The brief's `vendor/imessage_bridge/` reference describes a desired vendor layout, but the upstream source (`bridge.py`, `INSTALL_SNIPPET.sh`, launchd plist template) does not yet exist anywhere I can locate.

Writing `bridge.py` from scratch is out of scope for an installer-path closure PR. It requires a schema decision (which chat.db tables are polled, what does `inbox.jsonl` look like, what does idempotency look like across re-runs), and that is an architectural choice that belongs upstream, not in CM051's install.sh.

### Blocker 2: dual-user architecture detection variable

The brief says install.sh should call the bridge install snippet "when the dual-user iMessage architecture was chosen at install-time". install.sh does not currently expose a flag or env var for that choice. Two options:

- (a) Add a new install-time question (UI flow + Rule 0.9 strings + persistence to `.ostler/config` + GUI sidecar).
- (b) Auto-detect (e.g. via the presence of a separate `assistant` macOS user account).

Neither is decided. (a) is a notable UX surface (another question in an already long onboarding); (b) needs a clear detection rule that doesn't false-positive.

### Blocker 3: ownership + permissions on `/Users/Shared/imessage-bridge/inbox.jsonl`

`/Users/Shared/` is world-readable. If the bridge LaunchAgent runs as the assistant user and writes inbox.jsonl, the main user needs read access (assistant chat output) but not necessarily write. If the main user can write, an integrity boundary disappears.

Owner / mode / sticky-bit choices need a security review at the same time as the schema decision in Blocker 1.

## What I checked before deferring

- `grep -nE "imessage.bridge|imessage_bridge|bridge\.py|Users/Shared/imessage" install.sh` → zero refs. Premise of the brief ("install.sh may skip this entirely") is confirmed: install.sh does not touch this at all today.
- `find` against all `Projects/` for any `bridge.py` or `imessage_bridge*` directory → zero hits.
- Cross-reference against the assistant-agent LaunchAgent plists that DO exist in CM051 (`gui/launchd/com.creativemachines.ostler.assistant.plist`, `whatsapp-keepalive.plist`, `wiki-recompile.plist`). None of these are the iMessage bridge.

## What needs to land before this can ship

In rough order:

1. **Andy commits / authors `bridge.py`** somewhere upstream (HR015 likely; possibly a new repo like `ostler-ai/ostler-imessage-bridge` to mirror the RemoteCapture pattern). Schema for `inbox.jsonl` documented in an accompanying `SCHEMA.md`. Idempotency model + chat.db polling cadence pinned.
2. **Andy picks the architecture-detection model:** (a) install-time question, (b) auto-detect on assistant user presence, or (c) always install but no-op when single-user.
3. **Andy decides ownership / permissions** on `/Users/Shared/imessage-bridge/` (POSIX mode + owner + group).
4. **Then this PR can be written.** Pattern mirrors the existing email-ingest LaunchAgent install (Phase 3.14a-ish). Estimated ~3-4 hours once the upstream + decisions exist.

## What this PR ships instead

Nothing on the WSA-018 axis. This deferral memo is the only artefact. The companion WSA-003 verification PASS report ships in the same branch.

## Re-open trigger

Open a new TNM brief once:

- The bridge source is available (vendored or git-clonable URL), AND
- The dual-user detection model is picked, AND
- The `/Users/Shared/` ownership choice is made.

I can ship the install.sh wiring + Rule 0.9 strings + Phase 3.x integration in a single small PR once those three are settled.
