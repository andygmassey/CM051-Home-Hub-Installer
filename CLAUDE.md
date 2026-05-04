# CLAUDE.md — CM051 Home Hub Installer

This file provides guidance to Claude Code agents working in this repo.

## Project purpose

CM051 is the public-facing installer for the Lifeline Home Hub. Users run:

```bash
curl -fsSL https://ostler.ai/install.sh | bash
```

...and end up with a working local-first Lifeline Hub on their Mac.

## Related repos (sibling projects)

- **HR015 - Gaming PC** — parent infra repo, origin of this installer before it was split out. Still the authoritative home for security module, FDA extractors, website, and cross-project tooling.
- **CM050 - Home Hub Update System** — the auto-update pipeline (Sparkle) that maintains the installed Hub over time.
- **CM031 - PWG Companion** — iOS companion app.
- **ZeroClaw** (on Mac Mini at `/Users/marvin/zeroclaw/`) — the Rust agent framework the installer deploys.

## Read before committing

**Every commit in this repo must pass the Rule Zero gate from HR015's PRODUCTISATION_CHECKLIST.md:**

- No real-person names, emails, phone numbers, or conversation transcripts in fixtures
- No committed secrets (.env, SERVER_INFO.md, API keys, signing keys)
- Real-person data in `fixtures_private/` (gitignored) only

The pre-commit hook at `.git/hooks/pre-commit` (symlinked from HR015) enforces this automatically.

## Design principles

1. **This is user-facing public code.** Every line must be reviewable by a beta tester or a security auditor. No internal process noise, no stale personal references, no TODO comments naming real people.
2. **Fail loud, fail early.** If a dependency is missing or a permission is denied, show a clear error with the exact next step. Do not silently degrade.
3. **Idempotent where possible.** Re-running the installer should be safe. Phase 1 always runs; Phase 3 detects already-installed state and skips.
4. **No upload by default.** The installer asks before anything touches the network beyond homebrew / language-ecosystem downloads. Personal data never leaves the user's Mac.
5. **Follow the existing 4-phase structure:**
   - Phase 1: Prerequisites check (automatic, no input)
   - Phase 2: Collect all user input upfront (~2 min)
   - Phase 3: Install unattended (~10-15 min)
   - Phase 4: Health check + next steps

## Current active work

See `PLAN.md` for the current workstream (channel configurator + OAuth for launch).

## Platform assumptions

- macOS only (Intel or Apple Silicon; Apple Silicon recommended for local inference)
- macOS 14+ target (ties to Swift helper binary + passkey support)
- Bash 3.2+ (ships with macOS)
- User-interactive terminal (runs with `/dev/tty` redirect if piped from `curl`)

## Security posture

- Secrets never land in stdout, never in `set -x` output
- User-provided passphrases / tokens are read with `read -s`
- Installer logs are opt-in and written to `$HOME/Library/Logs/Lifeline/install-YYYYMMDD-HHMMSS.log`
- No telemetry without explicit consent

## Writing style

- British English in all user-facing messages
- En-dashes ` – ` with spaces, never emdashes
- Short, direct copy; no marketing fluff inside the installer
