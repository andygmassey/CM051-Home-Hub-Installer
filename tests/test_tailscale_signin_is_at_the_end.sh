#!/usr/bin/env bash
#
# tests/test_tailscale_signin_is_at_the_end.sh
#
# F2 (Andy's console walk of DMG #16): every interactive moment belongs at
# the START or the END of the install, never mid-progress. Two prompts used
# to land mid-install:
#
#   1. the Tailscale browser sign-in (up to 3 minutes waiting on the
#      customer), which ran inside tailscale_connect, between the Hub app
#      and graph hydration;
#   2. the assistant daemon's Reminders TCC prompt, raised the moment the
#      daemon first started (mid-install).
#
# This test pins the order in install.sh, statically, by line number:
#
#   - tailscale_connect (binary + LaunchAgent) stays BEFORE health_check;
#   - the sign-in step (`gui_step_begin "tailscale_signin"`), the
#     `tailscale up` that mints the login URL, the #644 skip-sentinel poll and
#     every `tailscale serve` all begin AFTER health_check's STEP_BEGIN and
#     BEFORE the final assistant-daemon start;
#   - every producer and consumer of OSTLER_TAILSCALE_IP (the ip --4 read),
#     OSTLER_TAILNET_OWNER and the OSTLER_WIKI_TAILNET_URL banner is after
#     the sign-in step opens;
#   - the install-in-progress marker is set before the FIRST daemon start and
#     cleared immediately before the LAST one, at the path the daemon reads.
#
# Then it runs the real marker helpers (extracted from install.sh) against a
# throwaway HOME and checks set -> file present, clear -> file gone.
#
# Usage: tests/test_tailscale_signin_is_at_the_end.sh [path/to/install.sh]
# Exit 0 = PASS, 1 = FAIL, 2 = CANNOT-RUN.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${1:-${SCRIPT_DIR}/../install.sh}"

[[ -r "$INSTALL_SH" ]] || { echo "CANNOT-RUN: install.sh not readable at $INSTALL_SH"; exit 2; }
bash -n "$INSTALL_SH" || { echo "CANNOT-RUN: install.sh fails bash -n"; exit 2; }

FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

# first / last line number of a fixed-string match, ignoring comment lines.
_lines() { /usr/bin/grep -nF -- "$1" "$INSTALL_SH" | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1; }
first() { _lines "$1" | head -1; }
last()  { _lines "$1" | tail -1; }

HC="$(first 'gui_step_begin "health_check"')"
[[ -n "$HC" ]] || { echo "CANNOT-RUN: no gui_step_begin \"health_check\" in install.sh"; exit 2; }
echo "      health_check STEP_BEGIN at line $HC"

# The final daemon start is the LAST top-level call (no indentation).
FINAL="$(/usr/bin/grep -nE '^_ostler_start_assistant_daemon$' "$INSTALL_SH" | tail -1 | cut -d: -f1)"
FIRST_START="$(/usr/bin/grep -nE '^[[:space:]]*_ostler_start_assistant_daemon$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
[[ -n "$FINAL" && -n "$FIRST_START" ]] || { echo "CANNOT-RUN: no _ostler_start_assistant_daemon call found"; exit 2; }
echo "      first daemon start at line $FIRST_START, final at line $FINAL"

TC="$(first '"tailscale_connect"')"
if [[ -n "$TC" && "$TC" -lt "$HC" ]]; then
    pass "tailscale_connect (binary + LaunchAgent) stays before health_check ($TC < $HC)"
else
    fail "tailscale_connect step missing or moved after health_check (line ${TC:-none})"
fi

# A line-ordered assertion: every match of $1 lies strictly between lo and hi.
between() {
    local what="$1" lo="$2" hi="$3" label="$4" n=0 bad=""
    local l
    for l in $(_lines "$what"); do
        n=$((n + 1))
        if [[ "$l" -le "$lo" || "$l" -ge "$hi" ]]; then bad="${bad} ${l}"; fi
    done
    if [[ "$n" -eq 0 ]]; then
        fail "$label: no occurrence of [$what] in install.sh"
    elif [[ -n "$bad" ]]; then
        fail "$label: [$what] at line(s)${bad}, outside ($lo, $hi)"
    else
        pass "$label: all $n occurrence(s) of [$what] inside ($lo, $hi)"
    fi
}

SI="$(first 'gui_step_begin "tailscale_signin"')"
if [[ -n "$SI" && "$SI" -gt "$HC" && "$SI" -lt "$FINAL" ]]; then
    pass "tailscale_signin STEP_BEGIN at line $SI: after health_check ($HC), before final daemon start ($FINAL)"
else
    fail "tailscale_signin STEP_BEGIN must sit after health_check ($HC) and before the final daemon start ($FINAL); found line ${SI:-none}"
    SI="$HC"
fi

between 'up --hostname=ostler-hub'        "$SI" "$FINAL" "sign-in (tailscale up)"
between '.signin_skip'                    "$SI" "$FINAL" "#644 skip sentinel"
between 'serve --bg'                      "$SI" "$FINAL" "tailscale serve publish"
between 'ip --4 2>/dev/null'              "$SI" "$FINAL" "OSTLER_TAILSCALE_IP read"
between 'OSTLER_TAILNET_OWNER'            "$SI" "$FINAL" "OSTLER_TAILNET_OWNER producer + consumers"
between 'MSG_WARN_TAILSCALE_DIDN_T_SIGN_WITHIN_3MIN' "$SI" "$FINAL" "sign-in timeout warning"

BANNER="$(first '$MSG_INFO_WIKI_TAILNET_BANNER')"
if [[ -n "$BANNER" && "$BANNER" -gt "$SI" ]]; then
    pass "OSTLER_WIKI_TAILNET_URL banner ($BANNER) is after the sign-in step ($SI)"
else
    fail "OSTLER_WIKI_TAILNET_URL banner (line ${BANNER:-none}) is not after the sign-in step ($SI)"
fi

# ── install-in-progress marker ─────────────────────────────────────────
MSET="$(/usr/bin/grep -nE '^_ostler_install_marker_set$' "$INSTALL_SH" | head -1 | cut -d: -f1)"
MCLR="$(/usr/bin/grep -nE '^_ostler_install_marker_clear$' "$INSTALL_SH" | tail -1 | cut -d: -f1)"
if [[ -n "$MSET" && "$MSET" -lt "$FIRST_START" ]]; then
    pass "marker set (line $MSET) before the first daemon start ($FIRST_START)"
else
    fail "marker must be set before the first daemon start ($FIRST_START); found line ${MSET:-none}"
fi
if [[ -n "$MCLR" && "$MCLR" -eq $((FINAL - 1)) && "$MCLR" -gt "$SI" ]]; then
    pass "marker cleared on the line before the final daemon start ($MCLR, $FINAL), after the sign-in ($SI)"
else
    fail "marker clear must be the line before the final daemon start ($FINAL) and after the sign-in ($SI); found line ${MCLR:-none}"
fi
# The daemon side (ostler-reminders watcher.rs INSTALL_MARKER_RELATIVE)
# reads exactly this path relative to $HOME.
if /usr/bin/grep -qF '"${HOME}/.ostler/state/install-in-progress"' "$INSTALL_SH"; then
    pass "marker path is \${HOME}/.ostler/state/install-in-progress (the daemon's path)"
else
    fail "marker path is not \${HOME}/.ostler/state/install-in-progress"
fi

# Behaviour: run the real helpers against a throwaway HOME.
HELPERS="$(awk '/^_ostler_install_marker_set\(\) \{$/{f=1} f{print} f&&/^\}$/{n++; if(n==2) exit}' "$INSTALL_SH")"
if [[ "$(printf '%s\n' "$HELPERS" | /usr/bin/grep -c '^_ostler_install_marker_')" -ne 2 ]]; then
    fail "could not extract both marker helpers from install.sh"
else
    WORK="$(mktemp -d)"
    out="$(HOME="$WORK" bash -c "set -u; OSTLER_INSTALL_MARKER=''; $HELPERS
_ostler_install_marker_set
[[ -f \"\$HOME/.ostler/state/install-in-progress\" ]] && echo SET_PRESENT
echo \"VAR=\$OSTLER_INSTALL_MARKER\"
_ostler_install_marker_clear
[[ -e \"\$HOME/.ostler/state/install-in-progress\" ]] || echo CLEAR_GONE
echo \"VAR2=[\$OSTLER_INSTALL_MARKER]\"" 2>&1)"
    rm -rf "$WORK"
    if printf '%s' "$out" | /usr/bin/grep -q SET_PRESENT \
       && printf '%s' "$out" | /usr/bin/grep -q 'VAR=.*/.ostler/state/install-in-progress' \
       && printf '%s' "$out" | /usr/bin/grep -q CLEAR_GONE \
       && printf '%s' "$out" | /usr/bin/grep -qF 'VAR2=[]'; then
        pass "marker helpers: set writes the file, clear removes it and empties the variable"
    else
        fail "marker helpers misbehaved: $out"
    fi
fi

echo ""
if [[ "$FAILS" -gt 0 ]]; then
    echo "FAIL: test_tailscale_signin_is_at_the_end.sh ($FAILS failure(s))"
    exit 1
fi
echo "ALL PASS: test_tailscale_signin_is_at_the_end.sh"
