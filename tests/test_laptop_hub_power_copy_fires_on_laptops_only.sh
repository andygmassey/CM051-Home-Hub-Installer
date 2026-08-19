#!/usr/bin/env bash
#
# tests/test_laptop_hub_power_copy_fires_on_laptops_only.sh
#
# A laptop Hub goes silent and says nothing about it. This asserts the
# installer says it, and says it only to the customers it is true for.
#
# THE GAP THIS COPY EXISTS TO CLOSE
# ---------------------------------
# install.sh installs com.ostler.stay-awake, a KeepAlive LaunchAgent running
# `caffeinate -s`. Two documented properties decide the whole shape of this:
#
#   1. caffeinate(8) on `-s`: "This assertion is valid only when system is
#      running on AC power." On battery it holds nothing. That is correct and
#      deliberate: `-i` would hold idle sleep on battery too and flatten a
#      laptop overnight. The flag is not the bug.
#   2. Closing the lid sleeps the Mac regardless of any power assertion,
#      unless it is in closed-display mode. Apple states that mode's
#      requirement directly: "If the display is connected to a Mac laptop
#      computer with a closed lid, make sure that the Mac is connected to
#      power and using an external keyboard and mouse."
#      (support.apple.com/en-us/102501, verified 2026-08-15)
#
# So on a Mac mini or Studio the agent is sufficient and there is nothing to
# tell anyone. On a laptop the customer shuts the lid, the Mac sleeps, and the
# assistant stops receiving messages. launchd does not schedule user agents in
# dark wake, so the poll never runs and inbound messages are never seen (task
# #338, measured 2026-08-13: 1430 of 1439 wakes were dark). Nothing on screen
# distinguishes that from a Hub that is working.
#
# The remedy is honest copy, not a behaviour change. Which makes the copy the
# shipped artefact, and this its regression gate.
#
# WHAT IS ASSERTED, AND WHY IT IS SHAPED THIS WAY
# ----------------------------------------------
# Not a grep for the strings in install.sh. Presence in the file proves the
# words are THERE, never that they REACH the right customer -- and "the right
# customer" is the entire point of a hardware-gated message. So this extracts
# the two real blocks from install.sh, sources the real catalogue, stubs
# `pmset` on PATH to present laptop or desktop hardware, and reads what the
# blocks actually PRINT.
#
#   laptop on mains     the four Phase 1 lines + the seven recap lines
#   laptop on battery   the same, because the condition is ongoing and does
#                       not depend on where the cable is at install time
#   desktop Mac         NONE of them, and the Mac Mini / Studio line instead
#
# The desktop case carries its own denominator check: it must still produce
# the desktop copy. Absence of laptop copy over an empty run is indis-
# tinguishable from a clean pass, and would be a false green.
#
# The catalogue keys are checked non-empty before anything is compared. An
# unset MSG_* expands to "", every `case ... in *""*)` matches, and the whole
# suite passes against a tree that has none of this copy in it. That guard is
# what makes the red on the pre-fix tree real rather than accidental.
#
# NEGATIVE CONTROL: the end of this file strips the added lines from a copy of
# install.sh and re-runs the laptop predicate against it, requiring a reject.
# A gate never seen to fire is not evidence.
#
# Pure bash, no network, no Mac needed. Synthetic input only.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
CATALOGUE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

for f in "$INSTALL_SH" "$CATALOGUE"; do
    [ -f "$f" ] || {
        echo "test_laptop_hub_power_copy: CANNOT RUN -- missing $f" >&2
        echo "                            Nothing was rendered. Not a pass." >&2
        exit 2
    }
done

# ── The keys under test ─────────────────────────────────────────────────
# Phase 1 (prereq check) and the final recap are separate surfaces with
# separate keys; a fix landing on only one of them repeats the defect in the
# other, so both are named here.
PHASE1_KEYS=(
    MSG_INFO_LAPTOP_HUB_AWAKE_CONDITIONS
    MSG_INFO_LAPTOP_HUB_SLEEP_COST
    MSG_INFO_LAPTOP_HUB_CLOSED_DISPLAY
    MSG_INFO_LAPTOP_HUB_DESKTOP_ALTERNATIVE
)
RECAP_KEYS=(
    MSG_INFO_HUB_RECAP_LAPTOP_AWAKE
    MSG_INFO_HUB_RECAP_LAPTOP_SLEEPS
    MSG_INFO_HUB_RECAP_LAPTOP_RECEIVES_NOTHING
    MSG_INFO_HUB_RECAP_LAPTOP_MESSAGES_MISSED
    MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY
    MSG_INFO_HUB_RECAP_LAPTOP_CLOSED_DISPLAY_NEEDS
    MSG_INFO_HUB_RECAP_LAPTOP_PAUSES
)
FILEVAULT_KEYS=(
    MSG_INFO_HUB_RECAP_FILEVAULT_LOGIN
    MSG_INFO_HUB_RECAP_FILEVAULT_STARTS
)
ALL_LAPTOP_KEYS=("${PHASE1_KEYS[@]}" "${RECAP_KEYS[@]}")

echo "laptop Hub power copy: catalogue"

# shellcheck disable=SC1090
source "$CATALOGUE"

# ── Guard: every key must exist and be non-empty ────────────────────────
# Without this the comparisons below degrade to substring-matching the empty
# string, which every haystack contains. A tree with none of this copy would
# report a clean pass.
missing=0
for k in "${ALL_LAPTOP_KEYS[@]}" "${FILEVAULT_KEYS[@]}"; do
    v="${!k:-}"
    if [ -z "$v" ]; then
        fail "catalogue has no value for $k -- the copy is not in the catalogue"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -gt 0 ]; then
    echo "" >&2
    echo "test_laptop_hub_power_copy: $missing key(s) undefined or empty in" >&2
    echo "  install.sh.strings.en-GB.sh. Comparing rendered output against an" >&2
    echo "  empty string always matches, so the rest of this suite would pass" >&2
    echo "  vacuously. Refusing to continue." >&2
    exit 1
fi
pass "all ${#ALL_LAPTOP_KEYS[@]} laptop keys + ${#FILEVAULT_KEYS[@]} FileVault keys defined and non-empty"

# ── House copy rules, on the values that actually ship ──────────────────
for k in "${ALL_LAPTOP_KEYS[@]}" "${FILEVAULT_KEYS[@]}"; do
    v="${!k}"
    case "$v" in
        *"—"*|*"–"*) fail "$k contains a dash character that is not a hyphen" ;;
    esac
done
pass "no em-dashes or en-dashes in the new copy"

# ── Extract the two real blocks from install.sh ─────────────────────────
# Phase 1: the power-source check, from its heading comment through the `fi`
# that closes the laptop / desktop branch.
PHASE1_BLOCK="$(awk '
    /^# Power source check\./ { f=1 }
    f { print }
    f && /MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO/ { seen=1; next }
    seen && /^fi$/ { exit }
' "$INSTALL_SH")"

# Recap: the Hub-deployment block, from its heading comment up to (but not
# including) the support-email line that follows it.
RECAP_BLOCK="$(awk '
    /Mac Mini Hub vs MacBook Hub/ { f=1 }
    f && /MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI/ { exit }
    f { print }
' "$INSTALL_SH")"

for pair in "PHASE1_BLOCK:HAS_BATTERY" "RECAP_BLOCK:Hub deployment"; do
    name="${pair%%:*}"; probe="${pair#*:}"
    body="${!name}"
    if [ -z "$body" ] || ! printf '%s' "$body" | grep -qF "$probe"; then
        echo "test_laptop_hub_power_copy: CANNOT RUN -- failed to extract $name" >&2
        echo "  from install.sh (looked for \"$probe\"). An empty extract renders" >&2
        echo "  nothing and compares clean, which is the false green this file" >&2
        echo "  exists to prevent." >&2
        exit 2
    fi
done
pass "extracted the real Phase 1 power-source block and the real recap block"

# ── Harness ─────────────────────────────────────────────────────────────
# A stub pmset decides what hardware the blocks believe they are on. Both
# blocks detect a laptop the same way, `pmset -g batt` matching [0-9]+%, so
# one stub drives both.
mkdir -p "$WORK/bin"
make_pmset() {
    # $1 = "laptop-mains" | "laptop-battery" | "desktop"
    {
        echo '#!/bin/sh'
        case "$1" in
            laptop-mains)
                echo "echo \"Now drawing from 'AC Power'\""
                echo "echo ' -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true'"
                ;;
            laptop-battery)
                echo "echo \"Now drawing from 'Battery Power'\""
                echo "echo ' -InternalBattery-0 (id=1)\t62%; discharging; 3:41 remaining present: true'"
                ;;
            desktop)
                # A Mac mini reports the source and no battery line at all.
                echo "echo \"Now drawing from 'AC Power'\""
                ;;
        esac
    } > "$WORK/bin/pmset"
    chmod +x "$WORK/bin/pmset"
}

render() {
    # $1 = hardware, $2 = FV_ENABLED. Echoes everything the two blocks print.
    make_pmset "$1"
    {
        echo 'set -uo pipefail'
        echo 'BOLD=""; NC=""; YELLOW=""; GREEN=""; RED=""; BLUE=""'
        # The real helpers prefix and route to the GUI log; for a copy test
        # only the text matters, so these are the thinnest stand-ins that
        # still keep the four channels distinguishable in the transcript.
        echo 'info() { echo "[info]  $*"; }'
        echo 'warn() { echo "[warn]  $*"; }'
        echo 'ok()   { echo "[ok]    $*"; }'
        printf 'source %q\n' "$CATALOGUE"
        printf 'FV_ENABLED=%q\n' "$2"
        printf 'CONFIG_DIR=/tmp/o; DATA_DIR=/tmp/o; LOGS_DIR=/tmp/o\n'
        printf '%s\n' "$PHASE1_BLOCK"
        printf '%s\n' "$RECAP_BLOCK"
    } > "$WORK/render.sh"
    PATH="$WORK/bin:$PATH" bash "$WORK/render.sh" 2>&1
}

says() {
    # says <output> <key> -- the rendered text contains the catalogue value
    case "$1" in
        *"${!2}"*) return 0 ;;
        *) return 1 ;;
    esac
}

echo ""
echo "laptop Hub power copy: what each machine is told"

# ── Case 1: laptop on mains ─────────────────────────────────────────────
OUT_LAPTOP_AC="$(render laptop-mains false)"
for k in "${PHASE1_KEYS[@]}" "${RECAP_KEYS[@]}"; do
    if says "$OUT_LAPTOP_AC" "$k"; then
        pass "laptop on mains is told: $k"
    else
        fail "laptop on mains is NOT told: $k"
    fi
done

# ── Case 2: laptop on battery ───────────────────────────────────────────
# The condition is ongoing. A laptop that happens to be plugged in at install
# time and one that is not must both hear it, or the customer who unplugs
# later never does.
OUT_LAPTOP_BATT="$(render laptop-battery false)"
missing_batt=0
for k in "${PHASE1_KEYS[@]}" "${RECAP_KEYS[@]}"; do
    says "$OUT_LAPTOP_BATT" "$k" || { fail "laptop on battery is NOT told: $k"; missing_batt=$((missing_batt + 1)); }
done
[ "$missing_batt" -eq 0 ] && pass "laptop on battery hears all ${#PHASE1_KEYS[@]}+${#RECAP_KEYS[@]} lines too (not gated on install-time power source)"

# ── Case 3: desktop Mac ─────────────────────────────────────────────────
# The half that makes this a gate rather than a spell-check. Desktop
# customers must not be shown a laptop warning.
OUT_DESKTOP="$(render desktop false)"
for k in "${PHASE1_KEYS[@]}" "${RECAP_KEYS[@]}"; do
    if says "$OUT_DESKTOP" "$k"; then
        fail "desktop Mac is shown laptop copy: $k"
    else
        pass "desktop Mac is not shown: $k"
    fi
done

# Denominator. Nothing rendered would satisfy every absence check above.
if printf '%s' "$OUT_DESKTOP" | grep -qF "Mac Mini / Studio Hub"; then
    pass "desktop run produced the desktop copy (absence checks had something to look at)"
else
    fail "desktop run produced no desktop copy -- the absence checks above passed over an empty render"
fi

# ── FileVault, which is not laptop-only ─────────────────────────────────
# Every Ostler service is a LaunchAgent and a LaunchAgent needs an Aqua login
# session. FileVault holds the boot at the unlock screen, so a Hub that
# restarts overnight is down until someone signs in.
OUT_FV_ON="$(render desktop true)"
for k in "${FILEVAULT_KEYS[@]}"; do
    if says "$OUT_FV_ON" "$k"; then
        pass "FileVault Mac is told: $k"
    else
        fail "FileVault Mac is NOT told: $k"
    fi
done
OUT_FV_OFF="$(render desktop false)"
for k in "${FILEVAULT_KEYS[@]}"; do
    if says "$OUT_FV_OFF" "$k"; then
        fail "Mac without FileVault is told about a login screen it will not see: $k"
    else
        pass "Mac without FileVault is not shown: $k"
    fi
done

# ── NEGATIVE CONTROL ────────────────────────────────────────────────────
# Strip the added lines from a copy of install.sh and require the laptop
# predicate to reject it. If this passes, every green above is decoration.
echo ""
echo "laptop Hub power copy: negative control"

STRIPPED="$WORK/install_stripped.sh"
grep -vE 'MSG_INFO_LAPTOP_HUB_|MSG_INFO_HUB_RECAP_LAPTOP_' "$INSTALL_SH" > "$STRIPPED"

STRIP_PHASE1="$(awk '
    /^# Power source check\./ { f=1 }
    f { print }
    f && /MSG_OK_POWER_SOURCE_AC_DESKTOP_MAC_NO/ { seen=1; next }
    seen && /^fi$/ { exit }
' "$STRIPPED")"
STRIP_RECAP="$(awk '
    /Mac Mini Hub vs MacBook Hub/ { f=1 }
    f && /MSG_INFO_NEED_HELP_EMAIL_SUPPORT_OSTLER_AI/ { exit }
    f { print }
' "$STRIPPED")"

make_pmset laptop-mains
{
    echo 'set -uo pipefail'
    echo 'BOLD=""; NC=""; YELLOW=""; GREEN=""; RED=""; BLUE=""'
    echo 'info() { echo "[info]  $*"; }'
    echo 'warn() { echo "[warn]  $*"; }'
    echo 'ok()   { echo "[ok]    $*"; }'
    printf 'source %q\n' "$CATALOGUE"
    printf 'FV_ENABLED=false\n'
    printf 'CONFIG_DIR=/tmp/o; DATA_DIR=/tmp/o; LOGS_DIR=/tmp/o\n'
    printf '%s\n' "$STRIP_PHASE1"
    printf '%s\n' "$STRIP_RECAP"
} > "$WORK/red.sh"
RED_OUT="$(PATH="$WORK/bin:$PATH" bash "$WORK/red.sh" 2>&1)"

red_leaks=0
for k in "${PHASE1_KEYS[@]}" "${RECAP_KEYS[@]}"; do
    says "$RED_OUT" "$k" && red_leaks=$((red_leaks + 1))
done
if [ "$red_leaks" -gt 0 ]; then
    fail "negative control: laptop copy still rendered after being stripped ($red_leaks key(s)) -- this test cannot detect its own absence"
else
    pass "negative control: with the lines stripped, a laptop is told none of it (the predicate does fire)"
fi
if ! printf '%s' "$RED_OUT" | grep -qF "Now drawing"; then
    :
fi
if [ -z "$RED_OUT" ]; then
    fail "negative control rendered nothing -- it proved only that an empty string contains no copy"
else
    pass "negative control rendered a real installer transcript to look at"
fi

echo ""
if [ "$fails" -gt 0 ]; then
    printf '\033[0;31mlaptop Hub power copy: %d failure(s)\033[0m\n' "$fails"
    exit 1
fi
printf '\033[0;32mlaptop Hub power copy: laptops are told, desktops are not\033[0m\n'
