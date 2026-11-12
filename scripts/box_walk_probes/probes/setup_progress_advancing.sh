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
# TERMINAL (per shard, at the end sample). ONLY an explicit marker:
#   complete:true                    the writer finished this source
#   skip_reason:"<code>"             yielded nothing by design, or unreadable
# A count that reaches its total WITHOUT a marker is OPEN, and so is 0/0: a
# producer that has not yet discovered its work has not finished, and reading
# it as terminal let the bar touch 100% and fall back (tests/test_settling_zero_is_discovering.sh).
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
# WHAT IS JUDGED. Only the channels in settling_channels.json (the bar's fixed
# denominator, installed beside the shard directory). A shard file is judged when
# its stem IS a channel, or is "messages.<source>" (the one sub-sharded channel).
# Every other shard (notes, emails.history, today) is printed as INFO and never
# judged: the bar does not count it, so it cannot hold the bar. The manifest
# absent or unusable is a FAIL (the #3453 wiring check), never a fallback list.
#
# CADENCE PER CHANNEL. A shard is written when its writer's launchd job ticks,
# so an OPEN shard cannot move in a 60 s window whatever its health. It is
# judged on FRESHNESS: updated_at (the shard's own claim, not file mtime) within
# 2x the StartInterval of THAT channel's writer plist, and done not decreased;
# older is FAIL "not advancing". The done-delta is printed as extra evidence and
# is never a substitute. The channel-to-launchd-label map is _writer_label:
#   emails    com.creativemachines.ostler.email-ingest  (hourly tick)
#   calendar  com.ostler.fda-rerun  (extract_all.py:588 -> calendar.py:96)
#   messages  com.ostler.fda-rerun  (imessage.py:192, whatsapp_history.py:121)
#   contacts  no periodic writer (install.sh:36416, install time only)
# A channel with no label, a missing plist or an unreadable plist is CANNOT-RUN
# for that channel, with the plist path printed. complete=true needs no interval.
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

_manifest_path() {
    if [ -n "${OSTLER_SETTLING_MANIFEST:-}" ]; then
        printf '%s' "$OSTLER_SETTLING_MANIFEST"
    else
        printf '%s/settling_channels.json' "$(dirname "$1")"
    fi
}

# Prints OK|<comma list of channels> or MISSING|<why>.
_manifest_verdict() {
    local m="$1"
    if [ ! -f "$m" ]; then
        printf 'MISSING|settling_channels.json is absent at %s; install.sh never placed it (CM051 #3453), so the bar divides by a built-in fallback and this probe will not guess a list' "$m"
        return 0
    fi
    python3 -I - "$m" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        ch = json.load(fh)["channels"]
    if not isinstance(ch, list) or not ch or not all(isinstance(c, str) and c for c in ch):
        raise ValueError("channels is empty or not a list of names")
    print("OK|" + ",".join(ch))
except (OSError, ValueError, KeyError, TypeError) as exc:
    print("MISSING|settling_channels.json at %s is unusable (%s)" % (sys.argv[1], type(exc).__name__))
PY
}

# The launchd job whose tick writes a channel's shard. Empty = no periodic writer.
_writer_label() {
    case "$1" in
        emails)   printf 'com.creativemachines.ostler.email-ingest' ;;
        calendar) printf 'com.ostler.fda-rerun' ;;
        messages) printf 'com.ostler.fda-rerun' ;;
    esac
}

# _tick_intervals <channels,...>: one line per channel:
#   <channel>=<seconds>|<plist path>          the writer's StartInterval
#   <channel>=CANNOT|<why, with the path>     no label, no plist, or unreadable
_tick_intervals() {
    local ch label plist agents="${OSTLER_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
    for ch in $(printf '%s' "$1" | tr ',' ' '); do
        label="$(_writer_label "$ch")"
        if [ -z "$label" ]; then
            printf '%s=CANNOT|channel %s has no launchd writer label in the probe map (written at install time only or unmapped)\n' "$ch" "$ch"
            continue
        fi
        plist="$agents/$label.plist"
        if [ ! -f "$plist" ]; then
            printf '%s=CANNOT|no plist at %s (writer %s), so its tick interval is unknown\n' "$ch" "$plist" "$label"
            continue
        fi
        python3 -I - "$ch" "$plist" <<'PY'
import plistlib, sys
ch, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as fh:
        v = plistlib.load(fh).get("StartInterval")
    if isinstance(v, int) and not isinstance(v, bool) and v > 0:
        print("%s=%d|%s" % (ch, v, path))
    else:
        print("%s=CANNOT|plist %s has no positive StartInterval" % (ch, path))
except Exception as exc:
    print("%s=CANNOT|plist %s is unreadable (%s)" % (ch, path, type(exc).__name__))
PY
    done
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

def epoch(r):
    from datetime import datetime, timezone
    u = r.get("updated_at")
    if not isinstance(u, str) or not u.strip():
        return 0
    try:
        t = datetime.fromisoformat(u.strip().replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        return int(t.timestamp())
    except ValueError:
        return 0

def terminal(r):
    reason = r.get("skip_reason")
    if isinstance(reason, str) and reason.strip():
        return "skipped: " + reason.strip()
    if r.get("complete") is True:
        return "complete"
    done = int(r.get("done") or 0)
    total = int(r.get("total") or 0)
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
        print("%s|%d|%d|OPEN|needs_source=%s|%d" % (name, done, total, bool(r.get("needs_source")), epoch(r)))
    else:
        print("%s|%d|%d|TERMINAL|%s|%d" % (name, done, total, why, epoch(r)))
PY
}

# _judge <start-snapshot> <end-snapshot> <channels,...> <intervals-file>
# Prints one line per shard in the END snapshot:
#   <file>|PASS|<why>, <file>|FAIL|<why>, <file>|CANNOT|<why> (no interval), or
#   <file>|INFO|<why> (not judged).
_judge() {
    python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys, time

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
channels = [c for c in sys.argv[3].split(",") if c]
intervals = {}
try:
    with open(sys.argv[4], encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            head, _, why = line.partition("|")
            if "=" in head:
                k, v = head.split("=", 1)
                intervals[k] = (int(v), why) if v.isdigit() else (None, why)
except (OSError, ValueError):
    pass
now = int(time.time())

def channel_of(fname):
    stem = fname[:-5] if fname.endswith(".json") else fname
    if stem in channels:
        return stem
    if stem.startswith("messages.") and "messages" in channels:
        return "messages"
    return None

for name in sorted(end):
    ch = channel_of(name)
    p = end[name]
    if ch is None:
        print("%s|INFO|not in settling_channels.json, so the bar does not count it and this probe does not judge it" % name)
        continue
    if p[1] == "UNREADABLE":
        print("%s|FAIL|unreadable shard (%s): the reader skips it silently, so the bar would read high" % (name, p[2]))
        continue
    done_end, total_end = int(p[1]), int(p[2])
    if p[3] == "TERMINAL":
        print("%s|PASS|terminal (%s)" % (name, p[4]))
        continue
    s = start.get(name)
    done_start = int(s[1]) if (s and s[1] != "UNREADABLE") else 0
    upd = int(p[5]) if len(p) > 5 else 0
    ivt = intervals.get(ch, (None, "channel %s has no entry in the interval table" % ch))
    iv = ivt[0]
    if iv is None:
        print("%s|CANNOT|%s" % (name, ivt[1]))
        continue
    if True:
        age = now - upd if upd else None
        if done_end < done_start:
            print("%s|FAIL|done went backwards %d -> %d of %d; the bar must never fall" % (name, done_start, done_end, total_end))
        elif age is None:
            print("%s|FAIL|not advancing: open with no readable updated_at, so freshness against the %ds tick cannot be shown (done %d of %d)" % (name, iv, done_end, total_end))
        elif age <= 2 * iv:
            extra = "; done %d -> %d" % (done_start, done_end) if done_end > done_start else "; done unchanged in the window"
            print("%s|PASS|fresh: updated %ds ago, within 2x the %ds tick (%d of %d)%s" % (name, age, iv, done_end, total_end, extra))
        else:
            print("%s|FAIL|not advancing: updated %ds ago, older than 2x the %ds tick (done %d of %d)" % (name, age, iv, done_end, total_end))
        continue
PY
}

run_probe() {
    local dir; dir="$(_settling_dir)"
    if [ ! -d "$dir" ]; then
        probe_cannot_run "no settling shard directory at $dir; nothing was measured, so the bar cannot be judged (this is not a pass)"
    fi

    local mpath mv channels
    mpath="$(_manifest_path "$dir")"
    mv="$(_manifest_verdict "$mpath")"
    case "$mv" in
        OK\|*) channels="${mv#OK|}" ;;
        *) probe_examined 1 "settling_channels.json at $mpath"
           probe_fail "${mv#MISSING|}" ;;
    esac
    probe_note "judging the channels in $mpath: $channels"

    local tmp; tmp="$(mktemp -d)" || probe_cannot_run "could not create a scratch directory for the two samples"
    local window; window="$(_settle_window_s)"

    _tick_intervals "$channels" > "$tmp/intervals.txt"
    local iv_line
    while IFS= read -r iv_line; do
        [ -n "$iv_line" ] || continue
        case "${iv_line#*=}" in
            CANNOT\|*) probe_note "writer of ${iv_line%%=*}: interval unknown (${iv_line#*|})" ;;
            *) probe_note "writer of ${iv_line%%=*}: StartInterval=${iv_line#*=} (freshness window is 2x this)" ;;
        esac
    done < "$tmp/intervals.txt"

    local start_snap end_snap
    start_snap="$tmp/start.txt"; end_snap="$tmp/end.txt"
    _snapshot "$dir" > "$start_snap" || { rm -rf "$tmp"; probe_cannot_run "could not read $dir at the start sample (python3 classifier failed)"; }
    sleep "$window"
    _snapshot "$dir" > "$end_snap" || { rm -rf "$tmp"; probe_cannot_run "could not read $dir at the end sample (python3 classifier failed)"; }

    local verdicts; verdicts="$(_judge "$start_snap" "$end_snap" "$channels" "$tmp/intervals.txt")"
    local n_total n_info open_fail="" n_fail=0 n_cannot=0 cannot_list=""
    n_total="$(printf '%s\n' "$verdicts" | /usr/bin/grep -c -E '\|(PASS|FAIL|CANNOT)\|' || true)"
    n_info="$(printf '%s\n' "$verdicts" | /usr/bin/grep -c '|INFO|' || true)"
    probe_examined "$n_total" "judged settling shard(s) of the manifest channels in $dir, sampled at start and after a ${window}s settle window ($n_info other shard(s) listed, not judged)"

    if [ "$n_total" -eq 0 ]; then
        rm -rf "$tmp"
        probe_cannot_run "no shard in $dir belongs to a manifest channel ($channels); nothing was measured (this is not a pass)"
    fi

    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        probe_note "$line"
        case "$line" in
            *"|FAIL|"*)
                n_fail=$((n_fail + 1))
                open_fail="${open_fail}${open_fail:+, }${line%%|*}" ;;
            *"|CANNOT|"*)
                n_cannot=$((n_cannot + 1))
                cannot_list="${cannot_list}${cannot_list:+, }${line%%|*}" ;;
        esac
    done <<VERDICTS
$verdicts
VERDICTS
    rm -rf "$tmp"

    if [ "$n_fail" -gt 0 ]; then
        probe_fail "$n_fail of $n_total settling source(s) are open and not advancing (${window}s window; hourly writers by freshness): $open_fail"
    fi
    if [ "$n_cannot" -gt 0 ]; then
        probe_cannot_run "$n_cannot of $n_total judged settling source(s) are open and have no known writer interval, so freshness cannot be judged (not a pass): $cannot_list; see the CANNOT lines for the plist path looked for"
    fi
    probe_pass "all $n_total judged settling source(s) are terminal or fresh in $dir"
}

self_test() {
    SELF_TEST_LOCAL=1
    probe_examined 4 "synthetic settling shards: stale contacts and emails shards (3h old, hourly writers), a waiting notes channel (not in the manifest, must NOT be judged) and a calendar shard whose writer interval is unknown (must read CANNOT)"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/d"
    local old='2000-01-01T00:00:00+00:00'
    printf '{"key":"contacts","done":2398,"total":2443,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/contacts.json"
    printf '{"key":"emails","done":17080,"total":121262,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/emails.json"
    printf '{"key":"calendar","done":10,"total":50,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/calendar.json"
    printf '%s\n' '{"key":"notes","done":0,"total":0,"needs_source":true}' > "$tmp/d/notes.json"
    local sa="$tmp/s"
    _snapshot "$tmp/d" > "$sa"
    printf 'contacts=3600|x\nemails=3600|x\ncalendar=CANNOT|no plist\n' > "$tmp/iv.txt"
    local out; out="$(_judge "$sa" "$sa" "contacts,calendar,messages,emails" "$tmp/iv.txt")"
    local fail_n info_n cannot_n
    fail_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|FAIL|not advancing' || true)"
    info_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|INFO|' || true)"
    cannot_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|CANNOT|' || true)"
    rm -rf "$tmp"
    if [ "$fail_n" -ne 2 ] || [ "$info_n" -ne 1 ] || [ "$cannot_n" -ne 1 ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the stalled fixture gave $fail_n FAIL (want 2), $info_n INFO (want 1, notes), $cannot_n CANNOT (want 1, calendar). This probe cannot see a stalled bar."
    fi
    probe_fail "self-test: the stalled fixture gave 2 FAIL (stale hourly shards), 1 INFO (notes) and 1 CANNOT (unknown interval), so this probe returns FAIL on it as it must"
}

probe_main "$@"
