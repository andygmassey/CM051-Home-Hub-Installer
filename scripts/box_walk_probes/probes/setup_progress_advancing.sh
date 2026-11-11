#!/usr/bin/env bash
# probes/setup_progress_advancing.sh
# ============================================================================
# QUESTION: over the walk's settle window, is every source in the Setting-up
#           denominator either TERMINAL or still ADVANCING?
#
# THE DENOMINATOR. The Hub's Setting-up percentage is done/total summed over
# the settling shards in state/settling_progress.d/<channel>.json (CM044
# compiler/hydration.py settling_progress). The bar cannot finish while a
# shard is open and not moving. Which writer owns which shard, and the exact
# terminal write for each, is in docs/setup_progress_terminal_map.md.
#
# WHY NOT "REACHES DONE". A large source (Mini16: emails 17080 of 121262) does
# not finish inside a walk, and a walk that waited for it would never end. The
# walk only needs to know the bar is MOVING where it is not finished, and that
# every finished source is recorded as finished.
#
# TERMINAL (per shard, at the end sample):
#   complete:true                    the writer finished this source
#   skip_reason:"<code>"             yielded nothing by design, or unreadable
#   total>0 and done>=total          all the work it measured is done
#   total==0 and needs_source false  nothing to measure, nothing queued
#
# ADVANCING (per shard, non-terminal): done at the END sample is strictly
# greater than done at the START sample. A shard that is absent at the start
# counts as done=0 there.
#
# PASS: every shard is terminal or advancing.
# FAIL: names every shard that is open and did not advance.
#
# THE WINDOW. Two samples, taken at the start and end of the walk's existing
# settle window. The window is OSTLER_STABILITY_INTERVAL_S (default 60 s, the
# same gap lib/converge_wait.sh already waits between store counts). This probe
# adds NO wait beyond that: it never waits for a bar to reach 100%.
#
# NO DIRECTORY = CANNOT-RUN, not PASS. Zero shards means nothing was measured.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="setup_progress_advancing"
PROBE_QUESTION="is every Setting-up source terminal or still advancing over the settle window?"

_settling_dir() {
    if [ -n "${OSTLER_SETTLING_DIR:-}" ]; then
        printf '%s' "$OSTLER_SETTLING_DIR"
    else
        printf '%s/settling_progress.d' "${OSTLER_STATE_DIR:-$HOME/.ostler/state}"
    fi
}

_settle_window_s() {
    local w="${OSTLER_STABILITY_INTERVAL_S:-60}"
    case "$w" in ''|*[!0-9]*) w=60 ;; esac
    printf '%s' "$w"
}

# Prints one line per shard in <dir>:
#   <file>|<done>|<total>|TERMINAL|<why>
#   <file>|<done>|<total>|OPEN|<why>
#   <file>|UNREADABLE|<why>
# Stdlib only, isolated mode. Exit 0 always; the caller reads the lines.
_snapshot() {
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
        done = int(r.get("done") or 0)
        total = int(r.get("total") or 0)
    except (OSError, ValueError, TypeError) as exc:
        print("%s|UNREADABLE|%s" % (name, type(exc).__name__))
        continue
    why = terminal(r)
    if why is None:
        print("%s|%d|%d|OPEN|needs_source=%s" % (name, done, total, bool(r.get("needs_source"))))
    else:
        print("%s|%d|%d|TERMINAL|%s" % (name, done, total, why))
PY
}

# _judge <start-snapshot> <end-snapshot>
# Prints one line per shard in the END snapshot:
#   <file>|PASS|<why>  or  <file>|FAIL|<why>
_judge() {
    python3 -I - "$1" "$2" <<'PY'
import sys

def parse(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("|")
                if not parts or not parts[0]:
                    continue
                out[parts[0]] = parts
    except OSError:
        pass
    return out

start = parse(sys.argv[1])
end = parse(sys.argv[2])

for name in sorted(end):
    p = end[name]
    if p[1] == "UNREADABLE":
        print("%s|FAIL|unreadable shard (%s): the reader skips it silently, so the bar would read high" % (name, p[2]))
        continue
    done_end, total_end = int(p[1]), int(p[2])
    if p[3] == "TERMINAL":
        print("%s|PASS|terminal (%s)" % (name, p[4]))
        continue
    s = start.get(name)
    done_start = int(s[1]) if (s and s[1] != "UNREADABLE") else 0
    if done_end > done_start:
        print("%s|PASS|advancing: done %d -> %d of %d" % (name, done_start, done_end, total_end))
    else:
        print("%s|FAIL|open and not advancing: done %d -> %d of %d (%s)" % (name, done_start, done_end, total_end, p[4]))
PY
}

run_probe() {
    local dir; dir="$(_settling_dir)"
    if [ ! -d "$dir" ]; then
        probe_cannot_run "no settling shard directory at $dir; nothing was measured, so the bar cannot be judged (this is not a pass)"
    fi

    local tmp; tmp="$(mktemp -d)" || probe_cannot_run "could not create a scratch directory for the two samples"
    local window; window="$(_settle_window_s)"

    local start_snap end_snap
    start_snap="$tmp/start.txt"; end_snap="$tmp/end.txt"
    _snapshot "$dir" > "$start_snap" || { rm -rf "$tmp"; probe_cannot_run "could not read $dir at the start sample (python3 classifier failed)"; }
    sleep "$window"
    _snapshot "$dir" > "$end_snap" || { rm -rf "$tmp"; probe_cannot_run "could not read $dir at the end sample (python3 classifier failed)"; }

    local verdicts; verdicts="$(_judge "$start_snap" "$end_snap")"
    local n_total open_fail="" n_fail=0
    n_total="$(printf '%s\n' "$verdicts" | /usr/bin/grep -c '|' || true)"
    probe_examined "$n_total" "settling shard(s) in $dir, sampled at start and after a ${window}s settle window"

    if [ "$n_total" -eq 0 ]; then
        rm -rf "$tmp"
        probe_cannot_run "settling directory $dir holds no shard files; nothing was measured (this is not a pass)"
    fi

    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        probe_note "$line"
        case "$line" in
            *"|FAIL|"*)
                n_fail=$((n_fail + 1))
                open_fail="${open_fail}${open_fail:+, }${line%%|*}" ;;
        esac
    done <<EOF
$verdicts
EOF
    rm -rf "$tmp"

    if [ "$n_fail" -gt 0 ]; then
        probe_fail "$n_fail of $n_total settling source(s) are open and did not advance in ${window}s: $open_fail"
    fi
    probe_pass "all $n_total settling source(s) are terminal or advancing over ${window}s in $dir"
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 3 "synthetic settling shards: a stalled contacts pass, a stalled emails backlog and a waiting notes channel (negative control)"
    local tmp; tmp="$(mktemp -d)"
    local a="$tmp/start" b="$tmp/end"
    mkdir -p "$a" "$b"
    # The stalled Mini16 shape: nothing moves between the two samples. Contacts
    # and emails are open and not advancing; notes has no work and no request.
    printf '%s\n' '{"key":"contacts","done":2398,"total":2443,"needs_source":false}' > "$a/contacts.json"
    printf '%s\n' '{"key":"emails","done":17080,"total":121262,"needs_source":false}' > "$a/emails.json"
    printf '%s\n' '{"key":"notes","done":0,"total":0,"needs_source":true}' > "$a/notes.json"
    cp "$a"/*.json "$b"/
    local sa="$tmp/s.start" sb="$tmp/s.end"
    _snapshot "$a" > "$sa"; _snapshot "$b" > "$sb"
    local out; out="$(_judge "$sa" "$sb")"
    local fail_n; fail_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|FAIL|' || true)"
    rm -rf "$tmp"
    if [ "$fail_n" -ne 3 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the stalled fixture produced $fail_n FAIL verdicts, not 3. This probe cannot see a stalled bar."
    fi
    probe_fail "self-test: the stalled fixture (contacts 2398/2443 and emails 17080/121262 unmoved, notes waiting with no work) gave 3 FAIL verdicts, so this probe returns FAIL on it as it must"
}

probe_main "$@"
