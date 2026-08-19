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

  # ── Current Ostler TCC client bundle identifiers (backlog #446) ──────
  #
  # These MUST match the CFBundleIdentifier the live apps actually ship
  # with, or tccutil silently no-ops and the next install inherits stale
  # grants, polluting retests. Each id below is sourced from a real
  # Info.plist / project config; keep this list in sync if any of those
  # change. Sources (paths relative to each repo's root):
  #
  #   ai.ostler.installer
  #     OstlerInstaller GUI (drives the install-time consent step:
  #     Contacts, Calendar, Reminders, Photos, AppleEvents/admin,
  #     Desktop/Documents/Downloads folder access).
  #     Source: CM051 gui/OstlerInstaller/Info.plist (CFBundleIdentifier)
  #             + CM051 gui/project.yml (CFBundleIdentifier).
  #
  #   ai.ostler.assistant
  #     Ostler Assistant daemon, locally-wrapped .app. Holds Full Disk
  #     Access (kTCCServiceSystemPolicyAllFiles) for chat.db / Contacts /
  #     Calendars reads.
  #     Source: CM051 install.sh Info.plist heredocs (CFBundleIdentifier
  #             string ai.ostler.assistant) + the FDA TCC probe that
  #             queries client='ai.ostler.assistant'.
  #
  #   ai.creativemachines.ostler-hub
  #     Ostler.app, the Tauri Hub desktop companion.
  #     Source: ostler-ai/ostler-assistant apps/tauri/tauri.conf.json
  #             ("identifier": "ai.creativemachines.ostler-hub").
  #
  #   com.creativemachines.RemoteCapture
  #     Ostler RemoteCapture.app (Microphone, System Audio / Screen
  #     Recording, Calendar, Location).
  #     Source: CM042 project.yml (bundleIdPrefix com.creativemachines +
  #             target name RemoteCapture, no PRODUCT_BUNDLE_IDENTIFIER
  #             override); corroborated by runtime defaults domain
  #             com.creativemachines.RemoteCapture.
  #
  # NOTE on the legacy bare binary: pre-.app-wrap installs ran the
  # assistant as ~/.ostler/bin/ostler-assistant, whose TCC client id is
  # the executable PATH, not a bundle id. tccutil can reset by path too,
  # so we also reset that to clear any FDA grant left by an older install.
  for bundle in ai.ostler.installer \
                ai.ostler.assistant \
                ai.creativemachines.ostler-hub \
                com.creativemachines.RemoteCapture; do
    # Reset every TCC service this fleet touches. `All` covers the
    # per-bundle resettable buckets (AddressBook=Contacts, Calendar,
    # Reminders, AppleEvents/Automation, ScreenCapture, Microphone,
    # Photos, plus SystemPolicyAllFiles where the system allows a
    # per-client reset). We also fire the named services explicitly so a
    # macOS build that scopes `All` more narrowly than expected still
    # gets each bucket cleared.
    tccutil reset All "$bundle" 2>/dev/null || true
    for svc in AddressBook Calendar Reminders AppleEvents \
               ScreenCapture Microphone Photos SystemPolicyAllFiles; do
      tccutil reset "$svc" "$bundle" 2>/dev/null || true
    done
  done

  # Legacy bare-binary assistant client (id = executable path, not a
  # bundle id). Only the FDA bucket was ever granted to it.
  tccutil reset SystemPolicyAllFiles "$HOME/.ostler/bin/ostler-assistant" 2>/dev/null || true

  # Full Disk Access (kTCCServiceSystemPolicyAllFiles) cannot always be
  # reset per-client on every macOS version; the SystemPolicyAllFiles
  # resets above are best-effort. If FDA grants survive, clear them by
  # hand in System Settings > Privacy & Security > Full Disk Access (the
  # next install re-prompts regardless, so a leftover entry there is
  # cosmetic, not a grant the new app silently inherits under a fresh
  # bundle id).
fi

echo "[wipe] done"
echo ""
echo "Verification (each should report 'No such file or directory'):"
ls -la "$HOME/.ostler" 2>&1 | head -1
ls "/Applications/Ostler.app" 2>&1 | head -1
ls "/Applications/OstlerInstaller.app" 2>&1 | head -1
ls "/Applications/Ostler RemoteCapture.app" 2>&1 | head -1
