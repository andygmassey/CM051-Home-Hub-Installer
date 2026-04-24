# PLAN.md — CM051 Home Hub Installer

**Last updated:** 2026-04-24
**Launch target:** mid-late May 2026

---

## Current active workstream: channel configurator for launch

Status: **proposed, awaiting Andy's sign-off before agent dispatch**

### Goal

At the end of the installer, walk the user through configuring every ZeroClaw channel they want to use, producing a valid `~/.zeroclaw/config.toml` channel section and restarting ZeroClaw cleanly.

### Why

- Users should not have to hand-edit TOML to onboard a messaging channel.
- Andy's first beta tester (Jeffrey) uses Telegram — we need a painless path to "enable Telegram" at install time, not a bash session editing config files.
- Productisation win: the current setup expects a developer audience; the configurator makes it accessible to non-technical users.

### Scope for launch (mid-late May 2026)

All OoTB ZeroClaw channels supported, grouped by configuration complexity:

| Group | Channels | Flow |
|-------|----------|------|
| **Auto-detect** | iMessage, Apple Mail | No prompts — relies on FDA already granted earlier in installer |
| **Token + allowlist** | Telegram, Discord, Slack, Mattermost, Bluesky, Mastodon, Nostr | Prompt for bot token (or equivalent) + list of allowed user IDs |
| **Pair-code / QR** | WhatsApp Web | Reuses existing ZeroClaw pair-code flow; defer QR scan to post-install on first run |
| **OAuth browser-callback** | Gmail, Google Workspace, Outlook | Local HTTP callback server + browser launch + token exchange + encrypted store |
| **External-account stub** | Matrix, Signal, IRC | Show "requires external account; configure later via `lifeline channel <name> setup`" |

### Out of scope (v1.1 or later)

- Rich TUI with arrow-key navigation (launch uses clean prompts; polish later)
- Per-channel connection health dashboard
- Re-run wizard for users who skipped channels first time (defer to `lifeline channel setup`)
- Channel removal flow

### Architecture

**Split responsibilities:**

- **`zeroclaw setup channels` subcommand** (new, in Rust, lives in ZeroClaw on Mac Mini)
  - Accepts `--interactive` flag
  - Reflects over the existing `ChannelConfig` trait to enumerate supported channels
  - Prompts for required fields per channel
  - Validates input (hits provider APIs to confirm tokens work before writing)
  - Writes to `~/.zeroclaw/config.toml` under `[channels_config.<name>]`
  - Stores secrets via ZeroClaw's existing ChaCha20 credentials pattern, not plaintext
  - Exits with structured JSON on success for installer to parse

- **Installer Phase 4 addition** (bash, in `install.sh`)
  - After health check, invoke `zeroclaw setup channels --interactive`
  - Installer stays out of channel-specific logic — delegates to ZeroClaw's own knowledge of its schemas

Why split this way: the config schemas already live in ZeroClaw's Rust. Duplicating them in bash is a guaranteed drift. Delegating keeps one source of truth.

### Sizing

- **Token + allowlist channels** — 1 day
- **OAuth (Gmail / Workspace / Outlook)** — 2-3 days (local callback server + token exchange + app registration)
- **WhatsApp reuse + external-account stubs** — 0.5 day
- **Installer wiring + testing** — 1 day
- **Total: 4-5 focused days**

### Risks

- OAuth app registration (Google + Microsoft) requires creating OAuth clients in each provider's developer console. Andy needs to do this once, reusable afterwards.
- Google's OAuth has a verification process for sensitive scopes. Gmail read is unrestricted; Gmail modify may need verification. Assess before committing to scope.
- Microsoft OAuth has different flow vs Google — two separate code paths.
- WhatsApp Web channel in ZeroClaw may have staleness issues under the installer context (session not yet established); may want to defer WhatsApp pairing to a post-install "run once" step.

---

## Backlog (post-channel-configurator)

- Pretty TUI (consider `gum` or a small Rust TUI)
- Checkpoint / resume — resume install if interrupted in Phase 3
- Offline install mode (bundle all deps in a tarball for air-gapped install)
- Windows installer (far post-launch; out of scope for May)
- Linux installer (far post-launch; out of scope for May)

---

## References

- Parent repo: `/Users/andy/Documents/Projects/HR015 - Gaming PC`
- ZeroClaw source: `ssh macmini ~/zeroclaw/` (on Mac Mini at 192.168.1.72)
- ZeroClaw channel schemas: `~/zeroclaw/src/config/schema.rs` on Mac Mini
- Pre-commit hook: symlinked from `../HR015 - Gaming PC/.githooks/pre-commit`
