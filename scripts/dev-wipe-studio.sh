#!/usr/bin/env bash
#
# dev-wipe-studio.sh — full Ostler wipe for dev / retest workflows
#
# Removes everything install.sh + the GUI installer place on a Mac, so the
# next install runs against a clean slate. Designed for operator use on the
# Mac Studio (or any test machine) between retest cycles. NOT intended as a
# customer-facing uninstaller — install.sh has its own --uninstall flag for
# that and respects customer data preservation conventions; this script does
# not. This is a dev tool: aggressive, no confirmation, no data preservation.
#
# What it removes:
#   - Running Ostler / zeroclaw-desktop / RemoteCapture processes
#   - All Ostler / Creative Machines LaunchAgents (user-level)
#   - /Applications/Ostler.app, /Applications/OstlerInstaller.app,
#     /Applications/Ostler RemoteCapture.app
#   - ~/.ostler/ (engine zone)
#   - ~/Library/Application Support/Ostler/
#   - ~/Library/Application Support/com.creativemachines.*
#   - ~/Documents/Ostler/ (visible zone)
#
# What it does NOT remove by default (pass --with-tcc to include):
#   - TCC permission grants (Full Disk Access etc.). Resetting these means
#     re-granting permissions on the next install, which is sometimes useful
#     for retesting the permission-grant UX and sometimes wasteful churn.
#
# What it does NOT remove ever:
#   - Keychain entries (use security delete-generic-password manually if
#     testing pairing-from-scratch)
#   - System-level LaunchDaemons in /Library/LaunchDaemons/ (v1.0 doesn't
#     install any, but if a future install starts adding them, extend below)
#
# Usage:
#   ./scripts/dev-wipe-studio.sh
#   ./scripts/dev-wipe-studio.sh --with-tcc
#
# Run as the user whose install you want to wipe. Does not require sudo for
# the default paths (everything install.sh writes is user-level on macOS).

set -euo pipefail

WITH_TCC=0
for arg in "$@"; do
  case "$arg" in
    --with-tcc) WITH_TCC=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown flag: $arg" >&2
      echo "Usage: $0 [--with-tcc]" >&2
      exit 2
      ;;
  esac
done

echo "[wipe] stopping Ostler processes"
pkill -f "Ostler|zeroclaw|RemoteCapture" 2>/dev/null || true

echo "[wipe] unloading + removing LaunchAgents"
shopt -s nullglob 2>/dev/null || true
for p in "$HOME/Library/LaunchAgents/com.creativemachines."* \
         "$HOME/Library/LaunchAgents/com.ostler."* \
         "$HOME/Library/LaunchAgents/ai.ostler."*; do
  [ -f "$p" ] || continue
  label="$(basename "$p" .plist)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$p"
done

echo "[wipe] removing /Applications bundles"
rm -rf "/Applications/Ostler.app" \
       "/Applications/OstlerInstaller.app" \
       "/Applications/Ostler RemoteCapture.app"

echo "[wipe] removing user data"
rm -rf "$HOME/.ostler" \
       "$HOME/Library/Application Support/Ostler" \
       "$HOME/Documents/Ostler"
rm -rf "$HOME/Library/Application Support/com.creativemachines."*

if [ "$WITH_TCC" = "1" ]; then
  echo "[wipe] resetting TCC permission grants (--with-tcc)"
  for bundle in com.creativemachines.OstlerInstaller \
                com.creativemachines.Ostler \
                com.creativemachines.RemoteCapture \
                ai.ostler.installer \
                ai.ostler.hub; do
    tccutil reset All "$bundle" 2>/dev/null || true
  done
fi

echo "[wipe] done"
echo ""
echo "Verification (each should report 'No such file or directory'):"
ls -la "$HOME/.ostler" 2>&1 | head -1
ls "/Applications/Ostler.app" 2>&1 | head -1
ls "/Applications/OstlerInstaller.app" 2>&1 | head -1
ls "/Applications/Ostler RemoteCapture.app" 2>&1 | head -1
