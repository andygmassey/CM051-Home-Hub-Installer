# Upstream-contribution candidates for zeroclaw-labs/zeroclaw

**Rule:** only framework-level improvements (bug fixes, new channels, performance) go here. **Never** upstream moat items: Apple Mail FDA, PWG-specific hooks, privacy-classifier routing, anything in our provisional patents.

Upstream timing: after launch (mid-late May 2026), when contribution builds marketing/engineering credibility without risking IP.

---

## Candidates

| Item | What it is | Why it's not moat | Status |
|------|------------|-------------------|--------|
| Bluesky + Mattermost wizard entries | New `ChannelMenuChoice` branches in `crates/zeroclaw-runtime/src/onboard/wizard.rs` that prompt for creds, probe `com.atproto.server.createSession` / `GET /api/v4/users/me`, and write `BlueskyConfig` / `MattermostConfig`. Both schemas already existed upstream with no wizard coverage. | Framework-level channel support only – no PWG hooks, no moat logic. Fills a pre-existing gap in upstream's wizard. | Landed on fork 2026-04-24 in branch `agent/setup-channels-bluesky-mattermost`. Ready to propose upstream post-launch. |
| `zeroclaw setup channels --interactive` alias | New `Setup` top-level subcommand in `src/main.rs` dispatching to `run_channels_repair_wizard`. Surfaces the channels repair flow under a discoverable name instead of `onboard --channels-only`. | Pure CLI ergonomics; no product logic. Installers outside Ostler would benefit equally. | Landed on fork 2026-04-24. Candidate for upstream after we confirm the alias is stable. |
| WhatsApp mining tools (`list_chats`, `read_history`, `get_contact`) | Three read-only Rust tools on top of the existing WhatsApp Web channel. Paginated chat list, chronological history with since-cursor + attachment metadata, contact profile fetch. | Framework-level capability (reads only what the linked session already exposes). Zero Ostler-specific coupling, no PWG classifier hooks, no mail-extraction-moat surface. Synthetic UK test numbers + JIDs throughout. | Landed on fork 2026-04-24 (PR #2, +727/-98 on top of WIP checkpoint). Ready to upstream post-launch. |

---

## Explicitly blocked from upstream (for reference)

| Item | Why blocked |
|------|-------------|
| Apple Mail FDA channel / reader | Covered by our provisional patent; "zero CASA, zero Google API surface" is a structural moat for Ostler |
| PWG integration hooks (if any custom ones are added) | Ostler-specific; shouldn't leak into a generic framework |
| Privacy-classifier routing (personal-data → local LLM, public → cloud) | Patent-adjacent, Ostler product logic |
| Any tool that reads from `ostler_security`, `ostler_fda`, or PWG graph | Product layer, not framework layer |
