#!/usr/bin/env bash
#
# tests/test_stay_awake_agent_survives_installer_exit.sh
#
# Locks the fix for the sleep launch blocker (task #338, measured
# 2026-08-13 on a v1.0.13.3 GUI install).
#
# WHAT WENT WRONG. install.sh section 3.0 prevents sleep two ways and
# neither survives the installer:
#
#   CLI path: `sudo pmset -a sleep 0`. Persistent, correct.
#   GUI path: skipped entirely, deferring to the parent .app's
#             `caffeinate -dimsu`, which is released when the .app
#             quits -- by design.
#
# The GUI path is the DMG path, so on every customer install the Mac
# kept its own sleep policy. On the measured box that was `sleep 1`
# on AC: it slept roughly every 100 seconds, and 1430 of 1439 wakes
# were DARK wakes. launchd does not schedule user agents in dark
# wake, so the assistant's iMessage poll never ran and inbound
# messages were silently never seen, answered or remembered.
#
# WHY THE OBVIOUS FIX IS WRONG. Adding `sudo pmset` back to the GUI
# branch reintroduces a closed launch blocker: install.sh's sudo
# prompt fires on a pty the GUI log drawer does not render, so it
# wedges invisibly (Studio retest #5; 2026-05-22 00:42 HKT).
#
# THE FIX UNDER TEST. A KeepAlive LaunchAgent running `caffeinate -s`.
# No root, no system-wide policy change, outlives the installer,
# removed on uninstall.
#
# AXES, and why each one is here rather than decorative:
#
#   1. The agent block exists at all.
#   2. It is NOT inside an `if OSTLER_GUI` branch. The whole defect
#      was one path getting persistence and the other not; a fix that
#      only lands on one path repeats it.
#   3. Program is /usr/bin/caffeinate with `-s`. `-s` is documented
#      as AC-only, which preserves section 3.0's deliberate
#      battery-aware posture on MacBook Hubs.
#   4. It does NOT pass `-i` or `-d`. `-i` prevents idle sleep on
#      BATTERY too and would flatten a laptop overnight; `-d` holds
#      the display on. Both are regressions dressed as thoroughness.
#   5. RunAtLoad and KeepAlive are both true. Without KeepAlive a
#      single caffeinate crash silently restores the whole defect,
#      which is precisely the failure mode being fixed.
#   6. The label is com.ostler.stay-awake, matching the uninstaller's
#      com.ostler.* sweep. A label outside that namespace leaks an
#      agent that keeps a stranger's Mac awake after uninstall.
#   7. The success line comes from the strings catalogue (Rule 0.9).
#
# NEGATIVE CONTROL: this file also asserts the test can FAIL. See
# the self-check at the end -- it strips the block from a copy and
# requires the axis-1 predicate to reject it. A gate that has never
# been shown to go red is not a gate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"

fails=0
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

[[ -f "$INSTALL_SCRIPT" ]] || { echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2; exit 1; }
[[ -f "$STRINGS" ]]        || { echo "FAIL: strings catalogue not found at $STRINGS" >&2; exit 1; }

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi

# The population control. Every assertion below is a grep, and a grep
# against a truncated or unreadable file returns zero and reads as a
# clean absence. Assert the file is the size we expect first.
lines=$(wc -l < "$INSTALL_SCRIPT" | tr -d ' ')
if [[ "$lines" -lt 15000 ]]; then
    echo "FAIL: install.sh is only $lines lines; every grep below would be untrustworthy" >&2
    exit 1
fi
printf '  (install.sh: %s lines examined)\n' "$lines"

# ── Axis 1: the agent is installed at all ──────────────────────────
if grep -q 'com\.ostler\.stay-awake' "$INSTALL_SCRIPT"; then
    ok "stay-awake LaunchAgent is installed by install.sh"
else
    bad "no com.ostler.stay-awake agent in install.sh -- the Hub sleeps after install"
fi

# ── Axis 2: it is not gated on the install path ────────────────────
# Extract the block and check no OSTLER_GUI conditional encloses it.
# Anchored on the section banner so a later refactor that moves the
# block still gets checked rather than silently skipped.
block_start=$(grep -n '3\.0-bis Keep the Hub awake' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1 || true)
if [[ -z "$block_start" ]]; then
    bad "section 3.0-bis banner missing -- cannot verify the path-gating axis"
else
    # Look at the 12 lines before the plist write for a GUI branch.
    plist_line=$(awk -v s="$block_start" 'NR>s && /STAY_AWAKE_PLIST=/ {print NR; exit}' "$INSTALL_SCRIPT")
    if [[ -z "$plist_line" ]]; then
        bad "STAY_AWAKE_PLIST assignment not found after the 3.0-bis banner"
    elif awk -v a="$block_start" -v b="$plist_line" 'NR>=a && NR<=b' "$INSTALL_SCRIPT" \
            | grep -qE '^\s*if .*OSTLER_GUI'; then
        bad "stay-awake agent is gated on OSTLER_GUI -- one path keeps the defect"
    else
        ok "stay-awake agent installs on BOTH the GUI and CLI paths"
    fi
fi

# ── Axis 3 + 4: caffeinate -s, and NOT -i or -d ────────────────────
# Read the flags out of the plist heredoc rather than grepping the
# whole file, so an unrelated `caffeinate -dimsu` elsewhere (the GUI
# app's own, which is correct and must stay) cannot satisfy or break
# this.
# NOTE: strip the tags with sed, NOT `tr -d '<>/string'`. tr takes a SET of
# characters, so that form deletes every s, t, r, i, n and g in the payload --
# it silently ate the -s and -i it was meant to be testing, reporting "-s
# missing" and "-i absent" against a plist that contained exactly one flag, -s.
# Caught only because the -s axis was expected to pass and went red.
plist_flags=$(awk '/<<.?STAYAWAKEEOF/,/^STAYAWAKEEOF/' "$INSTALL_SCRIPT" \
              | grep -oE '<string>-[a-z]+</string>' | sed -E 's#</?string>##g' || true)
if [[ -z "$plist_flags" ]]; then
    bad "no caffeinate flags found inside the stay-awake plist heredoc"
else
    if printf '%s' "$plist_flags" | grep -q 's'; then
        ok "caffeinate -s present (AC-only system-sleep assertion)"
    else
        bad "caffeinate -s missing -- the agent would not prevent system sleep"
    fi
    if printf '%s' "$plist_flags" | grep -q 'i'; then
        bad "caffeinate -i present -- would prevent idle sleep ON BATTERY and flatten a MacBook Hub"
    else
        ok "caffeinate -i absent (battery-aware posture preserved)"
    fi
    if printf '%s' "$plist_flags" | grep -q 'd'; then
        bad "caffeinate -d present -- would hold the customer's display on indefinitely"
    else
        ok "caffeinate -d absent (display still sleeps)"
    fi
fi

# ── Axis 5: RunAtLoad + KeepAlive ──────────────────────────────────
plist_body=$(awk '/<<.?STAYAWAKEEOF/,/^STAYAWAKEEOF/' "$INSTALL_SCRIPT")
for key in RunAtLoad KeepAlive; do
    if printf '%s' "$plist_body" | grep -A1 "<key>${key}</key>" | grep -q '<true/>'; then
        ok "${key} is true"
    else
        bad "${key} is not true -- a single caffeinate exit silently restores the defect"
    fi
done

# ── Axis 6: label is inside the uninstaller's namespace ────────────
if printf '%s' "$plist_body" | grep -A1 '<key>Label</key>' | grep -q 'com\.ostler\.stay-awake'; then
    ok "label com.ostler.stay-awake is inside the uninstaller's com.ostler.* sweep"
else
    bad "plist Label is not com.ostler.stay-awake -- uninstall would leak an agent that keeps the Mac awake"
fi

# ── Axis 7: Rule 0.9, the success line is catalogued ───────────────
if grep -q 'MSG_OK_STAY_AWAKE_AGENT_INSTALLED=' "$STRINGS"; then
    ok "success message is in the strings catalogue"
else
    bad "MSG_OK_STAY_AWAKE_AGENT_INSTALLED missing from $STRINGS -- set -u would abort the install here"
fi

# Every MSG_ referenced must exist, or `set -Eeuo pipefail` kills the
# install at this line. Verified explicitly because the failure is a
# hard abort mid-install, not a cosmetic gap.
if grep -q 'MSG_OK_STAY_AWAKE_AGENT_INSTALLED' "$INSTALL_SCRIPT" \
   && ! grep -q 'MSG_OK_STAY_AWAKE_AGENT_INSTALLED=' "$STRINGS"; then
    bad "install.sh references a MSG_ that the catalogue does not define"
fi

# ── NEGATIVE CONTROL ───────────────────────────────────────────────
# Prove this test can go red. Strip the agent from a scratch copy and
# require the axis-1 predicate to reject it. Without this, all the
# PASSes above are compatible with a predicate that matches anything.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
grep -v 'com\.ostler\.stay-awake' "$INSTALL_SCRIPT" > "${scratch}/install.sh"
if grep -q 'com\.ostler\.stay-awake' "${scratch}/install.sh"; then
    bad "NEGATIVE CONTROL BROKEN: stripped copy still matches; the axis-1 predicate proves nothing"
else
    ok "NEGATIVE CONTROL: axis-1 predicate rejects an install.sh with the agent removed"
fi

echo
if [[ "$fails" -eq 0 ]]; then
    echo "test_stay_awake_agent_survives_installer_exit: all axes pass, negative control fired"
    exit 0
else
    echo "test_stay_awake_agent_survives_installer_exit: ${fails} FAILURE(S)"
    exit 1
fi
