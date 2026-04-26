# CM051 – Ostler Home Hub Installer

The one-shot macOS installer for the Ostler Home Hub. This is the script a user runs to go from zero to a working local-first Ostler Hub on their Mac.

```bash
curl -fsSL https://ostler.ai/install.sh | bash
```

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

## Sibling projects

- **HR015 - Gaming PC** — parent infra repo, where this installer was born
- **CM050 - Home Hub Update System** — Sparkle-based auto-update pipeline for the installed Hub (pairs with this one at runtime)
- **CM031 - PWG Companion** — iOS companion app that pairs with the Hub this installer sets up

## Security / privacy rules

1. Never commit credentials, API keys, tokens, or real-person data.
2. The installer is user-facing public code — every line is auditable.
3. Pre-commit hook at `.git/hooks/pre-commit` (symlinked from HR015's shared `.githooks/pre-commit`) scans for PII + secret leaks.
4. Real-person test data goes in `fixtures_private/` (gitignored) only.
