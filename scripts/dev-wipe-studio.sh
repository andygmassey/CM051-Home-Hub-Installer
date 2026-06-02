#!/usr/bin/env bash
#
# dev-wipe-studio.sh - return a test Mac to "bare OS + my setup, minus Ostler"
#
# Removes everything install.sh + the GUI installer place on a Mac (the Ostler
# footprint AND the dependencies install.sh installs via Homebrew), so the next
# install runs against a clean slate WITHOUT a macOS reinstall. This is the
# fast alternative to wiping + re-logging-in to iCloud + re-doing System
# Settings every retest cycle.
#
# >>> WHAT IT NEVER TOUCHES (your painful-to-redo baseline is safe): <<<
#   - iCloud / Apple Account sign-in
#   - System Settings / System Preferences of any kind
#   - Remote Login (SSH), Wi-Fi, the user account, login items you set
#   - Login Keychain (pairing secrets etc. - delete manually if needed)
#   - Any Homebrew package NOT in the install.sh dependency allowlist below
#     (git, your own tools, etc. are untouched)
#
# What it removes:
#   - Running Ostler / zeroclaw-desktop / RemoteCapture processes
#   - All Ostler LaunchAgents (com.creativemachines.*, com.ostler.*, ai.ostler.*)
#   - /Applications/Ostler.app, OstlerInstaller.app, Ostler RemoteCapture.app,
#     and the official Ollama.app (cask)
#   - ~/.ostler/, ~/Documents/Ostler/, ~/Library/Application Support/{Ostler,com.creativemachines.*}
#   - The Colima VM (and with it the Qdrant/Oxigraph/Redis Docker volumes)
#   - The Homebrew deps install.sh installs (allowlist below) UNLESS --keep-deps
#   - TCC permission grants for the Ostler bundle IDs ONLY IF --with-tcc
#
# Usage:
#   ./dev-wipe-studio.sh                # remove footprint + deps (recommended)
#   ./dev-wipe-studio.sh --dry-run      # show exactly what would be removed
#   ./dev-wipe-studio.sh --keep-deps    # remove only the Ostler footprint
#   ./dev-wipe-studio.sh --with-tcc     # also reset Ostler TCC grants
#
# Run as the user whose install you want to wipe. No sudo needed (everything is
# user-level). Aggressive, no confirmation - use --dry-run first if unsure.

set -euo pipefail

KEEP_DEPS=0
WITH_TCC=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --keep-deps) KEEP_DEPS=1 ;;
    --with-tcc)  WITH_TCC=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "ERROR: unknown flag: $arg" >&2
       echo "Usage: $0 [--dry-run] [--keep-deps] [--with-tcc]" >&2; exit 2 ;;
  esac
done

# Homebrew packages install.sh installs. ONLY these are removed. Anything else
# you have in brew (git, your tools) is never touched.
DEP_FORMULAE=(ollama colima docker docker-compose docker-buildx lima qemu tailscale sqlcipher)
DEP_CASKS=(ollama-app)

# Real Ostler TCC subjects (bundle IDs verified from built artifacts 2026-06-02).
TCC_BUNDLES=(ai.ostler.installer ai.creativemachines.ostler-hub \
             com.creativemachines.ostler-remotecapture \
             com.creativemachines.ostler.assistant)

run() { if [ "$DRY_RUN" = "1" ]; then echo "  DRY: $*"; else eval "$*"; fi; }
say() { echo "[wipe] $*"; }

[ "$DRY_RUN" = "1" ] && say "DRY-RUN: nothing will be removed; showing intended actions only"

say "stopping Ostler processes"
run "pkill -f 'Ostler|zeroclaw|RemoteCapture' 2>/dev/null || true"

say "unloading + removing Ostler LaunchAgents"
shopt -s nullglob 2>/dev/null || true
for p in "$HOME/Library/LaunchAgents/com.creativemachines."* \
         "$HOME/Library/LaunchAgents/com.ostler."* \
         "$HOME/Library/LaunchAgents/ai.ostler."*; do
  [ -f "$p" ] || continue
  label="$(basename "$p" .plist)"
  run "launchctl bootout 'gui/$(id -u)/$label' 2>/dev/null || true"
  run "rm -f '$p'"
done

say "removing /Applications bundles"
run "rm -rf '/Applications/Ostler.app' '/Applications/OstlerInstaller.app' '/Applications/Ostler RemoteCapture.app'"

say "removing Ostler data (engine + visible zones)"
run "rm -rf '$HOME/.ostler' '$HOME/Library/Application Support/Ostler' '$HOME/Documents/Ostler'"
run "rm -rf $HOME/Library/Application\\ Support/com.creativemachines.*"

if [ "$KEEP_DEPS" = "0" ]; then
  say "tearing down Colima VM (takes the Qdrant/Oxigraph/Redis volumes with it)"
  if command -v colima >/dev/null 2>&1; then
    run "colima stop 2>/dev/null || true"
    run "colima delete -f 2>/dev/null || true"
  fi
  run "rm -rf '$HOME/.colima' '$HOME/.lima'"

  say "removing the official Ollama.app + its launchd"
  run "launchctl bootout 'gui/$(id -u)/homebrew.mxcl.ollama' 2>/dev/null || true"
  run "rm -rf '/Applications/Ollama.app'"

  if command -v brew >/dev/null 2>&1; then
    say "uninstalling install.sh Homebrew deps (allowlist only)"
    for f in "${DEP_FORMULAE[@]}"; do
      brew list --formula "$f" >/dev/null 2>&1 && run "brew uninstall --formula --ignore-dependencies '$f' 2>/dev/null || true"
    done
    for c in "${DEP_CASKS[@]}"; do
      brew list --cask "$c" >/dev/null 2>&1 && run "brew uninstall --cask '$c' 2>/dev/null || true"
    done
    run "brew autoremove 2>/dev/null || true"
  fi
else
  say "--keep-deps: leaving Ollama / Colima / Docker / Tailscale / sqlcipher in place"
fi

if [ "$WITH_TCC" = "1" ]; then
  say "resetting Ostler TCC grants (--with-tcc)"
  for b in "${TCC_BUNDLES[@]}"; do run "tccutil reset All '$b' 2>/dev/null || true"; done
else
  say "leaving TCC grants intact (pass --with-tcc to reset; stale grants for removed apps are harmless)"
fi

echo ""
say "done. iCloud, System Settings, SSH, Wi-Fi, your account: untouched."
[ "$DRY_RUN" = "1" ] && exit 0
echo ""
echo "Verification (each should report 'No such file or directory' / not-installed):"
ls -d "$HOME/.ostler" 2>&1 | head -1
ls -d "/Applications/Ostler.app" 2>&1 | head -1
ls -d "/Applications/Ollama.app" 2>&1 | head -1
command -v colima >/dev/null 2>&1 && echo "colima STILL present" || echo "colima: gone"
command -v ollama >/dev/null 2>&1 && echo "ollama STILL present" || echo "ollama: gone"
