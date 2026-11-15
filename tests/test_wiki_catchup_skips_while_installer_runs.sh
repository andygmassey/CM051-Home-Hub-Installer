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
#   A. install.sh's own marker (state/install-in-progress, pid=N), fresh, with
#      a live pid: exit 0, no tick, no try spent, reason logged.
#   A2/A3. the same marker with a dead pid, or older than 6 h: the tick RUNS.
#   A4. a process with "/install.sh" in its argv and no marker (a pager on
#      the file): the tick RUNS. The old pgrep skipped forever on this.
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
       && grep -q 'an install is running' "$h/.ostler/logs/wiki-recompile-catchup.log" 2>/dev/null; then
        ok "$label: exited 0, tick not run, no try spent, reason logged"
    else
        bad "$label: rc=$rc tick_ran=$([ -e "$h/tick-ran" ] && echo yes || echo no) tries=$(tries_of "$h")"
    fi
}

judge_runs() {  # $1 home, $2 rc, $3 label: the tick MUST run
    local h="$1" rc="$2" label="$3"
    if [ "$rc" -eq 0 ] && [ -e "$h/tick-ran" ] && [ "$(tries_of "$h")" = "1" ]; then
        ok "$label: not treated as an install; the tick ran and spent try 1"
    else
        bad "$label: rc=$rc tick_ran=$([ -e "$h/tick-ran" ] && echo yes || echo no) tries=$(tries_of "$h")"
    fi
}
marker() {  # $1 home, $2 pid
    mkdir -p "$1/.ostler/state"; printf 'pid=%s\n' "$2" > "$1/.ostler/state/install-in-progress"
}

# ── A. the installer's marker, fresh, naming a LIVE pid -> skip ─────────────
/bin/bash -c 'sleep 60' & FAKE_PID=$!
hA="$(new_home a)"; marker "$hA" "$FAKE_PID"
HOME="$hA" PATH="$hA/stub:/usr/bin:/bin" "$TMP/catchup"; rcA=$?
judge_skip "$hA" "$rcA" "MARKER + LIVE PID"

# ── A2. marker naming a DEAD pid -> run (an aborted install cannot wedge it) ─
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; DEAD="$FAKE_PID"; FAKE_PID=""
hA2="$(new_home a2)"; marker "$hA2" "$DEAD"
HOME="$hA2" PATH="$hA2/stub:/usr/bin:/bin" "$TMP/catchup"; judge_runs "$hA2" $? "MARKER + DEAD PID"

# ── A3. marker older than 6 h, pid alive -> run (bounded by age) ─────────────
/bin/bash -c 'sleep 60' & FAKE_PID=$!
hA3="$(new_home a3)"; marker "$hA3" "$FAKE_PID"
touch -t "$(date -v-7H +%Y%m%d%H%M 2>/dev/null || date -d '7 hours ago' +%Y%m%d%H%M)" "$hA3/.ostler/state/install-in-progress"
HOME="$hA3" PATH="$hA3/stub:/usr/bin:/bin" "$TMP/catchup"; judge_runs "$hA3" $? "MARKER 7 H OLD"
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=""

# ── A4. Archie's case: a process with /install.sh in its argv, NO marker ─────
# (a pager or an editor on the file). Must NOT hold the skip forever.
mkdir -p "$TMP/fake/Ostler.app/Contents/Resources"
printf '#!/bin/bash\nsleep 60\n' > "$TMP/fake/Ostler.app/Contents/Resources/install.sh"
/bin/bash "$TMP/fake/Ostler.app/Contents/Resources/install.sh" & FAKE_PID=$!
sleep 0.3
hA4="$(new_home a4)"
HOME="$hA4" PATH="$hA4/stub:/usr/bin:/bin" "$TMP/catchup"; judge_runs "$hA4" $? "ARGV MATCH, NO MARKER"
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
