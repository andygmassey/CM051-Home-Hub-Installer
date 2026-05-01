# CM051 – Ostler Home Hub Installer

The one-shot macOS installer for the Ostler Home Hub. This is the script a user runs to go from zero to a working local-first Ostler Hub on their Mac.

```bash
curl -fsSL https://ostler.ai/install.sh | bash
```

## Install prerequisites

| Requirement | Why |
|---|---|
| macOS 13 (Ventura) or later | Modern Docker, Ollama, security features |
| Apple Silicon (M1+) | Performance for on-device AI |
| 16 GB RAM minimum, 24 GB recommended | AI model size limits |
| 35 GB free disk | Docker images, AI model, embedding model, databases |
| **Plugged into AC power** | Phase 3 takes 10-15 minutes of continuous Docker pulls + Ollama model downloads. On a MacBook the hub power LaunchAgent (step 3.14) pauses Docker and Ollama on battery, which makes the installer's readiness probes time out. Stay on AC for the full install. |

Run `bash install.sh --check` to verify prerequisites without installing anything. The check warns if you're on battery.

### Mid-install battery transitions

A MacBook install spawns a background battery watcher at the start of Phase 3 (step 3.0a). It polls `pmset` every 60 seconds and prints a yellow warning if the user disconnects from AC, then a green confirmation when they plug back in. The watcher exists because the hub-power LaunchAgent that pauses Docker / Ollama on battery is not installed until step 3.14, leaving Phase 3 itself unprotected.

The watcher is killed at the start of Phase 4 (so health-check output is not interleaved) and is also killed by an EXIT trap as a backup. Mac Mini / Studio installs see no watcher (no battery present, nothing to poll).

---

## Status (2026-04-24)

- `install.sh` moved out of HR015 into its own project to give it a dedicated UX-iteration runway pre-launch and clear public auditability
- 2,268 lines of bash, structured into 4 phases:
  1. Check prerequisites (macOS version, Apple Silicon, RAM, disk)
  2. Collect all user input upfront (~2 min)
  3. Unattended install (~10-15 min)
  4. Health check + next steps
- Launch target: mid-late May 2026 alongside the product

## Active work (see PLAN.md)

- Channel configurator step — interactive wizard at the end of install to configure all OoTB ZeroClaw channels (Telegram, Discord, Slack, iMessage, Apple Mail, WhatsApp, Gmail, Google Workspace, Outlook, Matrix, Signal, IRC, etc.)
- OAuth local-callback flow for Gmail / Google Workspace / Outlook
- Nice TUI (gum / dialog / custom) to replace raw prompts

## Hub power policy (MacBook-as-Hub)

The installer wires in a LaunchAgent that pauses and resumes Docker + Ollama based on AC / battery state, and brings services back cleanly after sleep. This is what lets Ostler run on a laptop Hub without destroying the battery.

- Scripts: shipped from HR015 under `hub-power/`. Design doc: `HR015/HUB_PORTABILITY_PLAN.md`.
- Wired at step 3.14 of `install.sh`, which sources `hub-power/INSTALL_SNIPPET.sh`.
- Installed copy: `~/.ostler/hub-power/`.
- LaunchAgent plist: `~/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist` (label `com.creativemachines.ostler.hub-power`).
- User override: `~/.ostler/power.conf` with `POWER_POLICY=normal | aggressive | eco`.
- Log: `~/.ostler/hub-power.log` (bounded to the last 10,000 lines).

Mac Mini / Studio owners need do nothing. The watcher sees tier `ac` every tick and takes no action.

### Manual management

Check status:

```bash
launchctl list | grep com.creativemachines.ostler.hub-power
tail -f ~/.ostler/hub-power.log
```

Unload:

```bash
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power"
```

Reload (after editing policy or updating scripts):

```bash
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" \
    ~/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist
```

Uninstall completely:

```bash
launchctl bootout "gui/$(id -u)/com.creativemachines.ostler.hub-power"
rm ~/Library/LaunchAgents/com.creativemachines.ostler.hub-power.plist
rm -rf ~/.ostler/hub-power
# Leave ~/.ostler/power.conf if you might reinstall; the policy choice survives.
```

## Sibling projects

- **HR015 - Gaming PC** - parent infra repo, where this installer was born; hosts the `hub-power/` scripts
- **CM050 - Home Hub Update System** - Sparkle-based auto-update pipeline for the installed Hub (pairs with this one at runtime)
- **CM031 - PWG Companion** - iOS companion app that pairs with the Hub this installer sets up

## Security / privacy rules

1. Never commit credentials, API keys, tokens, or real-person data.
2. The installer is user-facing public code — every line is auditable.
3. Pre-commit hook at `.git/hooks/pre-commit` (symlinked from HR015's shared `.githooks/pre-commit`) scans for PII + secret leaks.
4. Real-person test data goes in `fixtures_private/` (gitignored) only.
