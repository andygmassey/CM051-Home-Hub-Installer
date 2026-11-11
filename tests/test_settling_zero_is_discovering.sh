#!/usr/bin/env bash
#
# test_settling_zero_is_discovering.sh
#
# A channel that reports done=0 total=0 WITHOUT a terminal marker has not
# finished. It has not yet discovered its work. It must not read as terminal,
# or the Setting-up bar can touch 100% and then fall back when the work turns
# up. Only an explicit marker makes a channel terminal:
#   settling_complete <channel>        -> complete:true
#   settling_skip <channel> <reason>   -> skip_reason:"<reason>"
#
# Proven here, on real shard files written by lib/settling_progress.sh and
# judged by the real probe scripts/box_walk_probes/probes/setup_progress_advancing.sh:
#   1. 0/0 unmarked: status "discovering", complete false, NOT terminal (probe FAILs it).
#   2. 0/0 with settling_complete: complete true, terminal (probe PASSes it).
#   3. 0/0 with settling_skip <reason>: terminal, reason recorded.
#   4. Discovery sequence 0/0 -> 0/50 -> 50/50 (complete): done never goes
#      down, and the channel is non-terminal until the final complete marker.
#   5. A complete channel that is re-run at 0/N (same N, nothing new) stays
#      complete: the marker is carried forward, not lost to a later 0/0 write.
#
# Usage: bash tests/test_settling_zero_is_discovering.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/settling_progress.sh"
PROBE="$REPO_ROOT/scripts/box_walk_probes/probes/setup_progress_advancing.sh"

pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

printf '== test_settling_zero_is_discovering ==\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export OSTLER_STATE_DIR="$TMP/state"
export HOME="$TMP/home"
export OSTLER_STABILITY_INTERVAL_S=0
mkdir -p "$HOME"
SHARD_DIR="$OSTLER_STATE_DIR/settling_progress.d"

field() {  # field <channel-file> <key>  -> JSON value, or "missing"
    python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(d[sys.argv[2]]) if sys.argv[2] in d else "missing")' "$1" "$2" 2>/dev/null || echo "unreadable"
}

# probe_verdict <dir> -> "PASS" | "FAIL" | "CANNOT-RUN" | "ERR:<rc>"
probe_verdict() {
    OSTLER_SETTLING_DIR="$1" bash "$PROBE" >"$TMP/probe.out" 2>&1
    case $? in
        0) echo PASS ;;
        1) echo FAIL ;;
        2) echo CANNOT-RUN ;;
        *) echo "ERR:$?" ;;
    esac
}

# Run the writer in a clean shell with the real library.
w() { bash -c '. "$0"; "$@"' "$LIB" "$@" >/dev/null 2>&1; }
rep()      { w settling_report "$@"; }
complete() { w settling_complete "$@"; }
skip()     { w settling_skip "$@"; }

# ── 1. 0/0 unmarked is discovering, not terminal ───────────────────────────

rm -rf "$SHARD_DIR"
rep contacts 0 0 false
F="$SHARD_DIR/contacts.json"
[ "$(field "$F" complete)" = "false" ] \
    && ok "0/0 unmarked: complete is false" \
    || bad "0/0 unmarked: complete=$(field "$F" complete), want false"
[ "$(field "$F" status)" = '"discovering"' ] \
    && ok "0/0 unmarked: status is discovering" \
    || bad "0/0 unmarked: status=$(field "$F" status), want \"discovering\""

# Judge twice (start and end sample are the same shard): nothing moves, so the
# probe must FAIL it as open. A PASS here means 0/0 is being read as terminal.
v="$(probe_verdict "$SHARD_DIR")"
[ "$v" = "FAIL" ] \
    && ok "0/0 unmarked: probe judges it OPEN (FAIL, not terminal)" \
    || bad "0/0 unmarked: probe verdict=$v, want FAIL (0/0 read as terminal)"

# ── 2. 0/0 with settling_complete is terminal ──────────────────────────────

rm -rf "$SHARD_DIR"
rep contacts 0 0 false
complete contacts
[ "$(field "$F" complete)" = "true" ] \
    && ok "0/0 then settling_complete: complete is true" \
    || bad "0/0 then settling_complete: complete=$(field "$F" complete), want true"
v="$(probe_verdict "$SHARD_DIR")"
[ "$v" = "PASS" ] \
    && ok "0/0 then settling_complete: probe judges it TERMINAL (PASS)" \
    || bad "0/0 then settling_complete: probe verdict=$v, want PASS"

# ── 3. 0/0 with settling_skip <reason> is terminal, reason recorded ────────

rm -rf "$SHARD_DIR"
rep notes 0 0 false
skip notes no_contacts
[ "$(field "$SHARD_DIR/notes.json" skip_reason)" = '"no_contacts"' ] \
    && ok "settling_skip: skip_reason recorded" \
    || bad "settling_skip: skip_reason=$(field "$SHARD_DIR/notes.json" skip_reason)"
v="$(probe_verdict "$SHARD_DIR")"
[ "$v" = "PASS" ] \
    && ok "settling_skip: probe judges it TERMINAL (PASS)" \
    || bad "settling_skip: probe verdict=$v, want PASS"

# ── 4. Discovery sequence 0/0 -> 0/50 -> 50/50 complete ────────────────────

rm -rf "$SHARD_DIR"
seq_ok=1; last_done=-1; terminal_early=0
step() {  # step <label> <expect-complete> ; reads current shard
    local d t c
    d="$(field "$F" done)"; t="$(field "$F" total)"; c="$(field "$F" complete)"
    if [ "$d" -lt "$last_done" ] 2>/dev/null; then seq_ok=0; fi
    last_done="$d"
    if [ "$c" = "true" ] && [ "$2" = "open" ]; then terminal_early=1; fi
    printf '    %-22s done=%s total=%s complete=%s\n' "$1" "$d" "$t" "$c"
}
rep contacts 0 0 false;                 step "0/0 discovering" open
rep contacts 0 50 false;                step "0/50 found 50" open
rep contacts 50 50 false;               step "50/50 measured" open
complete contacts;                      step "50/50 complete" done
[ "$seq_ok" = 1 ] \
    && ok "discovery sequence: done never decreases" \
    || bad "discovery sequence: done decreased somewhere in 0/0 -> 0/50 -> 50/50"
[ "$terminal_early" = 0 ] \
    && ok "discovery sequence: terminal only after the complete marker" \
    || bad "discovery sequence: channel read terminal before settling_complete"

# ── 5. A complete channel re-run at 0/N (same N) stays complete ────────────

rep contacts 0 0 false
[ "$(field "$F" complete)" = "true" ] \
    && ok "re-run 0/0 after complete (no growth): stays complete" \
    || bad "re-run 0/0 after complete: complete=$(field "$F" complete), want true"
v="$(probe_verdict "$SHARD_DIR")"
[ "$v" = "PASS" ] \
    && ok "re-run after complete: probe still TERMINAL (PASS)" \
    || bad "re-run after complete: probe verdict=$v, want PASS"

# ── 6. The python writer (calendar / iMessage / WhatsApp) obeys the same rule ──

PYW="$TMP/pyw"
mkdir -p "$PYW"
if python3 -I - "$REPO_ROOT/vendor" "$PYW" <<'PYEOF'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from ostler_fda.settling_progress import report_settling_progress as r
st = Path(sys.argv[2])
d = st / "settling_progress.d"
r("calendar", done=0, total=0, state_dir=st)
a = json.load(open(d / "calendar.json"))
assert a["complete"] is False and a["status"] == "discovering", a
r("messages", done=0, total=0, state_dir=st, shard="imessage", skip_reason="no_messages")
b = json.load(open(d / "messages.imessage.json"))
assert b["skip_reason"] == "no_messages" and b["status"] == "skipped", b
r("calendar", done=0, total=0, state_dir=st, complete=True)
r("calendar", done=0, total=0, state_dir=st)
c = json.load(open(d / "calendar.json"))
assert c["complete"] is True and c["status"] == "complete", c
PYEOF
then
    ok "python writer: 0/0 discovering, skip_reason terminal, complete carried forward"
else
    bad "python writer: terminal semantics differ from the shell writer"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
