#!/usr/bin/env bash
# tests/test_the_walk_waits_for_wiki_summaries.sh
# ============================================================================
# THE DEFECT, measured on the v1.0.82 walk (2026-09-09). usage_journal_producers
# requires five producers to have written to the usage journal, and on the wiped
# box cm044_wiki_compiler had written 0 rows (v1.0.81, a long-lived box, had
# 553). At 18:53:06Z the install-time recompile tick had run its phase-1
# baseline and logged "wiki summary backfill launched in background (holds
# shared Ollama slot lock; full compile, see
# ~/.ostler/logs/wiki-recompile-summaries.log)" at 18:48:11Z; that log was still
# 0 bytes; and the probe had read the journal at about 18:51Z. The compiler's
# model calls, the only writer of a cm044-compile- row, happen in that detached
# backfill, and nothing in the walk waited for it.
#
# AND THE SECOND MEASUREMENT, at 19:08:14Z and 19:08:35Z on the same box: the
# summaries log STILL 0 bytes twenty minutes after the launch, no process of
# ours matching wiki or compile alive, both LaunchAgents "not running, runs 1,
# last exit code 0", the journal at 290 rows with cm044-compile- 0. The
# backfill was not slow; it was gone and had written nothing, and every
# liveness signal read green because the tick exits 0 for having LAUNCHED it.
#
# WHAT IS UNDER TEST: scripts/box_walk_probes/lib/wiki_summaries_wait.sh
# kickstarts the recompile LaunchAgent after the seeds and waits, bounded, for
# every sign of life to end, then counts the cm044-compile- rows either side.
# There is no host-side marker (the pidfile written at wiki-recompile-tick.sh
# :449 is never removed and the summaries log carries no sentinel), so each
# reading takes the wrapper pid, the log's size and line count so GROWTH is
# seen, the slot lock's holder, the processes of this account naming the
# compiler or the tick, and the compile container once the wrapper is gone.
# An EMPTY LOG IS NEVER COMPLETE. This suite pins:
#
#   1. IT IS WIRED. The runner sources the lib and calls wiki_summaries_wait
#      BELOW the usage seed and ABOVE the phase-2 loop, and the runner's three
#      cited lines (:42 :44 :83) still say what is cited.
#   2. THE KICKSTART TEXT. What reaches launchctl is exactly
#      `kickstart -k gui/<id -u>/com.creativemachines.ostler.wiki-recompile`.
#   3. COMPLETION IS LIVENESS AND GROWTH, NEVER THE PID ALONE. A live pid with
#      an empty log is not complete and ends as the FINDING "wrote nothing,
#      still alive"; a live pid with a growing log is CANNOT-RUN "not
#      converged in time"; a dead wrapper with a 0-byte log and nothing else
#      alive is the 19:08Z FINDING "wrote nothing", reached without burning
#      the budget; a dead wrapper with a log that grew is complete.
#   4. THE DELTA IS THE VERDICT. A positive delta is CONVERGED; a zero delta
#      on a completed compile is the FINDING that names cm044_wiki_compiler as
#      a PRESENT producer that did not write.
#   5. WHAT COULD NOT BE LOOKED AT IS NOT A FAIL. A refused kickstart falls
#      back to the installed tick and says which; no label and no tick is a
#      CANNOT-RUN; a tick that ends without a backfill is a CANNOT-RUN quoting
#      the tick's own line; an unreadable box and an explicit skip are named
#      CANNOT-RUNs.
#   6. THE DIAGNOSTIC IS PRINTED, and the summaries log's CONTENT never is.
#   7. NO SINGLE-QUOTED LITERAL $HOME reaches the box, which is the
#      converge_wait defect from the v1.0.79 walk, and the default box paths
#      resolve on the box from $HOME.
#   8. THE REMOTE TEXT SURVIVES zsh, the login shell on this estate.
#   9. MUTATION: with the delta check disabled the FINDING arm must stop
#      holding, or it was never an assertion.
#
# THE STUB BOX. OSTLER_BOX_HOST is empty, so the lib's own _ww_box_exec runs
# each remote program through /bin/sh on this machine -- the REAL remote text,
# not a mock of it -- against a fake ~/.ostler, a fake launchctl on PATH and a
# fake tick that writes the real tick's log lines in the real tick's format,
# spawns a REAL background process as the backfill (with "wiki-compiler" in its
# argv so the real pgrep sees it) and records its pid in the real pidfile path,
# so kill -0, pgrep -U and the growth reading are exercised for real. What it
# cannot cover is the ssh transport, launchd, and a docker daemon.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/scripts/box_walk_probes/lib/wiki_summaries_wait.sh"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
PROBE="$REPO/scripts/box_walk_probes/probes/usage_journal_producers.sh"

PASS=0
FAIL=0
SKIP=0
arm() { # $1 = label, $2 = condition already evaluated (0/1), $3 = detail on failure
    if [ "$2" -eq 0 ]; then
        printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$1"; printf '%s\n' "$3" | sed 's/^/         /'; FAIL=$((FAIL + 1))
    fi
}
# An arm whose prerequisite is absent is NOT a pass. Its own column, printed.
skip_arm() { # $1 = label, $2 = the missing prerequisite
    printf '  [CANNOT-RUN] %s\n' "$1"; printf '         %s\n' "$2"; SKIP=$((SKIP + 1))
}

WORK="$(mktemp -d)"
PIDS="$WORK/pids"; : > "$PIDS"
# Every backfill the stub spawns is a REAL process whose argv carries
# "wiki-compiler", so the lib's real pgrep -U sees it, which is the point. It
# is also why each arm reaps the previous arm's stubs before it starts: a
# 60-second sleeper left over from a budget arm would keep "something of ours
# is alive" true for every arm after it, and the lib would be right to refuse
# to call the backfill over. Measured on the first run of this suite: seven
# arms went red on exactly that. And all of them are killed on exit, so a red
# run cannot leave sleepers behind on the runner.
reap() {
    while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$PIDS"
    : > "$PIDS"
    sleep 1
}
cleanup() {
    reap
    rm -rf "$WORK"
}
trap cleanup EXIT

[ -f "$LIB" ] || { printf 'CANNOT-RUN: no lib at %s\n' "$LIB"; exit 78; }
[ -f "$RUNNER" ] || { printf 'CANNOT-RUN: no runner at %s\n' "$RUNNER"; exit 78; }
[ -f "$PROBE" ] || { printf 'CANNOT-RUN: no probe at %s\n' "$PROBE"; exit 78; }
PY3="$(command -v python3 || true)"
[ -n "$PY3" ] || { printf 'CANNOT-RUN: no python3 on PATH\n'; exit 78; }
command -v pgrep >/dev/null 2>&1 || { printf 'CANNOT-RUN: no pgrep on PATH\n'; exit 78; }

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

# A name-shaped canary the fake compile writes into ITS log. It must never
# reach the operator's screen: the compiler names the people it summarises.
CANARY="CANARYPERSONNAME-Q7"

# THE FAKE TICK. Writes the real tick's log lines (wiki-recompile-tick.sh:256,
# :365, :451, :454, :301) in the real tick's log() format (:57) into the real
# log path. For a launch it spawns a REAL background process as the backfill,
# with "wiki-compiler" in its argv exactly as the wrapper's bash -c text
# carries it, records its pid in the real pidfile path as :449 does, and that
# process sleeps STUB_BACKFILL_S (growing the summaries log each second when
# STUB_BACKFILL_GROW=1), then writes STUB_BACKFILL_LOGLINE into the log and
# STUB_BACKFILL_ROWS cm044-compile- rows into the journal, and exits.
cat > "$STUB_BIN/fake-tick" <<'SH'
#!/bin/sh
# The same default the real tick resolves at wiki-recompile-tick.sh:54, so
# the arm that unsets OSTLER_DIR exercises the box-side $HOME expansion in the
# stub as well as in the lib.
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
T="$L/wiki-recompile.log"
S="$L/wiki-recompile-summaries.log"
P="$O/.wiki-recompile-summaries.pid"
mkdir -p "$L"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$T"; }
sleep "${STUB_TICK_DELAY_S:-0}"
log "wiki-recompile tick start (phase 1: fast baseline, OSTLER_WIKI_SKIP_LLM=1)"
case "${STUB_TICK_MODE:-launch}" in
    fail)
        log "ERROR: wiki-compiler baseline failed (exit 1); skipping wiki-site refresh."
        exit 1
        ;;
    already)
        pid="$(cat "$P")"
        log "wiki summary backfill already running (pid ${pid}); not launching another"
        ;;
    launch)
        # :447 opens the log fresh for the new backfill.
        : > "$S"
        sh -c '
            S="$1"; J="$2"
            i=0
            while [ "$i" -lt "${STUB_BACKFILL_S:-1}" ]; do
                sleep 1
                [ "${STUB_BACKFILL_GROW:-0}" = "1" ] && printf "summarising batch %s\n" "$i" >> "$S"
                i=$((i + 1))
            done
            if [ -n "${STUB_BACKFILL_LOGLINE:-}" ]; then
                printf "%s\n" "${STUB_BACKFILL_LOGLINE}" >> "$S"
            fi
            n="${STUB_BACKFILL_ROWS:-0}"
            i=0
            while [ "$i" -lt "$n" ]; do
                printf "{\"id\": \"stub-%s\", \"session_id\": \"cm044-compile-2026-09-09T00:00:00Z\", \"purpose\": \"enriching\", \"usage\": {\"model\": \"stub\", \"input_tokens\": 3}}\n" "$i" >> "$J"
                i=$((i + 1))
            done
            exit 0
        ' wiki-compiler-stub-backfill "$S" "${STUB_JOURNAL}" >/dev/null 2>&1 </dev/null &
        printf '%s\n' "$!" > "$P"
        printf '%s\n' "$!" >> "${STUB_PIDS}"
        log "wiki summary backfill launched in background (holds shared Ollama slot lock; full compile, see ${S})"
        ;;
esac
log "wiki recompile tick complete (baseline published; summaries backfilling)"
exit 0
SH
chmod +x "$STUB_BIN/fake-tick"

# THE FAKE launchctl. Records its argv, answers `print` with STUB_LABEL_RC, and
# on `kickstart` either refuses with launchd's own wording (STUB_KICK_RC) or
# runs the fake tick, detached when STUB_TICK_DELAY_S is set so the poll has to
# wait for the log to move.
cat > "$STUB_BIN/launchctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LAUNCHCTL_LOG:?}"
here="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
    print) exit "${STUB_LABEL_RC:-0}" ;;
    kickstart)
        if [ "${STUB_KICK_RC:-0}" -ne 0 ]; then
            printf 'Could not find service "%s" in domain for uid: %s\n' "${3#*/*/}" "$(id -u)" >&2
            exit "${STUB_KICK_RC}"
        fi
        if [ "${STUB_TICK_DELAY_S:-0}" -gt 0 ]; then
            "$here/fake-tick" >/dev/null 2>&1 </dev/null &
        else
            "$here/fake-tick" >/dev/null 2>&1 </dev/null
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
SH
chmod +x "$STUB_BIN/launchctl"

# A fake ~/.ostler: a tick log with history in the tick's own format, an empty
# summaries log, and the installed tick script standing in for
# ~/.ostler/bin/wiki-recompile-tick.sh.
make_box() { # $1 = OSTLER_DIR to build, $2 = "notick" to omit the tick script
    local root="$1"
    mkdir -p "$root/logs" "$root/bin"
    printf '[2026-09-09 18:47:40] wiki-recompile tick start (phase 1: fast baseline, OSTLER_WIKI_SKIP_LLM=1)\n' > "$root/logs/wiki-recompile.log"
    printf 'rendered 12 pages\n' >> "$root/logs/wiki-recompile.log"
    printf '[2026-09-09 18:48:11] wiki summary backfill launched in background (holds shared Ollama slot lock; full compile, see %s/logs/wiki-recompile-summaries.log)\n' "$root" >> "$root/logs/wiki-recompile.log"
    printf '[2026-09-09 18:48:11] wiki recompile tick complete (baseline published; summaries backfilling)\n' >> "$root/logs/wiki-recompile.log"
    : > "$root/logs/wiki-recompile-summaries.log"
    if [ "${2:-}" != "notick" ]; then
        printf '#!/bin/sh\nexec "%s/fake-tick" "$@"\n' "$STUB_BIN" > "$root/bin/wiki-recompile-tick.sh"
        chmod +x "$root/bin/wiki-recompile-tick.sh"
    fi
}

# Source the lib in a child shell, call the step, report what it decided.
# `set -uo pipefail` in the child on purpose: that is what run_box_walk.sh runs
# under, so an unset variable in the lib fails HERE rather than on a box.
run_wait() { # $1 = lib, $2 = box dir, $3 = journal, rest = env assignments
    local lib="$1" box="$2" journal="$3"; shift 3
    env -u OSTLER_WIKI_WAIT_SKIP \
        OSTLER_BOX_HOST= \
        PATH="$STUB_BIN:$PATH" \
        OSTLER_DIR="$box" \
        OSTLER_USAGE_JOURNAL="$journal" \
        STUB_JOURNAL="$journal" \
        STUB_PIDS="$PIDS" \
        STUB_LAUNCHCTL_LOG="$box/launchctl.argv" \
        OSTLER_WIKI_WAIT_INTERVAL_S=1 \
        OSTLER_WIKI_WAIT_BUDGET_S=25 \
        "$@" \
        bash -c '
            set -uo pipefail
            . "$1"
            wiki_summaries_wait
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${WIKI_WAIT_STATE}"
            printf "ELAPSED=%s\n" "${WIKI_WAIT_ELAPSED}"
        ' _ "$lib" 2>&1
}

printf 'THE WALK WAITS FOR THE WIKI SUMMARY BACKFILL\n\n'

# ---------------------------------------------------------------------------
printf -- '-- 1. it is wired into the runner, in the right order --\n'
# ---------------------------------------------------------------------------
src_line="$(grep -n 'lib/wiki_summaries_wait.sh' "$RUNNER" | head -1 | cut -d: -f1)"
call_line="$(grep -n '^wiki_summaries_wait' "$RUNNER" | head -1 | cut -d: -f1)"
usage_line="$(grep -n '^usage_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)"
loop_line="$(grep -n '^    out="$(bash "$p" 2>&1)"' "$RUNNER" | head -1 | cut -d: -f1)"

[ -n "$src_line" ] && [ -n "$call_line" ]
arm "the runner sources the lib and calls wiki_summaries_wait" $? \
    "source line='$src_line' call line='$call_line'"

[ -n "$usage_line" ] && [ -n "$call_line" ] && [ "$call_line" -gt "$usage_line" ]
arm "the wait runs AFTER the usage seed (:$usage_line), so the seeded content is in the compile and the seed's delta stays its own" $? \
    "wait at $call_line, usage seed at $usage_line"

[ -n "$loop_line" ] && [ -n "$call_line" ] && [ "$call_line" -lt "$loop_line" ]
arm "the wait runs BEFORE the phase-2 probe loop (:$loop_line); a wait after it waits for nothing)" $? \
    "wait at $call_line, probe loop at $loop_line"

# The three line citations at the top of the runner must survive this wiring.
[ "$(sed -n '42p' "$RUNNER")" = 'PROBE_DIR="$HERE/probes"' ] \
    && [ "$(sed -n '44p' "$RUNNER")" = 'EX_CANNOT_RUN=78' ] \
    && [ "$(sed -n '83p' "$RUNNER")" = 'for f in "$PROBE_DIR"/*.sh; do' ]
arm "the runner's three cited lines (:42 :44 :83) still say what is cited" $? \
    "42=[$(sed -n '42p' "$RUNNER")] 44=[$(sed -n '44p' "$RUNNER")] 83=[$(sed -n '83p' "$RUNNER")]"

# ONE RESOLVER, NOT TWO: the lib asks the probe where the journal is.
grep -q -- '--print-journal-path' "$LIB" && grep -q -- '--print-journal-path' "$PROBE"
arm "the journal path is resolved by the PROBE's own resolver, not a copy of it" $? \
    "the lib must invoke the probe with --print-journal-path"

# ---------------------------------------------------------------------------
printf -- '\n-- 2. a finished backfill with new rows is CONVERGED, via the real kickstart text --\n'
# ---------------------------------------------------------------------------
reap
BOX2="$WORK/box2"; make_box "$BOX2"
J2="$WORK/journal2.jsonl"; : > "$J2"
out2="$(run_wait "$LIB" "$BOX2" "$J2" STUB_BACKFILL_S=3 STUB_BACKFILL_ROWS=3 STUB_TICK_DELAY_S=1 \
    STUB_BACKFILL_GROW=1 STUB_BACKFILL_LOGLINE="summarised $CANARY")"
PID2="$(cat "$BOX2/.wiki-recompile-summaries.pid" 2>/dev/null || printf 'unread')"
grep -q 'RC=0' <<< "$out2" && grep -q 'STATE=converged' <<< "$out2"
arm "three new cm044-compile- rows once nothing is alive is CONVERGED, exit 0" $? "$out2"

grep -q 'delta  : 3 row' <<< "$out2" && grep -q 'before : 0 row' <<< "$out2" && grep -q 'after  : 3 row' <<< "$out2"
arm "the before, after and delta are all printed as numbers" $? "$out2"

grep -q 'CONVERGED: the summary backfill (pid [0-9][0-9]*) ended after [0-9][0-9]*s' <<< "$out2"
arm "the CONVERGED line names the backfill pid and the elapsed time" $? "$out2"

# THE KICKSTART TEXT. What the fake launchctl recorded is what a real one
# would have been handed: kickstart -k, the gui domain of THIS uid, the label.
want_argv="kickstart -k gui/$(id -u)/com.creativemachines.ostler.wiki-recompile"
[ -f "$BOX2/launchctl.argv" ] && grep -qxF "$want_argv" "$BOX2/launchctl.argv"
arm "launchctl was handed exactly [$want_argv]" $? \
    "recorded argv: $(cat "$BOX2/launchctl.argv" 2>/dev/null || printf '(none)')"
grep -qxF "print gui/$(id -u)/com.creativemachines.ostler.wiki-recompile" "$BOX2/launchctl.argv"
arm "and the label was checked with launchctl print before it was kicked" $? \
    "recorded argv: $(cat "$BOX2/launchctl.argv" 2>/dev/null || printf '(none)')"

grep -q 'started via    : launchctl kickstart -k' <<< "$out2"
arm "the output says the compile was started by the kickstart, not the fallback" $? "$out2"

# The state was read BEFORE acting, and says so with the tick's last line.
grep -q 'tick last line : \[2026-09-09 18:48:11\] wiki recompile tick complete' <<< "$out2"
arm "the tick log's last line was read BEFORE the kickstart and printed" $? "$out2"
grep -q 'summaries log  : 0 ' <<< "$out2"
arm "and the summaries log size was read BEFORE the kickstart and printed" $? "$out2"

# The tick was detached (STUB_TICK_DELAY_S=1), so at least one reading saw the
# log unmoved: the poll loop actually polled rather than reading once.
grep -q 'no new line yet' <<< "$out2"
arm "the tick phase POLLED: a reading before the tick had logged anything was printed" $? "$out2"

# LIVENESS IS READ FROM MORE THAN THE PID. While the backfill was alive the
# real pgrep -U found it by the wiki-compiler in its argv, and its pid is on
# the reading line beside the wrapper pid.
grep -qE "wrapper pid ${PID2} alive; .*matching processes: [1-9][0-9]* \[.*${PID2}.*\]" <<< "$out2"
arm "a reading shows the wrapper pid alive AND pgrep -U listing that same pid" $? "pid=$PID2 :: $out2"
grep -q 'GREW from' <<< "$out2"
arm "and the summaries log was seen GROWING between readings" $? "$out2"
grep -q 'nothing of ours is alive any more: the backfill is over' <<< "$out2"
arm "the wait ended on nothing-alive, not on the pid alone" $? "$out2"

# THE DIAGNOSTIC BLOCK, and what it must not contain.
grep -q -- '--- diagnostic, for whoever reads this record ---' <<< "$out2" \
    && grep -q 'tick log, its own lines, last 3:' <<< "$out2" \
    && grep -q 'tick stderr : absent ' <<< "$out2" \
    && grep -qE 'summaries   : summaries log [1-9][0-9]* bytes, [1-9][0-9]* line\(s\), last written [0-9]+s ago' <<< "$out2" \
    && grep -qE "pidfile     : wrapper pid ${PID2} dead" <<< "$out2" \
    && grep -q 'slot lock   : free ' <<< "$out2" \
    && grep -qE 'processes   : [0-9]+ matching wiki-compiler\|wiki-recompile-tick under this account' <<< "$out2" \
    && grep -qE 'container   : (none|unknown|running)' <<< "$out2"
arm "the diagnostic prints the tick log, tick stderr, summaries size, pidfile, slot, processes and container" $? "$out2"
# Only the tick's OWN lines from its log: the baseline compile's tailed output
# ("rendered 12 pages" in the fixture) must not be among them.
diag_tick="$(printf '%s\n' "$out2" | sed -n '/tick log, its own lines, last 3:/,/tick stderr/p')"
grep -q 'wiki recompile tick complete' <<< "$diag_tick" && ! grep -q 'rendered 12 pages' <<< "$diag_tick"
arm "the tick log tail carries the tick's own lines and not the compile output it tails" $? "$diag_tick"
! grep -q "$CANARY" <<< "$out2"
arm "the summaries log's CONTENT never reaches the screen (name-shaped canary absent)" $? "the canary $CANARY was printed"

# ---------------------------------------------------------------------------
printf -- '\n-- 3. completion is LIVENESS AND GROWTH, never the pid alone --\n'
# ---------------------------------------------------------------------------
# (a) alive, and not a byte for the whole budget: the FINDING "wrote nothing",
# marked still alive, never CONVERGED and never a plain CANNOT-RUN.
reap
BOX3="$WORK/box3"; make_box "$BOX3"
J3="$WORK/journal3.jsonl"; : > "$J3"
out3="$(run_wait "$LIB" "$BOX3" "$J3" STUB_BACKFILL_S=60 STUB_BACKFILL_ROWS=5 OSTLER_WIKI_WAIT_BUDGET_S=3)"
grep -q 'STATE=finding' <<< "$out3" && grep -q 'FINDING: THE BACKFILL WROTE NOTHING in [0-9]*s, and it is STILL ALIVE' <<< "$out3"
arm "(a) a live backfill whose log stayed at 0 bytes for the whole budget is the FINDING wrote-nothing, still alive" $? "$out3"
grep -q "$BOX3/logs/wiki-recompile-summaries.log" <<< "$out3" && grep -q 'was 0 bytes for the whole budget' <<< "$out3"
arm "(a) and it names the log path and says 0 bytes for the whole budget" $? "$out3"
grep -q 'RC=1' <<< "$out3" && ! grep -q 'CONVERGED' <<< "$out3"
arm "(a) and it returns 1 and never says CONVERGED" $? "$out3"
grep -q 'not a pass and not a producer defect' <<< "$out3"
arm "(a) and it says in words that this is not a pass and not a producer defect" $? "$out3"

# (b) alive, and the log is GROWING at the budget: CANNOT-RUN, not converged
# in time. This is the wait that was simply too short.
reap
BOX3b="$WORK/box3b"; make_box "$BOX3b"
J3b="$WORK/journal3b.jsonl"; : > "$J3b"
out3b="$(run_wait "$LIB" "$BOX3b" "$J3b" STUB_BACKFILL_S=60 STUB_BACKFILL_GROW=1 STUB_BACKFILL_ROWS=5 OSTLER_WIKI_WAIT_BUDGET_S=4)"
grep -q 'STATE=cannot-run' <<< "$out3b" && grep -q 'CANNOT-RUN: NOT CONVERGED IN TIME' <<< "$out3b" && grep -q 'is GROWING' <<< "$out3b"
arm "(b) a live backfill whose log is growing at the budget is CANNOT-RUN, not converged in time" $? "$out3b"
grep -qE 'CANNOT-RUN: NOT CONVERGED IN TIME. After [0-9]+s' <<< "$out3b" && ! grep -q 'FINDING' <<< "$out3b"
arm "(b) with the elapsed time on the line, and no FINDING of any kind" $? "$out3b"

# (c) THE 19:08Z SHAPE. The wrapper exits at once, the log never gets a byte,
# nothing of ours is alive: the FINDING "wrote nothing", reached without
# burning the budget, naming the log path, the elapsed time and the tick's
# exit-0-for-launching.
reap
BOX3c="$WORK/box3c"; make_box "$BOX3c"
J3c="$WORK/journal3c.jsonl"; : > "$J3c"
out3c="$(run_wait "$LIB" "$BOX3c" "$J3c" STUB_BACKFILL_S=0 STUB_BACKFILL_ROWS=0 OSTLER_WIKI_WAIT_BUDGET_S=20)"
grep -q 'STATE=finding' <<< "$out3c" && grep -q 'FINDING: THE BACKFILL WROTE NOTHING\. ' <<< "$out3c" && grep -q 'is 0 bytes, the wrapper pid [0-9]* is gone after [0-9]*s' <<< "$out3c"
arm "(c) a dead wrapper, a 0-byte log and nothing alive is the FINDING wrote-nothing, naming the gone pid and the time" $? "$out3c"
grep -q "$BOX3c/logs/wiki-recompile-summaries.log" <<< "$out3c" && grep -q 'tick exited 0 for having LAUNCHED it' <<< "$out3c"
arm "(c) and it names the log path and the tick's exit-0-for-launching" $? "$out3c"
e3c="$(printf '%s\n' "$out3c" | sed -n 's/^ELAPSED=//p')"
[ -n "$e3c" ] && [ "$e3c" -lt 20 ]
arm "(c) and it did NOT burn the budget waiting on a pid that was already gone (elapsed ${e3c:-?}s of 20)" $? "$out3c"
grep -q 'NOT about' <<< "$out3c" && grep -q 'never given a chance to write' <<< "$out3c"
arm "(c) and it says this is not about the producer, which was never given a chance" $? "$out3c"
grep -q -- '--- diagnostic, for whoever reads this record ---' <<< "$out3c" && grep -q 'pidfile     : wrapper pid [0-9]* dead' <<< "$out3c"
arm "(c) and the diagnostic block follows, with the dead pidfile" $? "$out3c"

# ---------------------------------------------------------------------------
printf -- '\n-- 4. a finished compile with NO new rows is the FINDING that names the producer --\n'
# ---------------------------------------------------------------------------
reap
BOX4="$WORK/box4"; make_box "$BOX4"
J4="$WORK/journal4.jsonl"
# The journal already holds rows from OTHER producers and one older cm044 row,
# so the delta and not the total is what decides.
printf '{"id": "a", "session_id": "ostler-fda-ingest-1", "purpose": "ingesting", "usage": {"input_tokens": 3}}\n' > "$J4"
printf '{"id": "b", "session_id": "cm044-compile-2026-09-08T00:00:00Z", "purpose": "enriching", "usage": {"input_tokens": 3}}\n' >> "$J4"
out4="$(run_wait "$LIB" "$BOX4" "$J4" STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=0 \
    STUB_BACKFILL_LOGLINE="compiled 0 summaries for $CANARY")"
grep -q 'STATE=finding' <<< "$out4" && grep -q 'FINDING: THE COMPILE RAN AND cm044_wiki_compiler DID NOT WRITE' <<< "$out4"
arm "the compile ran (its log grew), everything exited, no row: a FINDING in those words" $? "$out4"
grep -q 'cm044_wiki_compiler is a' <<< "$out4" && grep -q 'PRESENT producer that did not write' <<< "$out4"
arm "and it names cm044_wiki_compiler as a PRESENT producer that did not write" $? "$out4"
grep -q 'before : 1 row' <<< "$out4" && grep -q 'after  : 1 row' <<< "$out4" && grep -q 'delta  : 0 row' <<< "$out4"
arm "the pre-existing cm044 row is counted on both ends and the delta is 0, not the total" $? "$out4"
grep -q 'RC=1' <<< "$out4" && ! grep -q 'WROTE NOTHING' <<< "$out4"
arm "and it returns 1, and is NOT confused with the wrote-nothing finding" $? "$out4"
! grep -q "$CANARY" <<< "$out4"
arm "and the log content stays off the screen on this path too" $? "the canary $CANARY was printed"

# ---------------------------------------------------------------------------
printf -- '\n-- 5. a backfill that PREDATES the kickstart is the one waited on --\n'
# ---------------------------------------------------------------------------
# wiki-recompile-tick.sh:365 logs "already running (pid N); not launching
# another" when a previous tick's backfill is still alive. The wait must then
# wait on N, not on a pid that never appears.
reap
BOX5="$WORK/box5"; make_box "$BOX5"
J5="$WORK/journal5.jsonl"; : > "$J5"
( sleep 2; printf 'summarised one\n' >> "$BOX5/logs/wiki-recompile-summaries.log"; printf '{"id": "p", "session_id": "cm044-compile-2026-09-09T18:48:11Z", "purpose": "enriching", "usage": {"input_tokens": 3}}\n' >> "$J5" ) >/dev/null 2>&1 </dev/null &
PRE5=$!
printf '%s\n' "$PRE5" >> "$PIDS"
printf '%s\n' "$PRE5" > "$BOX5/.wiki-recompile-summaries.pid"
out5="$(run_wait "$LIB" "$BOX5" "$J5" STUB_TICK_MODE=already)"
grep -q "backfill pid   : $PRE5 alive" <<< "$out5"
arm "the pre-existing backfill pid was read as ALIVE before acting" $? "$out5"
grep -q "found a backfill already running (pid $PRE5)" <<< "$out5"
arm "the tick's own 'already running (pid N)' line was honoured and that pid waited on" $? "$out5"
grep -q 'STATE=converged' <<< "$out5" && grep -q 'delta  : 1 row' <<< "$out5"
arm "and its row, written before it exited, is the delta: CONVERGED" $? "$out5"

# ---------------------------------------------------------------------------
printf -- '\n-- 6. what could not be started, or could not be looked at, is never a FAIL --\n'
# ---------------------------------------------------------------------------
# A refused kickstart falls back to the installed tick, and says which.
reap
BOX6="$WORK/box6"; make_box "$BOX6"
J6="$WORK/journal6.jsonl"; : > "$J6"
out6="$(run_wait "$LIB" "$BOX6" "$J6" STUB_KICK_RC=113 STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=2 STUB_BACKFILL_LOGLINE=done)"
grep -q 'KICKSTART refused rc=113 Could not find service' <<< "$out6"
arm "a refused kickstart is reported with launchd's own words and exit code" $? "$out6"
grep -q 'FALLBACK started pid' <<< "$out6" && grep -q 'started via    : the installed tick run directly' <<< "$out6"
arm "and the installed tick is run directly instead, and the output says so" $? "$out6"
grep -q 'STATE=converged' <<< "$out6" && grep -q 'delta  : 2 row' <<< "$out6"
arm "and the fallback compile is waited on and measured like any other" $? "$out6"
grep -qE 'tick stderr : [0-9]+ bytes ' <<< "$out6"
arm "and the fallback's stderr file exists and is named in the diagnostic" $? "$out6"

# The label is not loaded at all: the fallback is used and the record says the
# daily agent is not scheduled on this box.
reap
BOX6b="$WORK/box6b"; make_box "$BOX6b"
J6b="$WORK/journal6b.jsonl"; : > "$J6b"
out6b="$(run_wait "$LIB" "$BOX6b" "$J6b" STUB_LABEL_RC=113 STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=1 STUB_BACKFILL_LOGLINE=done)"
grep -q 'LABEL absent' <<< "$out6b" && grep -q 'NOTE: the LaunchAgent label com.creativemachines.ostler.wiki-recompile is NOT loaded' <<< "$out6b"
arm "an absent label is named, with the note that the daily recompile is not scheduled" $? "$out6b"
grep -q 'STATE=converged' <<< "$out6b"
arm "and the fallback still measures the producer" $? "$out6b"
! grep -q 'kickstart -k' "$BOX6b/launchctl.argv"
arm "and kickstart was never attempted against a label that is not loaded" $? \
    "recorded argv: $(cat "$BOX6b/launchctl.argv")"

# No label AND no tick script: nothing can start a compile. CANNOT-RUN.
reap
BOX6c="$WORK/box6c"; make_box "$BOX6c" notick
J6c="$WORK/journal6c.jsonl"; : > "$J6c"
out6c="$(run_wait "$LIB" "$BOX6c" "$J6c" STUB_LABEL_RC=113)"
grep -q 'STATE=cannot-run' <<< "$out6c" && grep -q 'CANNOT-RUN: the recompile could not be started' <<< "$out6c"
arm "no label and no installed tick is CANNOT-RUN, not a product FAIL" $? "$out6c"
grep -q 'LABEL absent' <<< "$out6c" && grep -q 'FALLBACK absent' <<< "$out6c"
arm "and both absences are named on the line" $? "$out6c"

# The tick ran and ended WITHOUT launching a backfill: its own line is quoted.
reap
BOX6d="$WORK/box6d"; make_box "$BOX6d"
J6d="$WORK/journal6d.jsonl"; : > "$J6d"
out6d="$(run_wait "$LIB" "$BOX6d" "$J6d" STUB_TICK_MODE=fail)"
grep -q 'STATE=cannot-run' <<< "$out6d" && grep -q 'CANNOT-RUN: the recompile tick ended without launching a summary backfill' <<< "$out6d"
arm "a tick that ends without a backfill is CANNOT-RUN, never a FINDING about the producer" $? "$out6d"
grep -q 'ERROR: wiki-compiler baseline failed (exit 1)' <<< "$out6d"
arm "and the tick's own ERROR line is quoted as the reason" $? "$out6d"
grep -q -- '--- diagnostic, for whoever reads this record ---' <<< "$out6d"
arm "and the diagnostic block still follows" $? "$out6d"

# The box cannot be read at all: nothing is kickstarted.
reap
BOX6e="$WORK/box6e"; make_box "$BOX6e"
J6e="$WORK/journal6e.jsonl"; : > "$J6e"
out6e="$(env OSTLER_BOX_HOST= PATH="$STUB_BIN:$PATH" OSTLER_DIR="$BOX6e" OSTLER_USAGE_JOURNAL="$J6e" \
    STUB_LAUNCHCTL_LOG="$BOX6e/launchctl.argv" bash -c '
        set -uo pipefail
        . "$1"
        _ww_box_exec() { printf "ssh: connect to host walkbox port 22: Connection refused\n" >&2; return 255; }
        wiki_summaries_wait
        printf "RC=%s\n" "$?"
        printf "STATE=%s\n" "${WIKI_WAIT_STATE}"
    ' _ "$LIB" 2>&1)"
grep -q 'STATE=cannot-run' <<< "$out6e" && grep -q 'CANNOT-RUN: the box could not be read before acting (transport exit 255)' <<< "$out6e"
arm "an unreadable box is CANNOT-RUN naming the transport exit, and nothing is kickstarted" $? "$out6e"
[ ! -f "$BOX6e/launchctl.argv" ]
arm "and launchctl was never invoked on it" $? "argv was recorded: $(cat "$BOX6e/launchctl.argv" 2>/dev/null)"

# A CHECKOUT PROBLEM MUST NOT READ AS A BOX PROBLEM.
NOPROBE="$WORK/noprobe"
cp -R "$REPO/scripts/box_walk_probes" "$NOPROBE"
rm -rf "$NOPROBE/probes"
reap
BOX6f="$WORK/box6f"; make_box "$BOX6f"
J6f="$WORK/journal6f.jsonl"; : > "$J6f"
out6f="$(run_wait "$NOPROBE/lib/wiki_summaries_wait.sh" "$BOX6f" "$J6f" STUB_BACKFILL_ROWS=2)"
grep -q 'STATE=cannot-run' <<< "$out6f" && grep -q 'checkout problem' <<< "$out6f"
arm "an absent probe is CANNOT-RUN naming the CHECKOUT, not the box" $? "$out6f"
[ ! -f "$BOX6f/launchctl.argv" ]
arm "and nothing is kickstarted when the journal cannot even be named" $? "launchctl was invoked"

# ---------------------------------------------------------------------------
printf -- '\n-- 7. skipping --\n'
# ---------------------------------------------------------------------------
reap
BOX7="$WORK/box7"; make_box "$BOX7"
J7="$WORK/journal7.jsonl"; : > "$J7"
out7="$(run_wait "$LIB" "$BOX7" "$J7" OSTLER_WIKI_WAIT_SKIP=1 STUB_BACKFILL_ROWS=2)"
grep -q 'STATE=skipped' <<< "$out7" && grep -q 'CANNOT-RUN: skipped by OSTLER_WIKI_WAIT_SKIP=1' <<< "$out7" && grep -q 'not a pass' <<< "$out7"
arm "OSTLER_WIKI_WAIT_SKIP=1 is a named CANNOT-RUN that says it is not a pass" $? "$out7"
[ ! -f "$BOX7/launchctl.argv" ]
arm "and it really does not kickstart" $? "launchctl was invoked"

# EVERY return-1 path names which of the two it was.
missing=""
for o in "$out3" "$out3b" "$out3c" "$out4" "$out6c" "$out6d" "$out6e" "$out6f" "$out7"; do
    if ! grep -qE '^  (CANNOT-RUN|FINDING)' <<< "$o"; then
        missing="${missing}
$(printf '%s' "$o" | head -3)"
    fi
done
[ -z "$missing" ]
arm "every return-1 path prints a line beginning CANNOT-RUN or FINDING" $? "$missing"

# ---------------------------------------------------------------------------
printf -- '\n-- 8. no single-quoted literal $HOME reaches the box, and the defaults resolve there --\n'
# ---------------------------------------------------------------------------
# THE CONVERGE-WAIT DEFECT (v1.0.79): a parent-side value still carrying a
# literal $HOME was interpolated inside single quotes, the box never expanded
# it, and every reading was blind. Capture every remote program this lib
# sends, split each into its single-quoted segments the way sh does (left to
# right, outside double quotes) and require that none contains $HOME.
CAP="$WORK/remote.capture"; : > "$CAP"
reap
BOX8="$WORK/box8"; make_box "$BOX8"
J8="$WORK/journal8.jsonl"; : > "$J8"
out8="$(env OSTLER_BOX_HOST= PATH="$STUB_BIN:$PATH" OSTLER_DIR="$BOX8" OSTLER_USAGE_JOURNAL="$J8" \
    STUB_JOURNAL="$J8" STUB_PIDS="$PIDS" STUB_LAUNCHCTL_LOG="$BOX8/launchctl.argv" \
    STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=1 STUB_BACKFILL_LOGLINE=done \
    OSTLER_WIKI_WAIT_INTERVAL_S=1 OSTLER_WIKI_WAIT_BUDGET_S=25 \
    CAP="$CAP" bash -c '
        set -uo pipefail
        . "$1"
        _ww_box_exec() { printf "%s\n---PROGRAM---\n" "$1" >> "$CAP"; /bin/sh -c "$1"; }
        wiki_summaries_wait >/dev/null 2>&1
        printf "STATE=%s\n" "${WIKI_WAIT_STATE}"
    ' _ "$LIB" 2>&1)"
grep -q 'STATE=converged' <<< "$out8"
arm "harness control: the capturing transport still reaches CONVERGED, so the capture is of a real run" $? "$out8"
n_prog="$(grep -c -- '---PROGRAM---' "$CAP")"
[ "$n_prog" -ge 6 ]
arm "harness control: at least six remote programs were captured (state, count, kickstart, polls, diag)" $? "captured: $n_prog"

sq_check() { # $1 = capture file; prints offending segments, exit 1 if any
    "$PY3" - "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
bad = []
for prog in text.split("---PROGRAM---"):
    for seg in re.findall(r"'[^']*'", prog):
        if "$HOME" in seg:
            bad.append(seg)
for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}
sq_out="$(sq_check "$CAP")"
[ $? -eq 0 ]
arm "no captured remote program carries \$HOME inside single quotes" $? "$sq_out"
# CONTROL: the predicate must catch the exact converge_wait shape.
printf "curl -K '\$HOME/.ostler/secrets/store-curl.conf' http://x\n---PROGRAM---\n" > "$WORK/canary.capture"
sq_check "$WORK/canary.capture" >/dev/null
[ $? -ne 0 ]
arm "CONTROL: the single-quote predicate does catch a literal -K '\$HOME/...'" $? "the canary passed"

# The default paths are derived on the box from ITS $HOME. With OSTLER_DIR
# unset and HOME redirected, the run must still find the fake ~/.ostler.
reap
HOME8="$WORK/home8"; mkdir -p "$HOME8"
make_box "$HOME8/.ostler"
J8b="$WORK/journal8b.jsonl"; : > "$J8b"
out8b="$(env -u OSTLER_DIR HOME="$HOME8" OSTLER_BOX_HOST= PATH="$STUB_BIN:$PATH" \
    OSTLER_USAGE_JOURNAL="$J8b" STUB_JOURNAL="$J8b" STUB_PIDS="$PIDS" \
    STUB_LAUNCHCTL_LOG="$HOME8/.ostler/launchctl.argv" \
    STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=1 STUB_BACKFILL_LOGLINE=done \
    OSTLER_WIKI_WAIT_INTERVAL_S=1 OSTLER_WIKI_WAIT_BUDGET_S=25 \
    bash -c '
        set -uo pipefail
        . "$1"
        wiki_summaries_wait
        printf "STATE=%s\n" "${WIKI_WAIT_STATE}"
    ' _ "$LIB" 2>&1)"
grep -q 'STATE=converged' <<< "$out8b" && grep -q "tick log       : 4 $HOME8/.ostler/logs/wiki-recompile.log" <<< "$out8b"
arm "with OSTLER_DIR unset the box's own \$HOME/.ostler is read, expanded on the box" $? "$out8b"

# ---------------------------------------------------------------------------
printf -- '\n-- 9. the remote programs run under the shell the BOX runs them under --\n'
# ---------------------------------------------------------------------------
# MEASURE ON THE HOST THAT RUNS IT. Every arm above drives the lib's local
# branch, /bin/sh. Over ssh the box's LOGIN shell runs the text, and on this
# estate that is zsh. Swap the transport and require the same verdict.
ZSH_BIN="$(command -v zsh || true)"
if [ -z "$ZSH_BIN" ]; then
    skip_arm "the remote programs reach the same verdict under zsh" \
        "no zsh on this runner, so the login-shell path was NOT exercised. Not a pass."
else
    BOXZ="$WORK/boxz"; make_box "$BOXZ"
    JZ="$WORK/journalz.jsonl"; : > "$JZ"
    outz="$(env -u OSTLER_WIKI_WAIT_SKIP OSTLER_BOX_HOST= PATH="$STUB_BIN:$PATH" OSTLER_DIR="$BOXZ" \
        OSTLER_USAGE_JOURNAL="$JZ" STUB_JOURNAL="$JZ" STUB_PIDS="$PIDS" \
        STUB_LAUNCHCTL_LOG="$BOXZ/launchctl.argv" \
        STUB_BACKFILL_S=3 STUB_BACKFILL_ROWS=2 STUB_TICK_DELAY_S=1 STUB_BACKFILL_GROW=1 \
        OSTLER_WIKI_WAIT_INTERVAL_S=1 OSTLER_WIKI_WAIT_BUDGET_S=25 \
        ZSH_BIN="$ZSH_BIN" \
        bash -c '
            set -uo pipefail
            . "$1"
            _ww_box_exec() { "$ZSH_BIN" -c "$1"; }
            wiki_summaries_wait
            printf "RC=%s\n" "$?"
            printf "STATE=%s\n" "${WIKI_WAIT_STATE}"
        ' _ "$LIB" 2>&1)"
    PIDZ="$(cat "$BOXZ/.wiki-recompile-summaries.pid" 2>/dev/null || printf 'unread')"
    grep -q 'STATE=converged' <<< "$outz" && grep -q 'delta  : 2 row' <<< "$outz"
    arm "the remote programs reach the same verdict under zsh as under sh" $? "$outz"
    grep -qxF "$want_argv" "$BOXZ/launchctl.argv"
    arm "and hand zsh's launchctl the same kickstart text" $? \
        "recorded argv: $(cat "$BOXZ/launchctl.argv" 2>/dev/null)"
    grep -qE "wrapper pid ${PIDZ} alive; .*matching processes: [1-9][0-9]* \[.*${PIDZ}.*\]" <<< "$outz" && grep -q 'GREW from' <<< "$outz"
    arm "and under zsh the process count and the growth reading come out the same (no word-splitting difference)" $? "pid=$PIDZ :: $outz"
fi

# ---------------------------------------------------------------------------
printf -- '\n-- 10. MUTATION: with the delta check disabled, arm 4 must fail --\n'
# ---------------------------------------------------------------------------
# THE MUTANT LIVES IN A MIRROR OF THE REAL TREE: the lib finds the probe whose
# resolver it uses at ../probes/, relative to its own BASH_SOURCE, so a mutant
# loose in $WORK would die at the journal lookup and never reach the mutated
# line. A mutation arm that dies before the mutation looks exactly like one the
# suite caught.
MIRROR="$WORK/mirror"
cp -R "$REPO/scripts/box_walk_probes" "$MIRROR"
MUT="$MIRROR/lib/wiki_summaries_wait.sh"
sed 's/^    if \[ "${WIKI_WAIT_DELTA}" -gt 0 \]; then$/    if true; then/' "$LIB" > "$MUT"
mut_left="$(grep -c -F 'WIKI_WAIT_DELTA}" -gt 0' "$MUT" || true)"
[ "$mut_left" = "0" ]
arm "the mutant really has the delta check disabled (the injection landed)" $? \
    "still present: $mut_left line(s)"

BOXM="$WORK/boxm"; make_box "$BOXM"
JM="$WORK/journalm.jsonl"; : > "$JM"
outm="$(run_wait "$MUT" "$BOXM" "$JM" STUB_BACKFILL_S=1 STUB_BACKFILL_ROWS=0 STUB_BACKFILL_LOGLINE=done)"
grep -q 'STATE=converged' <<< "$outm"
if [ $? -eq 0 ]; then mut_rc=0; else mut_rc=1; fi
arm "MUST-FAIL: the mutant reports CONVERGED on a zero delta, so arm 4 is a real assertion" "$mut_rc" \
    "the mutant did not pass a zero delta: $outm"

printf '\n== %s pass / %s fail / %s cannot-run / %s total ==\n' \
    "$PASS" "$FAIL" "$SKIP" "$((PASS + FAIL + SKIP))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
