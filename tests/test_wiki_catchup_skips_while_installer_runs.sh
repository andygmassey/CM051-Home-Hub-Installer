#!/usr/bin/env bash
# The first-day wiki catch-up agent must not compile while an install runs.
#
# THE DEFECT (v1.0.117 thin walk, W6). install.sh writes
# com.creativemachines.ostler.wiki-recompile-catchup with StartInterval 1800
# mid-install. Its first tick landed while the installer's own baseline
# compile was still running, so two compiles ran in parallel and the
# catch-up's Obsidian rewrite mutated the wiki while the installer counted it.
#
# WHAT THIS DOES. Carves the REAL wrapper heredoc out of install.sh, runs it
# with HOME in a temp dir and a fake wiki-recompile-tick.sh that leaves a
# marker when invoked, in three shapes:
#
#   A. A REAL process whose command line holds "/install.sh" is running (the
#      same pgrep predicate the engine supervisor and the assistant watchdog
#      use). The wrapper must exit 0, NOT invoke the tick, NOT spend a try,
#      and log why.
#   B. The test seam says an install is running: same expectations.
#   C. CONTROL: the seam says nothing is running. The tick MUST run and one
#      try MUST be spent. Without this, a wrapper that never ticks passes A+B.
#
# Exit: 0 pass, 1 fail, 2 cannot-run.

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO/install.sh}"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: no install.sh at $INSTALL_SH" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "CANNOT-RUN: no pgrep" >&2; exit 2; }

TMP="$(mktemp -d)"; FAKE_PID=""
cleanup() { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

awk '/bin\/ostler-wiki-recompile-catchup" <</{p=1; next} /^WCUEOF$/{if(p) exit} p' \
    "$INSTALL_SH" > "$TMP/catchup"
if ! head -1 "$TMP/catchup" | grep -q '^#!/usr/bin/env bash'; then
    echo "CANNOT-RUN: could not carve the catch-up wrapper heredoc" >&2; exit 2
fi
chmod +x "$TMP/catchup"
printf '  carved wrapper: %s lines\n' "$(wc -l < "$TMP/catchup" | tr -d ' ')"

new_home() {
    local h="$TMP/home.$1"
    mkdir -p "$h/.ostler/bin" "$h/Library/LaunchAgents"
    printf '#!/bin/bash\necho ran > "%s/tick-ran"\n' "$h" > "$h/.ostler/bin/wiki-recompile-tick.sh"
    chmod +x "$h/.ostler/bin/wiki-recompile-tick.sh"
    # launchctl stub: the wrapper must never reach the real one.
    mkdir -p "$h/stub"; printf '#!/bin/bash\necho "$@" >> "%s/launchctl.log"\n' "$h" > "$h/stub/launchctl"
    chmod +x "$h/stub/launchctl"
    echo "$h"
}
tries_of() { cat "$1/.ostler/state/wiki-recompile-catchup.tries" 2>/dev/null || echo none; }

judge_skip() {  # $1 home, $2 rc, $3 label
    local h="$1" rc="$2" label="$3"
    if [ "$rc" -eq 0 ] && [ ! -e "$h/tick-ran" ] && [ "$(tries_of "$h")" = "none" ] \
       && grep -q 'install or uninstall is running' "$h/.ostler/logs/wiki-recompile-catchup.log" 2>/dev/null; then
        ok "$label: exited 0, tick not run, no try spent, reason logged"
    else
        bad "$label: rc=$rc tick_ran=$([ -e "$h/tick-ran" ] && echo yes || echo no) tries=$(tries_of "$h")"
    fi
}

# ── A. a real installer-shaped process ────────────────────────────────────
mkdir -p "$TMP/fake/Ostler.app/Contents/Resources"
printf '#!/bin/bash\nsleep 60\n' > "$TMP/fake/Ostler.app/Contents/Resources/install.sh"
/bin/bash "$TMP/fake/Ostler.app/Contents/Resources/install.sh" & FAKE_PID=$!
sleep 0.3
if ! pgrep -f '/install\.sh' >/dev/null 2>&1; then
    echo "CANNOT-RUN: pgrep cannot see the fake installer process" >&2; exit 2
fi
hA="$(new_home a)"
HOME="$hA" PATH="$hA/stub:/usr/bin:/bin" "$TMP/catchup"; rcA=$?
judge_skip "$hA" "$rcA" "REAL PROCESS"
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""

# ── B. the seam says an install is running ────────────────────────────────
hB="$(new_home b)"
HOME="$hB" PATH="$hB/stub:/usr/bin:/bin" OSTLER_WIKI_CATCHUP_INSTALL_RUNNING_CMD=true "$TMP/catchup"; rcB=$?
judge_skip "$hB" "$rcB" "SEAM"

# ── C. CONTROL: no install running, the tick must run ─────────────────────
hC="$(new_home c)"
HOME="$hC" PATH="$hC/stub:/usr/bin:/bin" OSTLER_WIKI_CATCHUP_INSTALL_RUNNING_CMD=false "$TMP/catchup"; rcC=$?
if [ "$rcC" -eq 0 ] && [ -e "$hC/tick-ran" ] && [ "$(tries_of "$hC")" = "1" ]; then
    ok "CONTROL: with no install running the tick ran and spent try 1"
else
    bad "CONTROL: rc=$rcC tick_ran=$([ -e "$hC/tick-ran" ] && echo yes || echo no) tries=$(tries_of "$hC")"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
