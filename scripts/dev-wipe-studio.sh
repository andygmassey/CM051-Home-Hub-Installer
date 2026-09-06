#!/usr/bin/env bash
#
# dev-wipe-studio.sh — full Ostler wipe for dev / retest workflows
#
# Leaves a Mac in the state the next install expects to find: nothing.
# Designed for operator use on the Mac Studio (or any test machine) between
# retest cycles. NOT a customer-facing uninstaller — the shipped
# `ostler-uninstall` is that, and it preserves customer data on purpose.
# This is a dev tool: aggressive, no confirmation, no data preservation.
#
# ── WHY THIS SCRIPT DELEGATES ────────────────────────────────────────────
#
# This file used to carry its OWN hand-maintained list of paths to remove.
# It drifted, silently, the way a second list always does. Measured against
# the shipped uninstaller on 2026-09-06, the hand-maintained wall left:
#
#   qdrant_data, oxigraph_data, redis_data, wiki-docs, vane_data
#       All five named Docker volumes — the graph, the vectors and the
#       compiled wiki. The script had ZERO docker lines in 163 lines, and it
#       removed ~/.ostler (which is where docker-compose.yml lives) FIRST,
#       so it destroyed the only supported route to removing them and then
#       left them. The next install ran against a populated store while the
#       header promised "a clean slate".
#   /usr/local/bin/ostler-knowledge
#       A root-owned symlink install.sh creates. The old header claimed
#       "Does not require sudo ... everything install.sh writes is
#       user-level on macOS". That was false.
#   ~/Library/Application Support/Ostler RemoteCapture
#       Removed the .app, kept its support directory.
#
# So the removal list is no longer maintained here. The shipped uninstaller
# owns it, is exercised by 8 dedicated test files and 2 workflows, and grows
# when install.sh grows. What stays below is ONLY the delta: the things the
# uninstaller keeps DELIBERATELY, which a dev wipe must not keep.
#
# ── THE DELTA, AND WHY EACH LINE IS HERE ─────────────────────────────────
#
#   ~/.ostler/data/knowledge-staging/   uninstaller preserves it so a
#                                       reinstall does not re-import 20+
#                                       minutes of Evernote. A retest wants
#                                       the import path exercised.
#   ~/.ostler/power.conf                uninstaller preserves it as operator
#                                       config that survives reinstall.
#   ~/Library/Application Support/com.creativemachines.*
#                                       dev-era bundle ids; not customer
#                                       surface, so not the uninstaller's job.
#   TCC grants (--with-tcc)             opt-in, see below.
#
# If you add a path here, first ask whether the SHIPPED uninstaller should
# be removing it. If a customer would also want it gone, it belongs there,
# not here, or this wall starts growing again.
#
# What it does NOT remove ever:
#   - Keychain entries (use security delete-generic-password manually if
#     testing pairing-from-scratch)
#
# Usage:
#   ./scripts/dev-wipe-studio.sh
#   ./scripts/dev-wipe-studio.sh --with-tcc
#
# Exit status:
#   0   wiped, and verified clean
#   1   RESIDUE — something survived, named on stdout
#   78  CANNOT-VERIFY — the wipe ran but the check could not complete
#
# Run as the user whose install you want to wipe.

set -euo pipefail

WITH_TCC=0

# ── Resolvers, not constants ─────────────────────────────────────────────
#
# Read at CALL time, never frozen at load time, so `dev_wipe_verify` can be
# sourced and driven against a sandbox HOME. The defaults ARE the production
# values: nothing here is a test-only code path, and a wrong default would
# fail the same way in the test as on the box.
_apps_dir() { printf '%s' "${DEV_WIPE_APPS_DIR:-/Applications}"; }
_bin_dir()  { printf '%s' "${DEV_WIPE_BIN_DIR:-/usr/local/bin}"; }
_ostler_dir() { printf '%s' "${HOME}/.ostler"; }
_docker()   { printf '%s' "${DEV_WIPE_DOCKER:-docker}"; }

# The five named volumes. This list is the verification DENOMINATOR only --
# removal goes through `docker compose down -v`, never through this list.
STORE_VOLUMES='qdrant_data|oxigraph_data|redis_data|wiki-docs|vane_data'

OSTLER_DIR="$(_ostler_dir)"
UNINSTALLER="${OSTLER_DIR}/bin/ostler-uninstall"

dev_wipe_main() {
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

# ── 1. The shipped uninstaller does the shared removal ───────────────────
#
# It removes the LaunchAgents, both .app bundles, the ostler-knowledge
# symlink, the RemoteCapture support dir, ~/.ostler, ~/Documents/Ostler AND
# the docker stores, in the right ORDER. Deleting ~/.ostler ourselves first
# would take docker-compose.yml with it.
UNINSTALLER_RAN=0
if [ -x "$UNINSTALLER" ]; then
  echo "[wipe] running the shipped uninstaller (it owns the removal list)"
  # An uninstaller written by an OLDER install may not know --remove-content
  # and exits 2 on an argument it does not recognise. Try the flag, and if it
  # is rejected fall back to the flagless form, which under assume-yes keeps
  # ~/Documents/Ostler -- so we say so and remove that root ourselves below.
  if OSTLER_UNINSTALL_ASSUME_YES=1 "$UNINSTALLER" --remove-content; then
    UNINSTALLER_RAN=1
  elif OSTLER_UNINSTALL_ASSUME_YES=1 "$UNINSTALLER"; then
    UNINSTALLER_RAN=1
    echo "[wipe] NOTE: this box's uninstaller does not accept --remove-content."
    echo "[wipe]       It is an older build. Removing the content root here instead."
  else
    echo "[wipe] WARNING: the shipped uninstaller failed. Falling back." >&2
  fi
else
  echo "[wipe] NOTE: no uninstaller at ${UNINSTALLER}."
  echo "[wipe]       Either nothing is installed or the install is partial."
fi

# ── 2. Stores, when the uninstaller could not run them ───────────────────
#
# `docker compose down -v` is the ONLY supported route, and it needs the
# compose file that lives under ~/.ostler. So this runs BEFORE anything
# removes that directory. A dev wipe that skips this leaves the graph, the
# vectors and the compiled wiki standing for the next install to find.
if [ "$UNINSTALLER_RAN" -eq 0 ] && [ -f "${OSTLER_DIR}/docker-compose.yml" ]; then
  echo "[wipe] removing data stores via docker compose down -v"
  ( cd "$OSTLER_DIR" && docker compose down -v ) || \
    echo "[wipe] WARNING: docker compose down -v failed; stores may survive." >&2
fi

# ── 3. Anything the uninstaller could not do, or keeps on purpose ────────
echo "[wipe] removing what the uninstaller preserves on purpose"
rm -rf "${OSTLER_DIR}/data/knowledge-staging" \
       "${OSTLER_DIR}/power.conf"
rm -rf "$OSTLER_DIR" \
       "${HOME}/Documents/Ostler" \
       "${HOME}/Library/Application Support/Ostler" \
       "${HOME}/Library/Application Support/Ostler RemoteCapture"
rm -rf "${HOME}/Library/Application Support/com.creativemachines."* 2>/dev/null || true

# Belt and braces for the older-uninstaller and no-uninstaller paths. These
# are all no-ops when step 1 succeeded.
shopt -s nullglob 2>/dev/null || true
for p in "$HOME/Library/LaunchAgents/com.creativemachines."* \
         "$HOME/Library/LaunchAgents/com.ostler."* \
         "$HOME/Library/LaunchAgents/ai.ostler."*; do
  [ -f "$p" ] || continue
  label="$(basename "$p" .plist)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$p"
done
rm -rf "$(_apps_dir)/Ostler.app" \
       "$(_apps_dir)/OstlerInstaller.app" \
       "$(_apps_dir)/Ostler RemoteCapture.app"
if [ -e "$(_bin_dir)/ostler-knowledge" ]; then
  sudo rm -f "$(_bin_dir)/ostler-knowledge" 2>/dev/null || \
    echo "[wipe] WARNING: $(_bin_dir)/ostler-knowledge survives (needs sudo)." >&2
fi

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

# ── 4. VERIFY, and let the exit code carry the answer ────────────────────
#
# 🔴 THE OLD VERSION OF THIS BLOCK WAS INVERTED, and it is worth saying how,
# because the shape recurs. It was four bare `ls PATH 2>&1 | head -1` lines
# under `set -euo pipefail`. On a SUCCESSFUL wipe the first `ls` exits 1,
# pipefail propagates it, errexit aborts the script -- so a clean wipe
# printed 1 of its 4 advertised checks and exited 1, while a wipe that
# removed NOTHING printed all 4 and exited 0. Measured, both arms.
#
# So: no bare `ls` in a pipeline, and residue is COUNTED rather than
# eyeballed. A check that cannot run is its own state and is never a pass.
}

dev_wipe_verify() {
echo ""
echo "[verify] checking for residue"
local residue=0
local cannot=0
local path p n vols agents
local APPS BIN OD
APPS="$(_apps_dir)"; BIN="$(_bin_dir)"; OD="$(_ostler_dir)"
report() { printf '  %-8s %s\n' "$1" "$2"; }

for path in "$OD" \
            "${HOME}/Documents/Ostler" \
            "${HOME}/Library/Application Support/Ostler" \
            "${HOME}/Library/Application Support/Ostler RemoteCapture" \
            "${APPS}/Ostler.app" \
            "${APPS}/OstlerInstaller.app" \
            "${APPS}/Ostler RemoteCapture.app" \
            "${BIN}/ostler-knowledge"; do
  if [ -e "$path" ]; then
    report RESIDUE "$path"
    residue=$((residue + 1))
  else
    report gone "$path"
  fi
done

# LaunchAgents: a count, so a plist nobody listed is still caught.
agents=0
for p in "$HOME/Library/LaunchAgents/com.creativemachines."* \
         "$HOME/Library/LaunchAgents/com.ostler."* \
         "$HOME/Library/LaunchAgents/ai.ostler."*; do
  [ -f "$p" ] || continue
  report RESIDUE "$p"
  agents=$((agents + 1))
done
[ "$agents" -eq 0 ] && report gone "LaunchAgents (0 Ostler plists)"
residue=$((residue + agents))

# Stores. "docker is not running" is CANNOT-VERIFY, not "no volumes".
if ! command -v "$(_docker)" >/dev/null 2>&1; then
  report CANNOT "$(_docker) not on PATH -- store volumes unverified"
  cannot=$((cannot + 1))
elif ! vols="$("$(_docker)" volume ls --format '{{.Name}}' 2>&1)"; then
  report CANNOT "docker volume ls failed -- store volumes unverified"
  cannot=$((cannot + 1))
else
  # Counting, not quiet-matching. Under pipefail a quiet grep on the right
  # of a pipe can exit on SIGPIPE and invert the arm. This repo has been
  # bitten by that before. Described rather than quoted: a comment that
  # spells out a flagged idiom becomes an instance of it, which is how a
  # scanner ends up reporting its own documentation.
  n="$(printf '%s\n' "$vols" | /usr/bin/grep -cE "$STORE_VOLUMES" || true)"
  if [ "$n" -gt 0 ]; then
    report RESIDUE "$n data store volume(s) survive:"
    printf '%s\n' "$vols" | /usr/bin/grep -E "$STORE_VOLUMES" | sed 's/^/           /'
    residue=$((residue + n))
  else
    report gone "data store volumes (0 of 5 named volumes present)"
  fi
fi

echo ""
if [ "$residue" -gt 0 ]; then
  echo "[wipe] RESIDUE: ${residue} item(s) survived. The box is NOT clean."
  return 1
fi
if [ "$cannot" -gt 0 ]; then
  echo "[wipe] CANNOT-VERIFY: ${cannot} check(s) could not run. Not a pass."
  return 78
fi
echo "[wipe] done — verified clean."
return 0
}

# Sourcing gets the function and nothing else, so a test can drive the real
# verifier rather than re-implement it. Re-implementing it is how a test ends
# up asserting on a copy that cannot drift with the thing it guards.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  return 0 2>/dev/null || true
fi

dev_wipe_main "$@"
dev_wipe_verify
