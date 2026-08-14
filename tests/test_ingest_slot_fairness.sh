#!/usr/bin/env bash
#
# test_ingest_slot_fairness.sh
#
# Guards the ingest-slot starvation fix measured on the live v1.0.26 Hub
# on 2026-08-14, where the iMessage conversation feed had never completed
# a single pass since install.
#
# ---------------------------------------------------------------------
# The mechanism
# ---------------------------------------------------------------------
# Four conversation feeds and the wiki recompile contend for ONE mkdir
# mutex (workspace/ingest-ollama.lock.d). They ran three mutually
# incompatible policies on it: email and spoken instant-yield, iMessage
# and WhatsApp wait a flat 75s if they have never run, the wiki recompile
# spins unbounded. NONE of them bounded the HOLD.
#
# A holder keeps the slot for exactly as long as its pipeline runs, and
# those pipelines loop over a whole document queue dispatching each item
# to pwg-convo. Measured per-document on the box: 17s to 900s. Measured
# hold: over an hour, still running. Against that, a 75s constant can
# never win, and neither can any other constant. That is why the earlier
# attempt at this fix (copying the same 75s block into the other three
# feeds, origin/fix/conversations-ingest-fairness-all-feeds) could not
# have worked: it changes who waits, not how long a holder may hold.
#
# Note also that the holder was NOT idle. Its tick.sh showed 0:00.01 CPU
# over 52 minutes, which reads as a stuck waiter, but the work was in a
# grandchild: tick.sh waits on the pipeline, which dispatches pwg-convo,
# which drives Ollama. Elapsed time on the wrong process in the tree is
# not evidence of a hang.
#
# ---------------------------------------------------------------------
# What the fix asserts
# ---------------------------------------------------------------------
# Section 2  a starving feed gets the slot while a long holder runs
# Section 3  an idle box does NOT preempt a long holder (the wiki
#            summary backfill legitimately runs for hours and was the
#            original reason no time-based steal existed)
# Section 4  FIFO: the longest-waiting feed is served first
# Section 5  the old policy really does starve (mechanism control, so
#            these numbers are not taken on trust)
# Section 6  reader.py translates a real macOS FDA denial
# Section 7  install.sh delivers the lib, and the embedded copy has not
#            drifted from the canonical one
# Section 8  the wiki recompile tick is wired to the shared slot
#
# Run:  bash tests/test_ingest_slot_fairness.sh
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/ostler-ingest-slot.sh"
INSTALL_SH="$REPO_ROOT/install.sh"
WIKI_TICK="$REPO_ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"
READER="$REPO_ROOT/vendor/imessage_source/reader.py"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "ok: $*"; }

# ---------------------------------------------------------------------
# Section 1 -- the lib exists and parses under the shell it ships under.
# The sealed ticks are forked with /bin/bash, which on macOS is 3.2. A
# 4.x-only construct would pass under Homebrew bash and still break on
# the customer's Mac.
# ---------------------------------------------------------------------
echo "== Section 1: the shared slot lib =="
# Deliberately NOT fatal. When the lib is absent the live sections
# cannot run, but the reader.py, delivery and wiki-wiring sections still
# can, and they are where the behavioural evidence is. A test that exits
# on the first missing file reports one line and hides the rest.
LIB_PRESENT=0
if [ ! -f "$LIB" ]; then
    failure "lib/ostler-ingest-slot.sh is missing. Nothing bounds how long a feed may hold the shared Ollama slot, so a feed that has never run can yield on every tick indefinitely."
else
    LIB_PRESENT=1
    if /bin/bash -n "$LIB" 2>/dev/null; then
        pass "lib parses under /bin/bash $(/bin/bash --version | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')"
    else
        failure "lib has a syntax error under /bin/bash"
    fi
fi

# Fast, deterministic timings for the live sections.
export OSTLER_SLOT_MAX_HOLD_SECS=6
export OSTLER_SLOT_POLL_SECS=1
export OSTLER_SLOT_GRACE_SECS=4
export OSTLER_SLOT_WAIT_SECS=3

fresh_ws() { mktemp -d; }

# The lib resolves its paths ONCE, at source time. A participant that
# sets OSTLER_STATE_DIR as a command prefix on the acquire call rather
# than in the environment before sourcing therefore lands on the REAL
# ~/.ostler/workspace while its counterpart lands in the temp dir. The
# two never contend, the waiter acquires instantly, and the section
# reports a confident pass having tested nothing. That happened while
# writing this file, so every participant now goes through `env`, and
# all three path variables are pinned rather than just the base one.
slot_sh() {
    # slot_sh <workspace> <script> [args...]
    local ws="$1"; shift
    env OSTLER_STATE_DIR="$ws" \
        OSTLER_INGEST_LOCK="$ws/ingest-ollama.lock.d" \
        OSTLER_SLOT_STATE_DIR="$ws/ingest-slot" \
        /bin/bash -c "$@"
}

# Refuse to run against a real installed workspace: a stray lock left in
# ~/.ostler would corrupt the results, and worse, a test run could
# disturb a live ingest.
REAL_WS="${HOME}/.ostler/workspace"
if [ -d "$REAL_WS/ingest-ollama.lock.d" ]; then
    echo "SKIP: $REAL_WS/ingest-ollama.lock.d exists; a live ingest may be holding the slot. Not running the live sections against a real install."
    exit 0
fi

# ---------------------------------------------------------------------
# Section 2 -- THE DEFECT. A feed that has never run must get the slot
# while a long holder is running. This is the live-box scenario.
# ---------------------------------------------------------------------
echo
echo "== Section 2: a starving feed gets a turn while a long holder runs =="
# Sections 2 to 4 exercise the lib itself, so they need it to exist.
# Bodies left unindented to keep the diff readable.
if [ "$LIB_PRESENT" = "1" ]; then
WS="$(fresh_ws)"
# A holder whose payload would run far longer than any waiter's
# patience: the unbounded-queue drain, in miniature.
slot_sh "$WS" '. "$1"; ostler_slot_acquire "email-bundle" >/dev/null 2>&1 || exit 1; ostler_slot_run sleep 300 >/dev/null 2>&1' _ "$LIB" &
HOLDER_SHELL=$!
sleep 2

# Control: the holder must genuinely own the lock in THIS workspace
# before the waiter starts. Without it a misconfigured harness produces
# an instant "acquired" and the section passes having tested nothing.
if [ -d "$WS/ingest-ollama.lock.d" ]; then
    pass "control: the holder owns the slot in the test workspace"
else
    failure "control: the holder never took the slot in $WS; the rest of this section would be meaningless"
fi

START="$(date +%s)"
WAITER_OUT="$(slot_sh "$WS" '. "$1"; if ostler_slot_acquire "imessage-bundle"; then echo ACQUIRED; else echo YIELDED; fi' _ "$LIB" 2>&1)"
ELAPSED=$(( $(date +%s) - START ))
kill "$HOLDER_SHELL" 2>/dev/null || true
wait "$HOLDER_SHELL" 2>/dev/null || true

case "$WAITER_OUT" in
    *ACQUIRED*)
        pass "the starving feed acquired the slot after ${ELAPSED}s (holder payload would have run 300s)" ;;
    *)
        failure "the starving feed never got the slot in ${ELAPSED}s. This is the live-box defect: the feed logs 'this feed has NEVER RUN' and yields forever. Output: $WAITER_OUT" ;;
esac
# A handoff that takes NO time means the two never contended.
if [ "$ELAPSED" -lt 1 ]; then
    failure "the waiter acquired in under a second, so it never actually waited on the holder; the participants are not sharing a slot"
elif [ "$ELAPSED" -le 30 ]; then
    pass "handoff took ${ELAPSED}s, within the configured ${OSTLER_SLOT_MAX_HOLD_SECS}s maximum hold plus grace"
else
    failure "handoff took ${ELAPSED}s, far past the ${OSTLER_SLOT_MAX_HOLD_SECS}s maximum hold; the bound is not being enforced"
fi
rm -rf "$WS"

# ---------------------------------------------------------------------
# Section 3 -- the constraint that made a naive fix unsafe. With NOBODY
# waiting, a long holder must NOT be preempted. The wiki summary backfill
# holds this same slot for hours and is essential; chopping it every N
# seconds would be a regression dressed up as a fix.
# ---------------------------------------------------------------------
echo
echo "== Section 3: an idle box does not preempt a long holder =="
WS="$(fresh_ws)"
slot_sh "$WS" '. "$1"; ostler_slot_acquire "wiki-recompile" >/dev/null 2>&1 || exit 1; ostler_slot_run sleep 300 >/dev/null 2>&1' _ "$LIB" &
IDLE_HOLDER=$!
sleep 2
if [ -d "$WS/ingest-ollama.lock.d" ]; then
    pass "control: the idle holder owns the slot in the test workspace"
else
    failure "control: the idle holder never took the slot in $WS"
fi
# Wait well past the 6s maximum hold with no waiter enrolled at any point.
sleep 12
if [ -d "$WS/ingest-ollama.lock.d" ]; then
    pass "holder still owns the slot ${OSTLER_SLOT_MAX_HOLD_SECS}s past its maximum hold because nothing is waiting"
else
    failure "holder was preempted with no waiter enrolled; this would chop the multi-hour wiki summary backfill on an idle box"
fi
if [ -f "$WS/ingest-slot/wiki-recompile.state" ] && grep -q '^preempt_count=' "$WS/ingest-slot/wiki-recompile.state" 2>/dev/null; then
    failure "a preemption was recorded on an idle box"
else
    pass "no preemption recorded on an idle box"
fi
kill "$IDLE_HOLDER" 2>/dev/null || true
wait "$IDLE_HOLDER" 2>/dev/null || true
rm -rf "$WS"

# ---------------------------------------------------------------------
# Section 4 -- FIFO. Without it a feed can be beaten to a freed slot by a
# luckier neighbour over and over, which is starvation by another route.
# ---------------------------------------------------------------------
echo
echo "== Section 4: the longest-waiting feed is served first =="
WS="$(fresh_ws)"
slot_sh "$WS" '. "$1"; ostler_slot_acquire "email-bundle" >/dev/null 2>&1 || exit 1; ostler_slot_run sleep 300 >/dev/null 2>&1' _ "$LIB" &
FIFO_HOLDER=$!
sleep 2
# "first" enrols two poll intervals before "second". The names are chosen
# so lexicographic order would pick the WRONG winner if enrolment time
# were ignored, which is what makes this a test of FIFO rather than of
# glob order.
slot_sh "$WS" '. "$1"; ostler_slot_acquire "zzz-first" >/dev/null 2>&1 && echo first > "$2"' _ "$LIB" "$WS/winner" &
FIRST=$!
sleep 2
slot_sh "$WS" '. "$1"; ostler_slot_acquire "aaa-second" >/dev/null 2>&1 && echo second > "$2"' _ "$LIB" "$WS/winner" &
SECOND=$!
wait "$FIRST" 2>/dev/null || true
WINNER="$(cat "$WS/winner" 2>/dev/null || echo none)"
kill "$SECOND" "$FIFO_HOLDER" 2>/dev/null || true
wait "$SECOND" 2>/dev/null || true
wait "$FIFO_HOLDER" 2>/dev/null || true
if [ "$WINNER" = "first" ]; then
    pass "the feed that enrolled first won the freed slot"
else
    failure "expected the first-enrolled feed to win, got '$WINNER'"
fi
rm -rf "$WS"
else
echo "  (sections 2 to 4 skipped: the lib they exercise does not exist)"
fi

# ---------------------------------------------------------------------
# Section 5 -- mechanism control. Reproduce the OLD policy (a constant
# patience racing an unbounded hold) and confirm it really does starve.
# Without this the numbers above are just assertions about new code; with
# it, the test carries its own evidence that the old shape was the fault.
# ---------------------------------------------------------------------
echo
echo "== Section 5: control -- the old constant-patience policy starves =="
WS="$(fresh_ws)"
LOCK="$WS/ingest-ollama.lock.d"
mkdir -p "$LOCK"
/bin/bash -c 'sleep 300' &
OLD_HOLDER=$!
printf '%s\n' "$OLD_HOLDER" > "$LOCK/pid"
# The shipped pre-fix algorithm, verbatim in shape: wait a CONSTANT, then
# yield. Compressed 75s -> 6s purely so the test is quick; the ratio to
# an unbounded hold is what matters, and it is unchanged.
OLD_RESULT="$(
    /bin/bash -c '
        _lock="$1"; _waited=0; _got=0
        while [ "$_waited" -lt 6 ]; do
            sleep 1; _waited=$((_waited + 1))
            if mkdir "$_lock" 2>/dev/null; then _got=1; break; fi
            _h="$(cat "$_lock/pid" 2>/dev/null || true)"
            if [ -z "${_h:-}" ] || ! kill -0 "$_h" 2>/dev/null; then
                rm -rf "$_lock" 2>/dev/null || true
                if mkdir "$_lock" 2>/dev/null; then _got=1; break; fi
            fi
        done
        [ "$_got" = "1" ] && echo ACQUIRED || echo STARVED
    ' _ "$LOCK"
)"
kill "$OLD_HOLDER" 2>/dev/null || true
wait "$OLD_HOLDER" 2>/dev/null || true
if [ "$OLD_RESULT" = "STARVED" ]; then
    pass "control: the old constant-patience policy starves against an unbounded hold, as measured on the box"
else
    failure "control did not reproduce the defect (got '$OLD_RESULT'); the comparison in Section 2 cannot be trusted"
fi
rm -rf "$WS"

# ---------------------------------------------------------------------
# Section 6 -- reader.py. The FDA translation keyed only on
# "authorization denied", a string macOS does not emit here, so the
# branch was unreachable and every real denial escaped as a bare
# sqlite3.OperationalError. The live box showed exactly that.
# ---------------------------------------------------------------------
echo
echo "== Section 6: reader.py translates a real macOS FDA denial =="
if [ ! -f "$READER" ]; then
    failure "missing $READER"
else
    PY_OUT="$(python3 - "$READER" <<'PYEOF' 2>&1
import importlib.util, sqlite3, sys, tempfile, pathlib

spec = importlib.util.spec_from_file_location("reader_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
# @dataclass looks the owning module up in sys.modules while the class
# body executes, so the module has to be registered BEFORE exec_module.
sys.modules["reader_under_test"] = mod
try:
    spec.loader.exec_module(mod)
except Exception as exc:  # import-time failure is itself a result
    print(f"IMPORT_FAILED {exc}")
    raise SystemExit(0)

tmp = pathlib.Path(tempfile.mkdtemp()) / "chat.db"
tmp.write_bytes(b"x")

real = sqlite3.connect

# The EXACT string macOS emits when TCC denies the open. Taken from the
# live box's imessage-bundle.err, not invented: the same run's fda-rerun
# log reported "iMessage: unable to open database file" for a context
# without Full Disk Access.
def denied(*a, **k):
    raise sqlite3.OperationalError("unable to open database file")

sqlite3.connect = denied
try:
    mod._connect_ro(tmp)
    print("NO_RAISE")
except PermissionError as exc:
    print("PERMISSION_ERROR", str(exc))
except sqlite3.OperationalError as exc:
    print("RAW_OPERATIONAL_ERROR", str(exc))
except Exception as exc:
    print("OTHER", type(exc).__name__, str(exc))
finally:
    sqlite3.connect = real
PYEOF
)"
    case "$PY_OUT" in
        PERMISSION_ERROR*Full\ Disk\ Access*)
            pass "a TCC denial becomes a PermissionError naming Full Disk Access" ;;
        RAW_OPERATIONAL_ERROR*)
            failure "the raw sqlite3.OperationalError escapes untranslated. This is the live-box defect: the customer's log got a bare traceback and the pipeline exited 1, which the tick then reported as 'chat.db not found' -- actively the wrong cause. Output: $PY_OUT" ;;
        *)
            failure "unexpected result from the reader probe: $PY_OUT" ;;
    esac

    # Disambiguation guard: a genuinely MISSING database must still be
    # reported as missing, not blamed on Full Disk Access.
    MISSING_OUT="$(python3 - "$READER" <<'PYEOF' 2>&1
import importlib.util, sys, pathlib, tempfile
spec = importlib.util.spec_from_file_location("reader_under_test", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
# @dataclass looks the owning module up in sys.modules while the class
# body executes, so the module has to be registered BEFORE exec_module.
sys.modules["reader_under_test"] = mod
spec.loader.exec_module(mod)
absent = pathlib.Path(tempfile.mkdtemp()) / "definitely-absent.db"
try:
    mod._connect_ro(absent)
    print("NO_RAISE")
except FileNotFoundError:
    print("FILE_NOT_FOUND")
except Exception as exc:
    print("OTHER", type(exc).__name__)
PYEOF
)"
    if [ "$MISSING_OUT" = "FILE_NOT_FOUND" ]; then
        pass "a missing database is still reported as missing, not as an FDA problem"
    else
        failure "a missing database is no longer distinguished from an FDA denial: $MISSING_OUT"
    fi
fi

# ---------------------------------------------------------------------
# Section 7 -- delivery. A lib that install.sh never writes is merged but
# not delivered, and the sealed ticks fall back to the unbounded path.
# ---------------------------------------------------------------------
echo
echo "== Section 7: install.sh delivers the lib, with no drift =="
if grep -q 'OSTLER_INGEST_SLOT_EOF' "$INSTALL_SH"; then
    pass "install.sh carries the embedded lib heredoc"
else
    failure "install.sh does not deliver ostler-ingest-slot.sh; the sealed ticks would fall back to the unbounded path on every install"
fi
grep -q 'chmod +x "${HOME}/.ostler/lib/ostler-ingest-slot.sh"' "$INSTALL_SH" \
    || failure "install.sh never makes the lib executable"

EMBED="$(awk "/<<.OSTLER_INGEST_SLOT_EOF.\$/{f=1;next} /^OSTLER_INGEST_SLOT_EOF\$/{f=0} f" "$INSTALL_SH")"
EMBED_LINES="$(printf '%s\n' "$EMBED" | grep -c .)"
if [ "$EMBED_LINES" -lt 50 ]; then
    failure "extracted only $EMBED_LINES lines from the install.sh embed; the extractor is not matching, so a drift PASS here would be meaningless"
else
    pass "extracted $EMBED_LINES lines from the install.sh embed"
    if [ "$EMBED" = "$(cat "$LIB")" ]; then
        pass "embedded install.sh copy matches the canonical lib (no drift)"
    else
        failure "the embedded copy of the lib has drifted from lib/ostler-ingest-slot.sh"
    fi
fi

# ---------------------------------------------------------------------
# Section 8 -- the wiki recompile is the longest holder on the box. If it
# is not wired, it can still hold the slot for hours with a feed waiting.
# ---------------------------------------------------------------------
echo
echo "== Section 8: the wiki recompile tick is wired to the shared slot =="
if grep -q 'ostler-ingest-slot.sh' "$WIKI_TICK"; then
    pass "wiki recompile consults the shared slot lib"
else
    failure "wiki recompile still takes the slot with an unbounded hold; it is the longest holder on the box"
fi
grep -q 'ostler_slot_run' "$WIKI_TICK" \
    || failure "wiki recompile does not run its compile under ostler_slot_run, so no maximum-hold watchdog is armed"
grep -q 'OSTLER_SLOT_WIKI_MAX_HOLD_SECS' "$WIKI_TICK" \
    || failure "wiki recompile has no dedicated maximum-hold knob; a compile legitimately runs for hours"
if /bin/bash -n "$WIKI_TICK" 2>/dev/null; then
    pass "wiki recompile tick parses under /bin/bash"
else
    failure "wiki recompile tick has a syntax error under /bin/bash"
fi

echo
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAILED"
    exit 1
fi
echo "RESULT: PASSED"
