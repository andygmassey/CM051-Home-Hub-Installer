#!/usr/bin/env bash
# probes/setup_progress_reaches_done.sh
# ============================================================================
# QUESTION: does every source in the Setting-up progress denominator reach a
#           TERMINAL state, so the bar can finish?
#
# THE DENOMINATOR. The Hub's Setting-up percentage is done/total summed over
# the settling shards in state/settling_progress.d/<channel>.json (CM044
# compiler/hydration.py settling_progress). A shard that never finishes holds
# the whole bar down: on Mini16 (2026-11-11) it sat at 71% because emails was
# 17080/121262 and contacts 2398/2443, both last written 2026-11-08.
#
# TERMINAL means one of:
#   complete:true                    the writer finished this source
#   skip_reason:"<code>"             yielded nothing by design, or unreadable
#   total>0 and done>=total          all the work it measured is done
#   total==0 and needs_source false  nothing to measure, nothing queued
#
# NOT TERMINAL: needs_source:true with no work (a question, not an end state),
# a partial count with no completion marker, and an unreadable shard. An
# unreadable shard is a writer fault: the reader skips it silently, so the bar
# would read high without saying so.
#
# TIMING. The walk runs this after its settle window, so it judges the state the
# customer would see at that point. It does not wait.
#
# NO DIRECTORY = CANNOT-RUN, not PASS. Zero shards means nothing was measured.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="setup_progress_reaches_done"
PROBE_QUESTION="does every source in the Setting-up progress reach a terminal state?"

_settling_dir() {
    if [ -n "${OSTLER_SETTLING_DIR:-}" ]; then
        printf '%s' "$OSTLER_SETTLING_DIR"
    else
        printf '%s/settling_progress.d' "${OSTLER_STATE_DIR:-$HOME/.ostler/state}"
    fi
}

# Classifies every shard in one directory. Prints one line per shard:
#   <file>|TERMINAL|<why>   or   <file>|OPEN|<why>
# Exit 0 always; the caller reads the lines. Stdlib only, isolated mode.
_classify_shards() {
    python3 -I - "$1" <<'PY'
import glob, json, os, sys

d = sys.argv[1]

def terminal(r):
    reason = r.get("skip_reason")
    if isinstance(reason, str) and reason.strip():
        return "skipped: " + reason.strip()
    if r.get("complete") is True:
        return "complete"
    done = int(r.get("done") or 0)
    total = int(r.get("total") or 0)
    if total > 0 and done >= total:
        return "measured done %d/%d" % (done, total)
    if total == 0 and not r.get("needs_source"):
        return "nothing to measure"
    return None

for path in sorted(glob.glob(os.path.join(d, "*.json"))):
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as fh:
            r = json.load(fh)
        if not isinstance(r, dict):
            raise ValueError("not an object")
    except (OSError, ValueError) as exc:
        print("%s|OPEN|unreadable shard (%s)" % (name, type(exc).__name__))
        continue
    why = terminal(r)
    if why is None:
        print("%s|OPEN|done=%s total=%s needs_source=%s complete=%s" % (
            name, r.get("done"), r.get("total"), bool(r.get("needs_source")), r.get("complete") is True))
    else:
        print("%s|TERMINAL|%s" % (name, why))
PY
}

run_probe() {
    local dir; dir="$(_settling_dir)"
    if [ ! -d "$dir" ]; then
        probe_cannot_run "no settling shard directory at $dir; nothing was measured, so the bar cannot be judged (this is not a pass)"
    fi
    local lines; lines="$(_classify_shards "$dir")" || probe_cannot_run "could not read $dir (python3 classifier failed)"
    local n open_list="" n_open=0 n_total=0
    n_total="$(printf '%s\n' "$lines" | /usr/bin/grep -c '|' || true)"
    probe_examined "$n_total" "settling shard(s) in $dir"
    if [ "$n_total" -eq 0 ]; then
        probe_cannot_run "settling directory $dir holds no shard files; nothing was measured (this is not a pass)"
    fi
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        probe_note "$line"
        case "$line" in
            *"|OPEN|"*)
                n_open=$((n_open + 1))
                open_list="${open_list}${open_list:+, }${line%%|*}" ;;
        esac
    done <<EOF
$lines
EOF
    if [ "$n_open" -gt 0 ]; then
        probe_fail "$n_open of $n_total settling source(s) never reached a terminal state, so the Setting-up bar cannot reach 100%: $open_list"
    fi
    probe_pass "all $n_total settling source(s) are terminal (complete, skipped with a reason, or measured done) in $dir"
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 3 "synthetic settling shards: a stalled contacts pass, a stalled emails backlog and a waiting notes channel (negative control)"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/settling_progress.d"
    # The Mini16 shape: a stalled measured pass, a stalled email backlog, and a
    # waiting channel with no work. All three must be OPEN.
    printf '%s\n' '{"key":"contacts","done":2398,"total":2443,"needs_source":false}' > "$tmp/settling_progress.d/contacts.json"
    printf '%s\n' '{"key":"emails","done":17080,"total":121262,"needs_source":false}' > "$tmp/settling_progress.d/emails.json"
    printf '%s\n' '{"key":"notes","done":0,"total":0,"needs_source":true}' > "$tmp/settling_progress.d/notes.json"
    local out; out="$(_classify_shards "$tmp/settling_progress.d")"
    rm -rf "$tmp"
    local open_n; open_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|OPEN|' || true)"
    if [ "$open_n" -ne 3 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the Mini16-shaped fixture classified $open_n of 3 shards as open. This probe cannot see the 71% defect."
    fi
    probe_fail "self-test: the known-bad fixture (contacts 2398/2443, emails 17080/121262, notes waiting with no work) classified as 3 OPEN shards, so this probe returns FAIL on it as it must"
}

probe_main "$@"
