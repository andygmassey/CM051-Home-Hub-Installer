#!/usr/bin/env bash
# scripts/box_walk_probes/lib/wiki_summaries_wait.sh
# ============================================================================
# WAIT FOR THE WIKI SUMMARY BACKFILL, so cm044_wiki_compiler has written before
# usage_journal_producers reads the journal.
#
# THE DEFECT, MEASURED ON THE v1.0.82 WALK (2026-09-09)
#
# usage_journal_producers requires five producers to have written to
# ~/.ostler/assistant-config/workspace/state/costs.jsonl. On the wiped v1.0.82
# box cm044_wiki_compiler had written 0 rows; on v1.0.81, a long-lived box, it
# had 553. Measured on the box at 18:53:06Z:
#
#   - the install-time compile tick (LaunchAgent
#     com.creativemachines.ostler.wiki-recompile, runs 1, exit 0, log
#     ~/.ostler/logs/wiki-recompile.log) ran
#         "phase 1: fast baseline, OSTLER_WIKI_SKIP_LLM=1"
#     and then
#         "wiki summary backfill launched in background (holds shared Ollama
#          slot lock; full compile, see ~/.ostler/logs/wiki-recompile-summaries.log)"
#   - the catch-up agent (com.creativemachines.ostler.wiki-recompile-catchup)
#     fired 30 minutes later and did the same;
#   - wiki-recompile-summaries.log was 0 bytes at 18:53Z, five minutes after
#     the backfill launched at 18:48:11Z;
#   - the producers probe read the journal at about 18:51Z.
#
# The compiler's model calls, which are the ONLY thing that writes a
# cm044-compile- row, happen in phase 2 of the tick: a detached background
# backfill that nothing in the walk waited for. So the first reading was "asked
# too early", the same shape converge_wait.sh closes for the two count-reading
# probes.
#
# AND THEN THE SECOND MEASUREMENT, WHICH IS WHY THIS DOES NOT WAIT ON A PID.
# Same box, 19:08:14Z and 19:08:35Z, twenty minutes after the launch:
# wiki-recompile-summaries.log STILL 0 bytes; wiki-background-compile.log 0
# bytes (18:32Z); wiki-recompile-catchup.log 2671 bytes; NO process of ours
# matching wiki or compile alive; both LaunchAgents reading "not running, runs
# 1, last exit code 0"; the journal at 290 rows with cm044-compile- 0. The
# backfill was not slow. It was not running, and it had written nothing, while
# every liveness signal read green, because the tick exits 0 for having
# LAUNCHED something. A wait armed on "the backfill pid is gone" would have
# called that complete and handed the reader a silent producer to explain.
#
# HOW THE BACKFILL IS LAUNCHED AND WHAT IT LEAVES BEHIND, read from
# wiki-recompile/bin/wiki-recompile-tick.sh (the script INSTALL_SNIPPET.sh
# stages to ~/.ostler/bin/wiki-recompile-tick.sh, install.sh:23634-23637):
#
#   :256      phase 1, the fast baseline compile, OSTLER_WIKI_SKIP_LLM=1
#   :339      "wiki baseline published and wiki-site verified up"
#   :351      the backfill log, ${OSTLER_LOGS:-$OSTLER_DIR/logs}/wiki-recompile-summaries.log
#   :356      the backfill pidfile, ${OSTLER_DIR}/.wiki-recompile-summaries.pid
#   :358-363  the no-stack guard: the recorded pid is tested with kill -0, and
#             a live one means "already running (pid N); not launching another"
#   :392      the shared Ollama slot lock,
#             ${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}
#             taken by lib/ostler-ingest-slot.sh: mkdir, then pid, holder,
#             acquired_at and max_hold files inside it
#   :394-447  the wrapper: nohup bash -c, BLOCKING acquire of that slot
#             (:416-418, sleeping 10 s between attempts), then
#             `docker compose --profile compile run --rm -T wiki-compiler`
#             under it. :447 redirects BOTH streams into the summaries log:
#             the backfill has no separate stderr file
#   :448-449  the wrapper's pid is written to the pidfile
#   :450      disown
#   :451      "wiki summary backfill launched in background (...)"
#   :454      "wiki recompile tick complete (baseline published; summaries backfilling)"
#
# THERE IS NO HOST-SIDE COMPLETION MARKER, and the pid is not enough. The
# pidfile is never removed; the summaries log is the container's own output and
# ends in no sentinel; the compiler's .compile-complete marker lives in the
# wiki_docs volume inside the container runtime. And a dead wrapper with an
# empty log is exactly what the 19:08Z measurement found. So each reading takes,
# together: whether the wrapper pid is alive; the summaries log's size and line
# count, so GROWTH is seen rather than inferred; the slot lock and who holds it;
# every process of THIS ACCOUNT whose command line names the compiler or the
# tick; and, once the wrapper is gone, whether a wiki-compiler container is
# still running, because a killed docker client does not stop its container.
# The wait ends when nothing of ours is alive any more, or at the budget.
#
# AN EMPTY LOG IS NEVER "COMPLETE". While the wrapper waits on the slot lock it
# prints nothing, so the log is 0 bytes for as long as another feed holds the
# slot. The log's size is printed on every reading because it says whether the
# compile has started writing; it never says the compile is over. Its CONTENT
# is never printed: the compiler names the people it summarises.
#
# WHAT THIS STEP DOES, IN ORDER
#
#   1. reads the box BEFORE acting: the tick log's line count and last line,
#      the summaries log's size, the pidfile and whether its pid is alive, the
#      slot lock, and the journal's cm044-compile- row count;
#   2. `launchctl kickstart -k gui/<uid>/com.creativemachines.ostler.wiki-recompile`
#      on the box, so the compile includes the person, preferences and
#      conversation the seeds above just wrote. If the label is absent or the
#      kickstart is refused, it says which and runs the installed tick script
#      directly, detached, appending to the same log; if that is absent too,
#      CANNOT-RUN. The kickstart may reproduce the 19:08Z shape or not; this
#      step makes the difference visible and assumes neither;
#   3. waits, bounded by OSTLER_WIKI_WAIT_BUDGET_S, first for the tick to hand
#      over a backfill pid (its "launched" line and the pidfile, or its "already
#      running (pid N)" line), then for every sign of life to end;
#   4. counts the journal's cm044-compile- rows again;
#   5. prints the diagnostic a person would need: the tick log's last three of
#      its own lines, the tick's stderr file, the summaries log's size, line
#      count and age, the pidfile, the slot lock's holder and age, the matching
#      processes, and the compile container.
#
# OUTCOMES, EACH A NAMED LINE, EACH WITH THE ELAPSED TIME
#
#   CONVERGED    nothing of ours is alive any more and the delta is > 0. Return 0.
#   FINDING      THE BACKFILL WROTE NOTHING: the summaries log is 0 bytes for
#                the whole of the wait, whether the wrapper exited (the 19:08Z
#                shape) or is still alive and blocked before its first line.
#                Names the log path and the elapsed time. Return 1.
#   FINDING      THE COMPILE RAN AND cm044_wiki_compiler DID NOT WRITE: the
#                log grew, everything of ours has exited, and the delta is 0.
#                cm044_wiki_compiler is named as a PRESENT producer that did
#                not write. Return 1.
#   CANNOT-RUN   NOT CONVERGED IN TIME: the log grew (or already had content)
#                and something of ours is still alive at the budget. Also: the
#                box could not be read; the label is absent AND no tick script
#                is installed; the tick ended without launching a backfill (its
#                own line quoted); OSTLER_WIKI_WAIT_SKIP=1. Return 1.
#
# A CANNOT-RUN is a coverage statement and never a product verdict. The two
# FINDINGs are about the product, and each is reachable only on evidence: an
# empty log with nothing alive, or a finished compile with no row.
#
# NO FORGET. The compile is the product's own, over the box's own graph, and the
# rows it writes are real measurements of real model calls. There is nothing
# synthetic to take back.
#
# ENV
#   OSTLER_WIKI_WAIT_BUDGET_S     total wait, default 900
#   OSTLER_WIKI_WAIT_INTERVAL_S   seconds between readings, default 20
#   OSTLER_WIKI_WAIT_SKIP=1       do nothing; prints a named CANNOT-RUN
#   OSTLER_USAGE_JOURNAL          honoured, because the journal path is resolved
#                                 by the PROBE (--print-journal-path), never by
#                                 a second copy of its resolver
#   OSTLER_BOX_HOST               unset means this machine, per the suite contract
#
# BASH 3.2 (macOS system bash). No associative arrays, no mapfile. Every remote
# program is POSIX sh: it is run by /bin/sh here and by the box's login shell
# over ssh, and neither is guaranteed to be bash. Paths that carry $HOME are
# expanded ON THE BOX, inside double quotes there; nothing here interpolates a
# parent-side value that still carries a literal $HOME into single quotes,
# which is the converge_wait defect measured on the v1.0.79 walk.
# ============================================================================

WIKI_WAIT_STATE="unrun"   # unrun|skipped|cannot-run|finding|converged
WIKI_WAIT_DETAIL=""
WIKI_WAIT_BEFORE=""
WIKI_WAIT_AFTER=""
WIKI_WAIT_DELTA=""
WIKI_WAIT_JOURNAL=""
WIKI_WAIT_ELAPSED=""
WIKI_WAIT_BACKFILL_PID=""

# The producer's session_id prefix, from scripts/usage_journal_producers.tsv
# (row cm044_wiki_compiler, match_value cm044-compile-). A literal here rather
# than a parse of the roster, for the reason usage_seed.sh gives: a roster edit
# and this step must not be able to agree with each other about a prefix the
# producer does not use.
_WW_SESSION_PREFIX="cm044-compile-"
_WW_LABEL="com.creativemachines.ostler.wiki-recompile"

# The ssh invocation the probes and the seeds use. Identical on purpose: a wait
# that watched a different box than the probes measure would be worse than none.
_ww_box_exec() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

_ww_now() { date +%s; }

# ---------------------------------------------------------------------------
# THE JOURNAL PATH IS RESOLVED BY THE PROBE, NOT BY A SECOND RESOLVER. Same
# route as lib/usage_seed.sh: probes/usage_journal_producers.sh exposes
# --print-journal-path so that a seed or a wait can count rows in the file the
# probe will actually read, and not in a file that merely shares its name.
# ---------------------------------------------------------------------------
_ww_resolve_journal() {
    _ww_probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/probes/usage_journal_producers.sh"
    [ -f "${_ww_probe}" ] || return 2
    bash "${_ww_probe}" --print-journal-path
}

# ---------------------------------------------------------------------------
# COUNT THE PRODUCER'S OWN ROWS, ON THE BOX. Prints "<rows> <unparseable>", and
# "-1 0" when the file does not exist: an absent journal and an empty one are
# different facts. Counted by JSON parse, not by grep, because json.dumps
# separator spacing is pinned by nothing. No `grep -c` anywhere, for the reason
# usage_seed.sh:205-207 gives.
#
# The path is placed inside DOUBLE quotes on the box, so a value that still
# carries $HOME (OSTLER_USAGE_JOURNAL may) expands there and not here.
# ---------------------------------------------------------------------------
_ww_count_rows() {
    _ww_box_exec 'p="'"${1}"'"
python3 -c "
import json, sys
try:
    fh = open(sys.argv[1])
except Exception:
    print(-1, 0)
    sys.exit(0)
n = 0
bad = 0
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        bad += 1
        continue
    if not isinstance(rec, dict):
        bad += 1
        continue
    sid = rec.get(sys.argv[2])
    if isinstance(sid, str) and sid.startswith(sys.argv[3]):
        n += 1
print(n, bad)
" "$p" session_id '"${_WW_SESSION_PREFIX}"'
'
}

# ---------------------------------------------------------------------------
# ONE READING OF THE BOX, BEFORE ACTING. Every path is derived on the box from
# the same defaults the tick uses (wiki-recompile-tick.sh:54, :351, :356,
# :392), so a box with OSTLER_DIR or OSTLER_LOGS set in its login environment
# is read where the tick writes. printf throughout: dash's echo interprets
# backslashes, and a log line is arbitrary text.
#
# Lines printed:
#   TICKLOG  <lines|absent> <path>
#   TICKLAST <last line of the tick log, or empty>
#   SUMLOG   <bytes|absent> <path>
#   PIDFILE  <pid|none|unparseable> <alive|dead|none>
#   SLOT     <held|free> <path>
#   TICKBIN  <present|absent> <path>
# ---------------------------------------------------------------------------
_ww_read_state() {
    _ww_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
T="$L/wiki-recompile.log"
S="$L/wiki-recompile-summaries.log"
P="$O/.wiki-recompile-summaries.pid"
K="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
B="$O/bin/wiki-recompile-tick.sh"
if [ -f "$T" ]; then
    printf "TICKLOG %s %s\n" "$(wc -l < "$T" | tr -d " ")" "$T"
    printf "TICKLAST %s\n" "$(tail -n 1 "$T")"
else
    printf "TICKLOG absent %s\n" "$T"
    printf "TICKLAST\n"
fi
if [ -f "$S" ]; then
    printf "SUMLOG %s %s\n" "$(wc -c < "$S" | tr -d " ")" "$S"
else
    printf "SUMLOG absent %s\n" "$S"
fi
if [ -f "$P" ]; then
    pid="$(tr -d "[:space:]" < "$P")"
    case "$pid" in
        ""|*[!0-9]*) printf "PIDFILE unparseable none\n" ;;
        *) if kill -0 "$pid" 2>/dev/null; then printf "PIDFILE %s alive\n" "$pid"; else printf "PIDFILE %s dead\n" "$pid"; fi ;;
    esac
else
    printf "PIDFILE none none\n"
fi
if [ -d "$K" ]; then printf "SLOT held %s\n" "$K"; else printf "SLOT free %s\n" "$K"; fi
if [ -x "$B" ]; then printf "TICKBIN present %s\n" "$B"; else printf "TICKBIN absent %s\n" "$B"; fi
exit 0
'
}

# Pull one field out of a reading. $1 = the reading, $2 = the key.
_ww_field() {
    printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# ---------------------------------------------------------------------------
# THE KICKSTART. `launchctl kickstart -k` on the LaunchAgent the installer
# loaded (INSTALL_SNIPPET.sh:87-92 bootstraps it into gui/$(id -u)), so the
# tick runs NOW rather than at its daily StartInterval, and -k so an instance
# still in its baseline phase is restarted rather than left to finish a compile
# that predates the seeds. When launchctl is missing, the label is not loaded,
# or the kickstart is refused, the installed tick script is run directly and
# detached, appending to the same log the LaunchAgent writes, so the same poll
# reads either. Every branch prints which one it took.
#
# Lines printed:
#   LAUNCHCTL <path|absent>
#   LABEL     <present|absent|unknown> <service>
#   KICKSTART <ok|refused rc=N <launchctl's own words>|unusable ...>
#   FALLBACK  <unused|started pid N <path>|absent <path>>
# ---------------------------------------------------------------------------
_ww_kickstart() {
    _ww_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
B="$O/bin/wiki-recompile-tick.sh"
svc="gui/$(id -u)/'"${_WW_LABEL}"'"
started=0
lc="$(command -v launchctl 2>/dev/null)"
if [ -z "$lc" ]; then
    printf "LAUNCHCTL absent\n"
    printf "LABEL unknown %s\n" "$svc"
    printf "KICKSTART unusable (no launchctl on this box)\n"
else
    printf "LAUNCHCTL %s\n" "$lc"
    if launchctl print "$svc" >/dev/null 2>&1; then
        printf "LABEL present %s\n" "$svc"
        err="$(launchctl kickstart -k "$svc" 2>&1)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            printf "KICKSTART ok %s\n" "$svc"
            started=1
        else
            printf "KICKSTART refused rc=%s %s\n" "$rc" "$(printf "%s" "$err" | tr "\n" " ")"
        fi
    else
        printf "LABEL absent %s\n" "$svc"
        printf "KICKSTART unusable (label not loaded in the gui domain)\n"
    fi
fi
if [ "$started" -eq 1 ]; then
    printf "FALLBACK unused\n"
elif [ -x "$B" ]; then
    mkdir -p "$L" 2>/dev/null
    nohup /bin/bash "$B" >>"$L/wiki-recompile.log" 2>>"$L/wiki-recompile.err" </dev/null &
    printf "FALLBACK started pid %s %s\n" "$!" "$B"
else
    printf "FALLBACK absent %s\n" "$B"
fi
exit 0
'
}

# ---------------------------------------------------------------------------
# ONE POLL OF THE TICK. $1 = the tick log's line count before the kickstart.
# Prints the tick's NEW lines that decide anything, prefixed TICK, plus the
# pidfile and the summaries log size. The tick's own words are matched, from
# wiki-recompile-tick.sh: :365 already running, :451 launched, :454 complete,
# :231 another tick holds the mutex, and the ERROR / not ready / paused lines
# that end a tick without a backfill.
# ---------------------------------------------------------------------------
_ww_poll_tick() {
    _ww_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
T="$L/wiki-recompile.log"
S="$L/wiki-recompile-summaries.log"
P="$O/.wiki-recompile-summaries.pid"
n="'"${1}"'"
if [ -f "$T" ]; then
    now="$(wc -l < "$T" | tr -d " ")"
    printf "TICKLINES %s\n" "$now"
    if [ "$now" -gt "$n" ]; then
        tail -n +$((n + 1)) "$T" | grep -E "backfill launched|backfill already running|already running; skipping|ERROR|not ready after|paused by the operator|tick complete" | sed "s/^/TICK /"
    fi
else
    printf "TICKLINES absent\n"
fi
if [ -f "$P" ]; then
    pid="$(tr -d "[:space:]" < "$P")"
    case "$pid" in
        ""|*[!0-9]*) printf "PIDFILE unparseable none\n" ;;
        *) if kill -0 "$pid" 2>/dev/null; then printf "PIDFILE %s alive\n" "$pid"; else printf "PIDFILE %s dead\n" "$pid"; fi ;;
    esac
else
    printf "PIDFILE none none\n"
fi
if [ -f "$S" ]; then
    printf "SUMLOG %s %s\n" "$(wc -c < "$S" | tr -d " ")" "$S"
else
    printf "SUMLOG absent %s\n" "$S"
fi
exit 0
'
}

# ---------------------------------------------------------------------------
# ONE POLL OF THE BACKFILL. $1 = the wrapper pid from the pidfile (or "none"),
# $2 = "full" to add the container check.
#
# NOT THE PID ALONE, for the 19:08Z reason in the header. Every reading takes
# the wrapper pid, the summaries log's size and line count and age, the slot
# lock and its holder (pid, holder and acquired_at files, per
# lib/ostler-ingest-slot.sh; the directory mtime when acquired_at is absent:
# GNU stat -c first, because GNU stat -f is filesystem status and answers a
# mount point for %m without failing, then BSD stat -f),
# and the processes of THIS ACCOUNT whose command line names the compiler or
# the tick. pgrep -U, never a bare -f: on the v1.0.67 walk a bare pgrep -f
# selected another account's process. The bracket in the pattern keeps this
# very program, whose text contains the words, from matching itself, AND SO
# MUST EVERY OTHER LITERAL IN THIS PROGRAM: the docker filter below is
# assembled from two halves for that reason. Measured on the first CI run of
# this lib (ubuntu, PR #1890): a literal "name=wiki-compiler" in the filter
# made the reading program match its own /bin/sh -c and the $(...) subshell,
# two fresh pids on every reading, so "something of ours is alive" never went
# false and every completion arm ended NOT CONVERGED IN TIME. macOS pgrep did
# not surface it; Linux does. The suite now has a control for it. The
# container check runs only when asked: docker ps costs seconds when the
# daemon is down, and it only matters once the wrapper is gone.
#
# Lines printed:
#   PID       <pid> <alive|dead>  (or "none none")
#   SUMLOG    <bytes|absent> <path>
#   SUMLINES  <n>
#   SUMAGE    <seconds since last write|->
#   SLOT      <held|free> <path>
#   SLOTINFO  holder=<feed> pid=<pid> <alive|dead|unknown> acquired=<seconds ago>s   (when held)
#   PROCS     <count> <pids>
#   CONTAINER <none|running <name> <status>|unknown <why>>   (when $2 = full)
# ---------------------------------------------------------------------------
_ww_poll_backfill() {
    _ww_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
S="$L/wiki-recompile-summaries.log"
K="${OSTLER_INGEST_LOCK:-${OSTLER_STATE_DIR:-$HOME/.ostler/workspace}/ingest-ollama.lock.d}"
pid="'"${1}"'"
full="'"${2:-}"'"
now="$(date +%s)"
case "$pid" in
    ""|*[!0-9]*) printf "PID none none\n" ;;
    *) if kill -0 "$pid" 2>/dev/null; then printf "PID %s alive\n" "$pid"; else printf "PID %s dead\n" "$pid"; fi ;;
esac
if [ -f "$S" ]; then
    printf "SUMLOG %s %s\n" "$(wc -c < "$S" | tr -d " ")" "$S"
    printf "SUMLINES %s\n" "$(wc -l < "$S" | tr -d " ")"
    m="$(stat -c %Y "$S" 2>/dev/null || stat -f %m "$S" 2>/dev/null || true)"
    case "$m" in ""|*[!0-9]*) printf "SUMAGE -\n" ;; *) printf "SUMAGE %s\n" "$((now - m))" ;; esac
else
    printf "SUMLOG absent %s\n" "$S"
    printf "SUMLINES 0\n"
    printf "SUMAGE -\n"
fi
if [ -d "$K" ]; then
    printf "SLOT held %s\n" "$K"
    hp="$(tr -d "[:space:]" < "$K/pid" 2>/dev/null)"
    hn="$(tr -d "[:space:]" < "$K/holder" 2>/dev/null)"
    ha="$(tr -d "[:space:]" < "$K/acquired_at" 2>/dev/null)"
    case "$ha" in ""|*[!0-9]*) ha="$(stat -c %Y "$K" 2>/dev/null || stat -f %m "$K" 2>/dev/null || true)" ;; esac
    case "$ha" in ""|*[!0-9]*) age="-" ;; *) age="$((now - ha))" ;; esac
    case "$hp" in
        ""|*[!0-9]*) hs="unknown" ;;
        *) if kill -0 "$hp" 2>/dev/null; then hs="alive"; else hs="dead"; fi ;;
    esac
    printf "SLOTINFO holder=%s pid=%s %s acquired=%ss\n" "${hn:-?}" "${hp:-?}" "$hs" "$age"
else
    printf "SLOT free %s\n" "$K"
fi
procs="$(pgrep -U "$(id -u)" -f "wiki-compile[r]|wiki-recompile-tic[k]" 2>/dev/null | tr "\n" " ")"
n="$(printf "%s" "$procs" | wc -w | tr -d " ")"
printf "PROCS %s %s\n" "$n" "$procs"
if [ "$full" = "full" ]; then
    PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
    if command -v docker >/dev/null 2>&1; then
        nm="wiki-compile"; nm="${nm}r"
        c="$(docker ps --filter "name=$nm" --format "{{.Names}} {{.Status}}" 2>&1)"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf "CONTAINER unknown docker ps exit %s: %s\n" "$rc" "$(printf "%s" "$c" | head -1)"
        elif [ -z "$c" ]; then
            printf "CONTAINER none\n"
        else
            printf "CONTAINER running %s\n" "$(printf "%s" "$c" | head -1)"
        fi
    else
        printf "CONTAINER unknown no docker on PATH\n"
    fi
fi
exit 0
'
}

# ---------------------------------------------------------------------------
# THE DIAGNOSTIC A PERSON WOULD NEED, read at the end. The tick log's last
# three of ITS OWN lines: the tick tails the baseline compile's output into the
# same log (:295) and that output can name people, so only lines in the tick's
# log() format (:57, "[YYYY-MM-DD HH:MM:SS] ") are taken. The tick's stderr file
# is launchd's StandardErrorPath (the plist) and the fallback's 2>> target; the
# backfill has none of its own (:447).
#
# Lines printed:
#   TICKTAIL <up to three lines joined by |, or absent>
#   ERRFILE  <bytes> bytes <path>  (or absent <path>)
#   ERRTAIL  <up to three lines joined by |>
# ---------------------------------------------------------------------------
_ww_diag() {
    _ww_box_exec '
O="${OSTLER_DIR:-$HOME/.ostler}"
L="${OSTLER_LOGS:-$O/logs}"
T="$L/wiki-recompile.log"
E="$L/wiki-recompile.err"
if [ -f "$T" ]; then
    printf "TICKTAIL %s\n" "$(grep -E "^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] " "$T" | tail -n 3 | tr "\n" "|")"
else
    printf "TICKTAIL absent\n"
fi
if [ -f "$E" ]; then
    printf "ERRFILE %s bytes %s\n" "$(wc -c < "$E" | tr -d " ")" "$E"
    printf "ERRTAIL %s\n" "$(tail -n 3 "$E" | tr "\n" "|")"
else
    printf "ERRFILE absent %s\n" "$E"
    printf "ERRTAIL\n"
fi
exit 0
'
}

# A one-line description of the summaries log, for the reading lines. Size,
# line count and age only; never its content.
_ww_sum_desc() { # $1 = a backfill reading
    _ww_sz="$(_ww_field "$1" SUMLOG | cut -d' ' -f1)"
    _ww_ln="$(_ww_field "$1" SUMLINES)"
    _ww_ag="$(_ww_field "$1" SUMAGE)"
    case "${_ww_sz}" in
        absent) printf 'summaries log absent' ;;
        '')     printf 'summaries log unread' ;;
        0)      printf 'summaries log 0 bytes' ;;
        *)      printf 'summaries log %s bytes, %s line(s), last written %ss ago' "${_ww_sz}" "${_ww_ln:-?}" "${_ww_ag:-?}" ;;
    esac
}

# Print the diagnostic block. $1 = the last backfill reading (with CONTAINER
# when one was taken).
_ww_print_diag() {
    local d
    d="$(_ww_diag 2>&1)"
    local tt et
    tt="$(_ww_field "$d" TICKTAIL)"
    et="$(_ww_field "$d" ERRTAIL)"
    printf '  --- diagnostic, for whoever reads this record ---\n'
    printf '  tick log, its own lines, last 3:\n'
    if [ -z "$tt" ] || [ "$tt" = "absent" ]; then
        printf '      (%s)\n' "${tt:-none}"
    else
        printf '%s\n' "$tt" | tr '|' '\n' | grep -v '^$' | sed 's/^/      /'
    fi
    printf '  tick stderr : %s\n' "$(_ww_field "$d" ERRFILE)"
    if [ -n "$et" ]; then
        printf '%s\n' "$et" | tr '|' '\n' | grep -v '^$' | sed 's/^/      /'
    fi
    printf '  summaries   : %s (%s)\n' "$(_ww_sum_desc "$1")" "$(_ww_field "$1" SUMLOG | cut -d' ' -f2-)"
    printf '                the backfill has no separate stderr: wiki-recompile-tick.sh:447 sends both\n'
    printf '                streams here. Its content is never printed; it names people.\n'
    printf '  pidfile     : wrapper pid %s\n' "$(_ww_field "$1" PID)"
    local si
    si="$(_ww_field "$1" SLOTINFO)"
    printf '  slot lock   : %s%s\n' "$(_ww_field "$1" SLOT)" "${si:+; $si}"
    printf '  processes   : %s matching wiki-compiler|wiki-recompile-tick under this account (pids: %s)\n' \
        "$(_ww_field "$1" PROCS | cut -d' ' -f1)" "$(_ww_field "$1" PROCS | cut -d' ' -f2- | sed 's/ *$//')"
    printf '  container   : %s\n' "$(_ww_field "$1" CONTAINER)"
}

# ---------------------------------------------------------------------------
# THE STEP. Sourced and called by run_box_walk.sh after the four seeds and
# before phase 2, so the compile it triggers sees the seeded person,
# preferences and conversation, and finishes before the journal is read.
#
# Returns 0 only on CONVERGED. Returns 1 otherwise, and EVERY return-1 path
# prints a line beginning CANNOT-RUN or FINDING.
# ---------------------------------------------------------------------------
wiki_summaries_wait() {
    local budget="${OSTLER_WIKI_WAIT_BUDGET_S:-900}"
    local gap="${OSTLER_WIKI_WAIT_INTERVAL_S:-20}"
    local step="$gap"
    [ "$step" -lt 1 ] && step=1
    local start waited=0 iter=0 elapsed=0
    start="$(_ww_now)"

    printf -- '--- WIKI SUMMARIES: kickstart the recompile and wait for its backfill, before the journal is read ---\n'
    printf '  cm044_wiki_compiler writes a cm044-compile- row only from the summary pass, which\n'
    printf '  the tick runs as a DETACHED backfill (wiki-recompile-tick.sh:394-451). On the wiped\n'
    printf '  v1.0.82 box that backfill had launched 3 minutes before the probe read the journal,\n'
    printf '  and twenty minutes later it was gone with a 0-byte log and every signal green.\n'
    printf '  budget: %ss (OSTLER_WIKI_WAIT_BUDGET_S), reading every %ss\n' "$budget" "$gap"

    if [ "${OSTLER_WIKI_WAIT_SKIP:-0}" = "1" ]; then
        WIKI_WAIT_STATE="skipped"
        WIKI_WAIT_ELAPSED=0
        WIKI_WAIT_DETAIL="skipped by OSTLER_WIKI_WAIT_SKIP=1; no recompile was triggered and no journal row was measured"
        printf '  CANNOT-RUN: skipped by OSTLER_WIKI_WAIT_SKIP=1 after 0s. No recompile was triggered\n'
        printf '  and no cm044-compile- row was measured. That is not a pass.\n\n'
        return 1
    fi

    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        printf '  target: this machine (OSTLER_BOX_HOST unset)\n'
    else
        printf '  target: %s\n' "${OSTLER_BOX_HOST}"
    fi

    # -- 1. the box, before acting -------------------------------------------
    local st0 rc0
    st0="$(_ww_read_state 2>&1)"
    rc0=$?
    if [ "$rc0" -ne 0 ] || [ -z "$(_ww_field "$st0" TICKLOG)" ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
        WIKI_WAIT_DETAIL="the box could not be read before acting (transport exit ${rc0}); nothing was kickstarted"
        printf '  CANNOT-RUN: the box could not be read before acting (transport exit %s) after %ss.\n' "$rc0" "$WIKI_WAIT_ELAPSED"
        printf '  Nothing was kickstarted and nothing was measured.\n'
        printf '%s\n' "$st0" | sed 's/^/    /'
        printf '\n'
        return 1
    fi
    local tick0 tick_last0 pid0 pid0_state sum0
    tick0="$(_ww_field "$st0" TICKLOG | cut -d' ' -f1)"
    tick_last0="$(_ww_field "$st0" TICKLAST)"
    pid0="$(_ww_field "$st0" PIDFILE | cut -d' ' -f1)"
    pid0_state="$(_ww_field "$st0" PIDFILE | cut -d' ' -f2)"
    sum0="$(_ww_field "$st0" SUMLOG | cut -d' ' -f1)"
    printf '  tick log       : %s\n' "$(_ww_field "$st0" TICKLOG)"
    printf '  tick last line : %s\n' "${tick_last0:-<empty>}"
    printf '  summaries log  : %s\n' "$(_ww_field "$st0" SUMLOG)"
    printf '  backfill pid   : %s %s (pidfile written by wiki-recompile-tick.sh:449)\n' "$pid0" "$pid0_state"
    printf '  slot lock      : %s\n' "$(_ww_field "$st0" SLOT)"
    printf '  tick script    : %s\n' "$(_ww_field "$st0" TICKBIN)"
    case "$tick0" in absent|''|*[!0-9]*) tick0=0 ;; esac
    case "$sum0" in absent|''|*[!0-9]*) sum0=0 ;; esac

    # -- 2. the journal, before -----------------------------------------------
    WIKI_WAIT_JOURNAL="$(_ww_resolve_journal)"
    local jrc=$?
    if [ "$jrc" -eq 2 ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
        WIKI_WAIT_DETAIL="probes/usage_journal_producers.sh is not beside this lib, so there is no journal resolver to ask (a checkout problem, not a box problem)"
        printf '  CANNOT-RUN: probes/usage_journal_producers.sh is not beside this lib, so there is\n'
        printf '  no resolver to ask. That is a checkout problem, not a box problem. Nothing was\n'
        printf '  kickstarted (%ss).\n\n' "$WIKI_WAIT_ELAPSED"
        return 1
    fi
    if [ -z "${WIKI_WAIT_JOURNAL}" ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
        WIKI_WAIT_DETAIL="the probe's own resolver returned no journal path"
        printf '  CANNOT-RUN: the probe own resolver returned no journal path, so no file was even\n'
        printf '  named. Nothing was kickstarted (%ss).\n\n' "$WIKI_WAIT_ELAPSED"
        return 1
    fi
    printf '  journal on box : %s\n' "${WIKI_WAIT_JOURNAL}"

    local before_raw brc before_n
    before_raw="$(_ww_count_rows "${WIKI_WAIT_JOURNAL}")"
    brc=$?
    if [ "$brc" -ne 0 ] || [ -z "$before_raw" ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
        WIKI_WAIT_DETAIL="could not count the journal BEFORE the kickstart (exit ${brc}); a delta needs both ends"
        printf '  CANNOT-RUN: could not count the journal BEFORE the kickstart (exit %s). A delta\n' "$brc"
        printf '  needs both ends. Nothing was kickstarted (%ss).\n' "$WIKI_WAIT_ELAPSED"
        printf '%s\n' "$before_raw" | sed 's/^/    /'
        printf '\n'
        return 1
    fi
    WIKI_WAIT_BEFORE="${before_raw%% *}"
    case "${WIKI_WAIT_BEFORE}" in
        -1) printf '  before : the journal does not exist yet on the box\n'; before_n=0 ;;
        ''|*[!0-9]*)
            WIKI_WAIT_STATE="cannot-run"
            WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
            WIKI_WAIT_DETAIL="the BEFORE count came back as [${WIKI_WAIT_BEFORE}], which is not a number"
            printf '  CANNOT-RUN: the BEFORE count came back as [%s], which is not a number. Nothing\n' "${WIKI_WAIT_BEFORE}"
            printf '  was kickstarted (%ss).\n\n' "$WIKI_WAIT_ELAPSED"
            return 1
            ;;
        *) printf '  before : %s row(s) with session_id starting %s (%s unparseable line(s))\n' \
               "${WIKI_WAIT_BEFORE}" "${_WW_SESSION_PREFIX}" "${before_raw##* }"
           before_n="${WIKI_WAIT_BEFORE}" ;;
    esac

    # -- 3. the kickstart -----------------------------------------------------
    local ks krc
    ks="$(_ww_kickstart 2>&1)"
    krc=$?
    printf '%s\n' "$ks" | sed 's/^/    /'
    if [ "$krc" -ne 0 ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
        WIKI_WAIT_DETAIL="the kickstart program could not be run on the box (transport exit ${krc})"
        printf '  CANNOT-RUN: the kickstart program could not be run on the box (transport exit\n'
        printf '  %s) after %ss. Nothing was measured.\n\n' "$krc" "$WIKI_WAIT_ELAPSED"
        return 1
    fi
    local how
    case "$ks" in
        *"KICKSTART ok"*)
            how="launchctl kickstart -k of ${_WW_LABEL}" ;;
        *"FALLBACK started"*)
            how="the installed tick run directly ($(_ww_field "$ks" KICKSTART))"
            printf '  kickstart was not usable (%s); the installed tick script was run directly instead\n' "$(_ww_field "$ks" KICKSTART)"
            case "$ks" in *"LABEL absent"*)
                printf '  NOTE: the LaunchAgent label %s is NOT loaded on this box. The compile below is\n' "${_WW_LABEL}"
                printf '  by hand; the daily recompile the installer promises is not scheduled here.\n'
            esac ;;
        *)
            WIKI_WAIT_STATE="cannot-run"
            WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
            WIKI_WAIT_DETAIL="the recompile could not be started: $(_ww_field "$ks" LABEL); $(_ww_field "$ks" KICKSTART); fallback $(_ww_field "$ks" FALLBACK)"
            printf '  CANNOT-RUN: the recompile could not be started after %ss. %s; %s; and the\n' \
                "$WIKI_WAIT_ELAPSED" "$(_ww_field "$ks" LABEL)" "$(_ww_field "$ks" KICKSTART)"
            printf '  installed tick script to fall back on is %s. Nothing was measured\n' "$(_ww_field "$ks" FALLBACK)"
            printf '  about the producer.\n\n'
            return 1
            ;;
    esac
    printf '  started via    : %s\n' "$how"

    # -- 4a. wait for the tick to hand over a backfill pid ---------------------
    local pid="" reading prc last_tick="" said_mutex=0 tick_lines launched_new=1
    while :; do
        elapsed=$(( $(_ww_now) - start ))
        waited=$(( iter * step ))
        [ "$elapsed" -gt "$waited" ] && waited="$elapsed"
        if [ "$waited" -ge "$budget" ]; then break; fi

        reading="$(_ww_poll_tick "$tick0" 2>&1)"
        prc=$?
        if [ "$prc" -ne 0 ]; then
            printf '  [%4ss] tick log unreadable (transport exit %s): %s\n' "$waited" "$prc" "$(printf '%s' "$reading" | head -1)"
            sleep "$gap"; iter=$((iter + 1)); continue
        fi
        tick_lines="$(printf '%s\n' "$reading" | sed -n 's/^TICK //p')"
        [ -n "$tick_lines" ] && last_tick="$(printf '%s\n' "$tick_lines" | tail -1)"

        # The tick ended without a backfill. Its own line is the reason.
        case "$tick_lines" in
            *ERROR*|*"not ready after"*|*"paused by the operator"*)
                WIKI_WAIT_STATE="cannot-run"
                WIKI_WAIT_ELAPSED="$waited"
                WIKI_WAIT_DETAIL="the recompile tick ended without launching a summary backfill after ${waited}s; its own line: $(printf '%s\n' "$tick_lines" | grep -E 'ERROR|not ready after|paused by the operator' | head -1)"
                printf '  [%4ss] the tick ended without launching a backfill:\n' "$waited"
                printf '%s\n' "$tick_lines" | sed 's/^/           /'
                printf '  CANNOT-RUN: the recompile tick ended without launching a summary backfill after\n'
                printf '  %ss, so the compiler never reached its summary pass. The line above is the\n' "$waited"
                printf '  tick own reason. Nothing is measured about the producer; a box whose baseline\n'
                printf '  compile fails has more wrong with it than the usage journal.\n'
                _ww_print_diag "$(_ww_poll_backfill none full 2>&1)"
                printf '\n'
                return 1
                ;;
        esac

        # A backfill that predates this tick is the one to wait on (:365).
        case "$tick_lines" in
            *"backfill already running (pid "*)
                pid="$(printf '%s\n' "$tick_lines" | sed -n 's/.*backfill already running (pid \([0-9][0-9]*\)).*/\1/p' | head -1)"
                if [ -n "$pid" ]; then
                    launched_new=0
                    printf '  [%4ss] the tick found a backfill already running (pid %s) and did not launch\n' "$waited" "$pid"
                    printf '           another; waiting on that one. It may predate the seeds.\n'
                    break
                fi
                ;;
        esac

        # The tick launched one (:451) and the pidfile names it (:449).
        local pf pf_pid pf_state
        pf="$(_ww_field "$reading" PIDFILE)"
        pf_pid="${pf%% *}"; pf_state="${pf##* }"
        case "$tick_lines" in
            *"backfill launched in background"*)
                case "$pf_pid" in
                    ''|none|unparseable|*[!0-9]*) : ;;
                    *) pid="$pf_pid"
                       printf '  [%4ss] the tick launched the backfill; pidfile names pid %s (%s)\n' "$waited" "$pid" "$pf_state"
                       break ;;
                esac
                ;;
        esac
        # Or another tick (the catch-up agent runs the same script under its
        # own label, :231) launched it while ours yielded the mutex: the
        # pidfile changed hands. A pid that differs from the one seen before
        # the kickstart is a new backfill whichever tick started it.
        case "$pf_pid" in
            ''|none|unparseable|*[!0-9]*) : ;;
            *)
                if [ "$pf_pid" != "$pid0" ]; then
                    pid="$pf_pid"
                    printf '  [%4ss] pidfile now names pid %s (%s), which it did not before the kickstart\n' "$waited" "$pid" "$pf_state"
                    break
                fi
                ;;
        esac
        case "$tick_lines" in
            *"already running; skipping this tick"*)
                if [ "$said_mutex" -eq 0 ]; then
                    printf '  [%4ss] another tick holds the recompile mutex (wiki-recompile-tick.sh:231); waiting\n' "$waited"
                    printf '           for the pidfile to change hands\n'
                    said_mutex=1
                fi
                ;;
        esac
        printf '  [%4ss] tick: %s; summaries log %s bytes\n' "$waited" "${last_tick:-no new line yet (baseline compile in progress)}" "$(_ww_field "$reading" SUMLOG | cut -d' ' -f1)"
        sleep "$gap"; iter=$((iter + 1))
    done

    if [ -z "$pid" ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_ELAPSED="$waited"
        WIKI_WAIT_DETAIL="the budget of ${budget}s ran out before the recompile tick handed over a backfill pid; last tick line: ${last_tick:-none since the kickstart}"
        printf '  CANNOT-RUN: the budget of %ss ran out after %ss before the tick handed over a\n' "$budget" "$waited"
        printf '  backfill pid. Last tick line since the kickstart: %s.\n' "${last_tick:-none (the baseline compile had not finished)}"
        printf '  The summary pass was never reached inside the budget, so nothing is measured\n'
        printf '  about the producer. Not a FAIL: the compile was still running.\n'
        _ww_print_diag "$(_ww_poll_backfill none full 2>&1)"
        printf '\n'
        return 1
    fi
    WIKI_WAIT_BACKFILL_PID="$pid"

    # -- 4b. wait for the backfill: LIVENESS AND GROWTH, never the pid alone ----
    #
    # The log size the comparison starts from. A NEW launch truncates the log
    # (:447 opens it with >), so for one anything above 0 is growth; a backfill
    # that predates the kickstart keeps writing into the same file, so growth
    # is anything above what was there before.
    local sum_prev sum_cur sum_max grew=0 lines_cur procs_n procs_l slot_s slot_i cont
    local alive="" finished=0 want_full="" live_signal growth
    sum_prev="$sum0"
    [ "$launched_new" -eq 1 ] && sum_prev=0
    sum_max="$sum_prev"
    lines_cur=""; procs_n=0; procs_l=""; slot_s=""; slot_i=""; cont=""; sum_cur="$sum_prev"
    while :; do
        elapsed=$(( $(_ww_now) - start ))
        waited=$(( iter * step ))
        [ "$elapsed" -gt "$waited" ] && waited="$elapsed"
        reading="$(_ww_poll_backfill "$pid" "$want_full" 2>&1)"
        prc=$?
        if [ "$prc" -ne 0 ]; then
            printf '  [%4ss] backfill unreadable (transport exit %s): %s\n' "$waited" "$prc" "$(printf '%s' "$reading" | head -1)"
        else
            alive="$(_ww_field "$reading" PID | cut -d' ' -f2)"
            sum_cur="$(_ww_field "$reading" SUMLOG | cut -d' ' -f1)"
            case "$sum_cur" in absent|''|*[!0-9]*) sum_cur=0 ;; esac
            lines_cur="$(_ww_field "$reading" SUMLINES)"
            procs_n="$(_ww_field "$reading" PROCS | cut -d' ' -f1)"
            procs_l="$(_ww_field "$reading" PROCS | cut -d' ' -f2- | sed 's/ *$//')"
            slot_s="$(_ww_field "$reading" SLOT | cut -d' ' -f1)"
            slot_i="$(_ww_field "$reading" SLOTINFO)"
            cont="$(_ww_field "$reading" CONTAINER)"
            case "${procs_n}" in ''|*[!0-9]*) procs_n=0 ;; esac
            growth="static"
            if [ "$sum_cur" -gt "$sum_prev" ]; then grew=1; growth="GREW from ${sum_prev}"; fi
            [ "$sum_cur" -gt "$sum_max" ] && sum_max="$sum_cur"
            sum_prev="$sum_cur"
            # Something of ours is alive when the wrapper is, when a process of
            # this account names the compiler or the tick, when the slot is
            # held by wiki-recompile with a live pid, or when the container is
            # still running after the wrapper has gone.
            live_signal=0
            [ "$alive" = "alive" ] && live_signal=1
            [ "$procs_n" -gt 0 ] && live_signal=1
            case "$slot_i" in *"holder=wiki-recompile "*" alive "*) live_signal=1 ;; esac
            case "$cont" in running*) live_signal=1 ;; esac
            printf '  [%4ss] wrapper pid %s %s; summaries log %s bytes, %s line(s), %s; slot %s; matching processes: %s%s\n' \
                "$waited" "$pid" "$alive" "$sum_cur" "${lines_cur:-0}" "$growth" "$slot_s" "$procs_n" "${procs_l:+ [${procs_l}]}"
            if [ "$alive" = "dead" ] && [ "$want_full" != "full" ]; then
                # The wrapper is gone. Take the next reading WITH the container
                # check before deciding anything: a killed docker client does
                # not stop its container.
                want_full="full"
                continue
            fi
            if [ "$live_signal" -eq 0 ]; then
                finished=1
                printf '  [%4ss] nothing of ours is alive any more: the backfill is over\n' "$waited"
                break
            fi
        fi
        if [ "$waited" -ge "$budget" ]; then break; fi
        sleep "$gap"; iter=$((iter + 1))
    done
    [ "$want_full" = "full" ] || reading="$(_ww_poll_backfill "$pid" full 2>&1)"

    if [ "$finished" -ne 1 ]; then
        WIKI_WAIT_ELAPSED="$waited"
        if [ "$sum_max" -eq 0 ]; then
            # Alive, and not one byte in the whole budget: blocked before its
            # first line. The slot holder on the line is the usual reason.
            WIKI_WAIT_STATE="finding"
            WIKI_WAIT_DETAIL="THE BACKFILL WROTE NOTHING: $(_ww_field "$reading" SUMLOG | cut -d' ' -f2-) was 0 bytes for the whole ${waited}s and something of ours is still alive (wrapper pid ${pid} ${alive}; slot ${slot_s}${slot_i:+, $slot_i}; ${procs_n} matching process(es)); the compile never printed its first line"
            printf '  FINDING: THE BACKFILL WROTE NOTHING in %ss, and it is STILL ALIVE. %s\n' "$waited" "$(_ww_field "$reading" SUMLOG | cut -d' ' -f2-)"
            printf '  was 0 bytes for the whole budget while the wrapper pid %s was %s, the slot was\n' "$pid" "$alive"
            printf '  %s%s and %s process(es) of this account named the compiler or the tick.\n' "$slot_s" "${slot_i:+ ($slot_i)}" "$procs_n"
            printf '  The compile never printed its first line: it is blocked before it, and the slot\n'
            printf '  holder above is the usual reason. Nothing is measured about the producer yet;\n'
            printf '  this is a finding about the backfill, not a pass and not a producer defect.\n'
        elif [ "$grew" -eq 1 ]; then
            WIKI_WAIT_STATE="cannot-run"
            WIKI_WAIT_DETAIL="NOT CONVERGED IN TIME: the summary backfill was still alive at the ${budget}s budget and its log was growing (${sum_max} bytes); a compile that has not finished has not had its chance to write"
            printf '  CANNOT-RUN: NOT CONVERGED IN TIME. After %ss the summary backfill is still alive\n' "$waited"
            printf '  (wrapper pid %s %s; slot %s; %s matching process(es); container: %s) and its log\n' "$pid" "$alive" "$slot_s" "$procs_n" "${cont:-not checked}"
            printf '  is GROWING (%s bytes, %s line(s)). A compile that has not finished has not had\n' "$sum_max" "${lines_cur:-?}"
            printf '  its chance to write, so nothing is measured about the producer. Not a FAIL.\n'
            printf '  Raise OSTLER_WIKI_WAIT_BUDGET_S if the box is slow.\n'
        else
            WIKI_WAIT_STATE="cannot-run"
            WIKI_WAIT_DETAIL="NOT CONVERGED IN TIME: the summary backfill was still alive at the ${budget}s budget with ${sum_max} bytes of log that did not grow during the wait"
            printf '  CANNOT-RUN: NOT CONVERGED IN TIME. After %ss the summary backfill is still alive\n' "$waited"
            printf '  (wrapper pid %s %s; slot %s; %s matching process(es); container: %s) with %s\n' "$pid" "$alive" "$slot_s" "$procs_n" "${cont:-not checked}" "$sum_max"
            printf '  bytes of log that did not grow during the wait. Nothing is measured about the\n'
            printf '  producer. Not a FAIL.\n'
        fi
        _ww_print_diag "$reading"
        printf '\n'
        return 1
    fi

    # -- 5. the journal, after -------------------------------------------------
    local after_raw arc after_n
    after_raw="$(_ww_count_rows "${WIKI_WAIT_JOURNAL}")"
    arc=$?
    WIKI_WAIT_ELAPSED=$(( $(_ww_now) - start ))
    if [ "$arc" -ne 0 ] || [ -z "$after_raw" ]; then
        WIKI_WAIT_STATE="cannot-run"
        WIKI_WAIT_DETAIL="could not count the journal AFTER the backfill ended (exit ${arc}); what it wrote is unmeasured"
        printf '  CANNOT-RUN: could not count the journal AFTER the backfill (exit %s) at %ss, so\n' "$arc" "$WIKI_WAIT_ELAPSED"
        printf '  the delta has only one end. The backfill DID end; what it wrote is unmeasured.\n'
        _ww_print_diag "$reading"
        printf '\n'
        return 1
    fi
    WIKI_WAIT_AFTER="${after_raw%% *}"
    case "${WIKI_WAIT_AFTER}" in
        -1) after_n=0; printf '  after  : the journal still does not exist\n' ;;
        ''|*[!0-9]*)
            WIKI_WAIT_STATE="cannot-run"
            WIKI_WAIT_DETAIL="the AFTER count came back as [${WIKI_WAIT_AFTER}], which is not a number"
            printf '  CANNOT-RUN: the AFTER count came back as [%s], which is not a number (%ss).\n' "${WIKI_WAIT_AFTER}" "$WIKI_WAIT_ELAPSED"
            printf '  The backfill ended and its effect is unmeasured.\n'
            _ww_print_diag "$reading"
            printf '\n'
            return 1
            ;;
        *) after_n="${WIKI_WAIT_AFTER}"
           printf '  after  : %s row(s) with session_id starting %s (%s unparseable line(s))\n' \
               "${WIKI_WAIT_AFTER}" "${_WW_SESSION_PREFIX}" "${after_raw##* }" ;;
    esac

    WIKI_WAIT_DELTA=$(( after_n - before_n ))
    printf '  delta  : %s row(s)\n' "${WIKI_WAIT_DELTA}"

    # THE DELTA IS THE MEASUREMENT, taken only once nothing of ours is alive.
    if [ "${WIKI_WAIT_DELTA}" -gt 0 ]; then
        WIKI_WAIT_STATE="converged"
        WIKI_WAIT_DETAIL="the summary backfill (pid ${pid}, started via ${how}) ended after ${WIKI_WAIT_ELAPSED}s and cm044_wiki_compiler wrote ${WIKI_WAIT_DELTA} row(s)"
        printf '  CONVERGED: the summary backfill (pid %s) ended after %ss and cm044_wiki_compiler\n' "$pid" "$WIKI_WAIT_ELAPSED"
        printf '  wrote %s row(s) carrying %s. The producer is present for\n' "${WIKI_WAIT_DELTA}" "${_WW_SESSION_PREFIX}"
        printf '  usage_journal_producers to find, on a compile that ran AFTER the seeds.\n'
        _ww_print_diag "$reading"
        printf '\n'
        return 0
    fi

    if [ "${WIKI_WAIT_DELTA}" -lt 0 ]; then
        WIKI_WAIT_STATE="finding"
        WIKI_WAIT_DETAIL="the journal LOST ${WIKI_WAIT_DELTA} cm044-compile- row(s) across the backfill (${WIKI_WAIT_ELAPSED}s); something truncated or rotated it"
        printf '  FINDING: the journal LOST %s row(s) across the backfill (%ss). Something\n' "${WIKI_WAIT_DELTA}" "$WIKI_WAIT_ELAPSED"
        printf '  truncated or rotated the file while the product was writing to it, which is a\n'
        printf '  finding about the journal and not about the producer.\n'
        _ww_print_diag "$reading"
        printf '\n'
        return 1
    fi

    if [ "$sum_max" -eq 0 ]; then
        # THE 19:08Z SHAPE. The wrapper is gone, nothing of ours is alive, the
        # log never received a byte, and the tick exited 0 for having launched
        # it. Every liveness signal reads green; nothing ran.
        WIKI_WAIT_STATE="finding"
        WIKI_WAIT_DETAIL="THE BACKFILL WROTE NOTHING: $(_ww_field "$reading" SUMLOG | cut -d' ' -f2-) is 0 bytes, the wrapper pid ${pid} is gone after ${WIKI_WAIT_ELAPSED}s, nothing of ours is alive (${procs_n} matching process(es); container: ${cont:-not checked}; slot ${slot_s}) and the journal gained 0 rows carrying ${_WW_SESSION_PREFIX}; the tick exited 0 for having launched it (wiki-recompile-tick.sh:451-454)"
        printf '  FINDING: THE BACKFILL WROTE NOTHING. %s\n' "$(_ww_field "$reading" SUMLOG | cut -d' ' -f2-)"
        printf '  is 0 bytes, the wrapper pid %s is gone after %ss, nothing of ours is alive\n' "$pid" "$WIKI_WAIT_ELAPSED"
        printf '  (%s matching process(es); container: %s; slot %s) and the journal gained 0\n' "$procs_n" "${cont:-not checked}" "$slot_s"
        printf '  rows carrying %s. The compile never printed a byte, so it never ran its\n' "${_WW_SESSION_PREFIX}"
        printf '  summary pass, and the tick exited 0 for having LAUNCHED it (wiki-recompile-tick.sh\n'
        printf '  :451-454), so every liveness signal reads green. This is the shape measured on the\n'
        printf '  v1.0.82 box at 19:08Z. It is a finding about the backfill launch, NOT about\n'
        printf '  cm044_wiki_compiler, which was never given a chance to write.\n'
        _ww_print_diag "$reading"
        printf '\n'
        return 1
    fi

    WIKI_WAIT_STATE="finding"
    WIKI_WAIT_DETAIL="THE COMPILE RAN AND cm044_wiki_compiler DID NOT WRITE: the summary backfill (pid ${pid}) ended after ${WIKI_WAIT_ELAPSED}s with ${sum_max} bytes of log and the journal gained 0 rows carrying ${_WW_SESSION_PREFIX}; a PRESENT producer that did not write"
    printf '  FINDING: THE COMPILE RAN AND cm044_wiki_compiler DID NOT WRITE. The summary pass\n'
    printf '  ran to its end (pid %s gone after %ss; %s)\n' "$pid" "$WIKI_WAIT_ELAPSED" "$(_ww_sum_desc "$reading")"
    printf '  and the journal gained zero rows carrying %s. cm044_wiki_compiler is a\n' "${_WW_SESSION_PREFIX}"
    printf '  PRESENT producer that did not write: not absent, not unexercised. This is the one\n'
    printf '  outcome here that is a finding about the producer itself, and it belongs to the\n'
    printf '  compiler writer path (contract WHAT EACH REPO OWES: every embedding and every\n'
    printf '  summarisation call in the compiler), or to a runtime that reported no usable\n'
    printf '  token count to it.\n'
    _ww_print_diag "$reading"
    printf '\n'
    return 1
}
