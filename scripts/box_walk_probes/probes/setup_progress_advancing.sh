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
#   contacts  INSTALL-ONLY (install.sh:36416). com.ostler.contact-resync (1800 s,
#             install.sh:36267) does NOT write it: bin/ostler-contact-resync
#             (install.sh:26748-26931) and oa release/ingest-ticks/contact-resync/
#             tick.sh carry no settling write, and the vendored syncer has none
#             (vendor/divergences/cm041_contact_syncer.UNRECORDED.md:336-339).
# The fda-rerun chain (traced): the plist runs `ostler-assistant run-source
# fda-rerun` (install.sh:21386), hub-v0.5.37 main.rs RunSource runs
# Resources/ingest/fda-rerun/tick.sh (bash, env inherited), the sealed tick execs
# ~/.ostler/bin/ostler-fda, which install.sh:26032 writes to run extract_all
# with the venv python. install.sh:9880 states the same chain.
# An OPEN install-only channel is FAIL (no writer can complete it). A channel
# with no label in the map, a missing plist or an unreadable plist is CANNOT-RUN
# for that channel, with the plist path printed. complete=true needs no interval.
#
# NO DIRECTORY = CANNOT-RUN, not PASS. Zero shards means nothing was measured.
#
# WHERE IT READS. Every read (the settling directory, the manifest, the shards,
# the writer plists) happens ON THE BOX, through box_run_v: ssh when
# OSTLER_BOX_HOST is set, this machine when it is unset. The box's HOME is read
# first, and every path is built from it. The driver's own ~/.ostler is never
# consulted. The v1.0.130 walk judged the driver's stale ~/.ostler, found no
# manifest there, and FAILed a box whose manifest had been present since install.
# A box that does not answer is CANNOT-RUN, never PASS or FAIL.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="setup_progress_advancing"
PROBE_QUESTION="is every Setting-up source terminal or still advancing over the settle window?"

# Absolute path of this file, for the self-test to re-run it as a child process.
_PROBE_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The box's own HOME. Set by run_probe (or by the self-test) before any path is
# built. Never the driver's HOME.
_PROBE_BOX_HOME=""

# Scratch directory for the run's sample files. Set by run_probe.
_PROBE_TMP=""

# _sq <string>: single-quote a string for the box's shell.
_sq() {
    local out
    out="$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
    printf "'%s'" "$out"
}

# _box_sh_to <outfile> <command>: run a shell command on the box, stdin closed.
# stdout to <outfile>, stderr to <outfile>.err. Returns the transport's exit code.
_box_sh_to() {
    box_run_v "$2" </dev/null > "$1" 2> "$1.err"
}

# _box_py_to <outfile> <quoted args>: run the python program read from THIS
# function's stdin (a heredoc at the call site) on the box. stdout to <outfile>,
# stderr to <outfile>.err. Returns the transport's exit code.
_box_py_to() {
    box_run_v "python3 -I - $2" > "$1" 2> "$1.err"
}

# _box_cannot <what> <stderr-file>: the box could not be read. CANNOT-RUN, with
# the transport's own first line of stderr as the reason. Never a PASS or FAIL.
# <stderr-file> is the transport's stderr file (the call's outfile plus .err).
_box_cannot() {
    local why
    why="$(head -n 1 "$2")"
    _probe_cleanup
    probe_cannot_run "$1 (box ${OSTLER_BOX_HOST:-this machine}; transport said: ${why:-nothing on stderr}). Nothing was measured, so this is not a pass"
}

_probe_cleanup() {
    if [ -n "${_PROBE_TMP}" ] && [ -d "${_PROBE_TMP}" ]; then rm -rf "${_PROBE_TMP}"; fi
}

# The settling shard directory, ON THE BOX.
_settling_dir() {
    if [ -n "${OSTLER_SETTLING_DIR:-}" ]; then
        printf '%s' "$OSTLER_SETTLING_DIR"
    else
        printf '%s/settling_progress.d' "${OSTLER_STATE_DIR:-$_PROBE_BOX_HOME/.ostler/state}"
    fi
}

# The fixed channel set the bar divides by. install.sh must place it at
# ~/.ostler/state/settling_channels.json (CM051 #3426) on the box; the wiki
# compiler reads it from there. Absent, CM044 logs "settling channel manifest
# ABSENT" and uses a built-in fallback, so the denominator silently stops being
# CM051's list.
_manifest_path() {
    if [ -n "${OSTLER_SETTLING_MANIFEST:-}" ]; then
        printf '%s' "$OSTLER_SETTLING_MANIFEST"
    else
        printf '%s/settling_channels.json' "$(dirname "$1")"
    fi
}

# The LaunchAgents directory, ON THE BOX.
_launchagents_dir() {
    if [ -n "${OSTLER_LAUNCHAGENTS_DIR:-}" ]; then
        printf '%s' "$OSTLER_LAUNCHAGENTS_DIR"
    else
        printf '%s/Library/LaunchAgents' "$_PROBE_BOX_HOME"
    fi
}

# _manifest_verdict <manifest path on the box> <outfile>
# Writes OK|<comma list of channels> or MISSING|<why>, read ON THE BOX.
_manifest_verdict() {
    _box_py_to "$2" "$(_sq "$1")" <<'PY'
import json, os, sys
m = sys.argv[1]
if not os.path.isfile(m):
    print("MISSING|settling_channels.json is absent at %s on the box; install.sh never placed it (CM051 #3453), so the bar divides by a built-in fallback and this probe will not guess a list" % m)
    sys.exit(0)
try:
    with open(m, encoding="utf-8") as fh:
        ch = json.load(fh)["channels"]
    if not isinstance(ch, list) or not ch or not all(isinstance(c, str) and c for c in ch):
        raise ValueError("channels is empty or not a list of names")
    print("OK|" + ",".join(ch))
except (OSError, ValueError, KeyError, TypeError) as exc:
    print("MISSING|settling_channels.json at %s on the box is unusable (%s)" % (m, type(exc).__name__))
PY
}

_settle_window_s() {
    local w="${OSTLER_STABILITY_INTERVAL_S:-60}"
    case "$w" in ''|*[!0-9]*) w=60 ;; esac
    printf '%s' "$w"
}

# The launchd job whose tick writes a channel's shard. Empty = no periodic writer.
_writer_label() {
    case "$1" in
        emails)   printf 'com.creativemachines.ostler.email-ingest' ;;
        calendar) printf 'com.ostler.fda-rerun' ;;
        messages) printf 'com.ostler.fda-rerun' ;;
        contacts) printf 'INSTALL_ONLY' ;;
    esac
}

# _tick_intervals <channels,...> <outfile>
# One line per channel, plist read ON THE BOX:
#   <channel>=<seconds>|<plist path>          the writer's StartInterval
#   <channel>=CANNOT|<why, with the path>     no label, no plist, or unreadable
#   <channel>=INSTALLONLY|<why>               written once at install
# Returns non-zero if the box could not be read for a plist.
_tick_intervals() {
    local ch label plist agents rc
    agents="$(_launchagents_dir)"
    : > "$2"
    for ch in $(printf '%s' "$1" | tr ',' ' '); do
        label="$(_writer_label "$ch")"
        if [ "$label" = "INSTALL_ONLY" ]; then
            printf '%s=INSTALLONLY|channel %s is written once at install (install.sh:36416); no periodic job writes it\n' "$ch" "$ch" >> "$2"
            continue
        fi
        if [ -z "$label" ]; then
            printf '%s=CANNOT|channel %s has no launchd writer label in the probe map (written at install time only or unmapped)\n' "$ch" "$ch" >> "$2"
            continue
        fi
        plist="$agents/$label.plist"
        _box_py_to "$2.one" "$(_sq "$ch") $(_sq "$plist") $(_sq "$label")" <<'PY'
import os, plistlib, sys
ch, path, label = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.isfile(path):
    print("%s=CANNOT|no plist at %s on the box (writer %s), so its tick interval is unknown" % (ch, path, label))
    sys.exit(0)
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
        rc=$?
        if [ "$rc" -ne 0 ]; then
            return "$rc"
        fi
        cat "$2.one" >> "$2"
    done
    rm -f "$2.one"
    return 0
}

# _snapshot <dir on the box> <outfile>
# One line per shard in <dir>, read ON THE BOX:
#   <file>|<done>|<total>|TERMINAL|<why>|<updated epoch>
#   <file>|<done>|<total>|OPEN|<why>|<updated epoch>
#   <file>|UNREADABLE|<why>
# Returns the transport's exit code. A python failure is non-zero too.
_snapshot() {
    _box_py_to "$2" "$(_sq "$1")" <<'PY'
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
# Local: judges the two samples the box returned. Prints one line per shard in
# the END snapshot:
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
                intervals[k] = (int(v), why) if v.isdigit() else (v, why)
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
    if iv == "INSTALLONLY":
        print("%s|FAIL|open with no writer that can complete it (written once at install.sh:36416): done %d of %d" % (name, done_end, total_end))
        continue
    if not isinstance(iv, int):
        print("%s|CANNOT|%s" % (name, ivt[1]))
        continue
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
PY
}

run_probe() {
    _PROBE_TMP="$(mktemp -d)" || probe_cannot_run "could not create a scratch directory for the samples"
    local tmp="${_PROBE_TMP}"

    # 1. THE BOX'S HOME. Also the reachability check: if the box does not
    #    answer, nothing below can be measured, and that is CANNOT-RUN.
    if ! _box_sh_to "$tmp/home" 'printf %s "$HOME"'; then
        _box_cannot "the box did not answer, so the Setting-up bar was not read" "$tmp/home.err"
    fi
    _PROBE_BOX_HOME="$(cat "$tmp/home")"
    if [ -z "${_PROBE_BOX_HOME}" ]; then
        _box_cannot "the box answered with an empty HOME" "$tmp/home.err"
    fi

    # 2. THE SHARD DIRECTORY, on the box.
    local dir; dir="$(_settling_dir)"
    if ! _box_sh_to "$tmp/dir" "if [ -d $(_sq "$dir") ]; then printf DIR; else printf NODIR; fi"; then
        _box_cannot "could not look for the settling directory $dir on the box" "$tmp/dir.err"
    fi
    if [ "$(cat "$tmp/dir")" != "DIR" ]; then
        _probe_cleanup
        probe_cannot_run "no settling shard directory at $dir on the box; nothing was measured, so the bar cannot be judged (this is not a pass)"
    fi

    # 2b. THE START SAMPLE, on the box, taken first so the settle window starts
    #     with the first read. The shards do not depend on the manifest.
    local window; window="$(_settle_window_s)"
    if ! _snapshot "$dir" "$tmp/start.txt"; then
        _box_cannot "could not read the shards in $dir on the box at the start sample (python3 failed there)" "$tmp/start.txt.err"
    fi

    # 3. THE MANIFEST, on the box. Absent or unusable is a FAIL (the #3453 check).
    local mpath mv channels
    mpath="$(_manifest_path "$dir")"
    if ! _manifest_verdict "$mpath" "$tmp/mv"; then
        _box_cannot "could not read the settling manifest $mpath on the box" "$tmp/mv.err"
    fi
    mv="$(cat "$tmp/mv")"
    case "$mv" in
        OK\|*) channels="${mv#OK|}" ;;
        *) probe_examined 1 "settling_channels.json at $mpath on the box"
           _probe_cleanup
           probe_fail "${mv#MISSING|}" ;;
    esac
    probe_note "judging the channels in $mpath on the box: $channels"

    # 4. THE WRITER PLISTS, on the box.
    if ! _tick_intervals "$channels" "$tmp/intervals.txt"; then
        _box_cannot "could not read the writer plists under $(_launchagents_dir) on the box" "$tmp/intervals.txt.one.err"
    fi
    local iv_line
    while IFS= read -r iv_line; do
        [ -n "$iv_line" ] || continue
        case "${iv_line#*=}" in
            CANNOT\|*) probe_note "writer of ${iv_line%%=*}: interval unknown (${iv_line#*|})" ;;
            INSTALLONLY\|*) probe_note "writer of ${iv_line%%=*}: install-only (${iv_line#*|})" ;;
            *) probe_note "writer of ${iv_line%%=*}: StartInterval=${iv_line#*=} (freshness window is 2x this)" ;;
        esac
    done < "$tmp/intervals.txt"

    # 5. THE END SAMPLE, after the settle window. The start sample was taken above,
    #    before the manifest and plist reads, so the window starts at the first sample.
    sleep "$window"
    if ! _snapshot "$dir" "$tmp/end.txt"; then
        _box_cannot "could not read the shards in $dir on the box at the end sample (python3 failed there)" "$tmp/end.txt.err"
    fi

    local verdicts; verdicts="$(_judge "$tmp/start.txt" "$tmp/end.txt" "$channels" "$tmp/intervals.txt")"
    local n_total n_info open_fail="" n_fail=0 n_cannot=0 cannot_list=""
    n_total="$(printf '%s\n' "$verdicts" | /usr/bin/grep -c -E '\|(PASS|FAIL|CANNOT)\|' || true)"
    n_info="$(printf '%s\n' "$verdicts" | /usr/bin/grep -c '|INFO|' || true)"
    probe_examined "$n_total" "judged settling shard(s) of the manifest channels in $dir on the box, sampled at start and after a ${window}s settle window ($n_info other shard(s) listed, not judged)"

    if [ "$n_total" -eq 0 ]; then
        _probe_cleanup
        probe_cannot_run "no shard in $dir on the box belongs to a manifest channel ($channels); nothing was measured (this is not a pass)"
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
    _probe_cleanup

    if [ "$n_fail" -gt 0 ]; then
        probe_fail "$n_fail of $n_total settling source(s) on the box are open and not advancing (${window}s window; hourly writers by freshness): $open_fail"
    fi
    if [ "$n_cannot" -gt 0 ]; then
        probe_cannot_run "$n_cannot of $n_total judged settling source(s) are open and have no known writer interval, so freshness cannot be judged (not a pass): $cannot_list; see the CANNOT lines for the plist path looked for"
    fi
    probe_pass "all $n_total judged settling source(s) on the box are terminal or fresh in $dir"
}

self_test() {
    SELF_TEST_LOCAL=1
    # The local arms below must not inherit a box from the caller's environment.
    unset OSTLER_BOX_HOST
    probe_examined 4 "synthetic settling shards: stale contacts and emails shards (3h old, hourly writers), a waiting notes channel (not in the manifest, must NOT be judged) and a calendar shard whose writer interval is unknown (must read CANNOT)"

    local root; root="$(mktemp -d)" || probe_cannot_run "self-test: no scratch directory"
    local box="$root/box" drv="$root/driver" stub="$root/stub" log="$root/ssh.log"
    mkdir -p "$box/.ostler/state/settling_progress.d" "$box/Library/LaunchAgents" "$drv" "$stub"

    # THE BOX-ONLY FIXTURE. The box's HOME holds the manifest, the shards and the
    # writer plist. The driver's HOME ($drv) is EMPTY: no manifest, no shards.
    # A probe that reads the driver judges MISSING and FAILs, so a PASS here can
    # only come from reading the box.
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"channels":["emails","contacts"]}\n' > "$box/.ostler/state/settling_channels.json"
    printf '{"key":"emails","done":100,"total":1000,"needs_source":false,"updated_at":"%s"}\n' "$now" > "$box/.ostler/state/settling_progress.d/emails.json"
    printf '{"key":"contacts","done":5,"total":5,"complete":true,"updated_at":"%s"}\n' "$now" > "$box/.ostler/state/settling_progress.d/contacts.json"
    cat > "$box/Library/LaunchAgents/com.creativemachines.ostler.email-ingest.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>StartInterval</key><integer>3600</integer></dict></plist>
PL

    # THE STUB SSH. Records the remote command, then runs it under the BOX's
    # HOME, with stdin passed through. SSH_STUB_MODE=dead makes it refuse.
    cat > "$stub/ssh" <<'STUB'
#!/bin/bash
cmd=""
for a in "$@"; do cmd="$a"; done
printf '%s\n' "$cmd" >> "${SSH_STUB_LOG}"
if [ "${SSH_STUB_MODE:-}" = "dead" ]; then
    printf 'ssh: connect to host stub-box port 22: Operation timed out\n' >&2
    exit 255
fi
exec env HOME="${STUB_BOX_HOME}" /bin/bash -c "$cmd"
STUB
    chmod +x "$stub/ssh"

    local fails=""
    local stub_path="$stub:/usr/bin:/bin:/usr/sbin:/sbin"

    # ARM B. Driver has no manifest, the box has one: PASS on the box's data.
    local outB rcB
    outB="$(env -i PATH="$stub_path" HOME="$drv" OSTLER_BOX_HOST=stub-box STUB_BOX_HOME="$box" SSH_STUB_LOG="$log" OSTLER_STABILITY_INTERVAL_S=0 /bin/bash "$_PROBE_SELF" 2>&1)"; rcB=$?
    if [ "$rcB" -ne 0 ] || ! /usr/bin/grep -q 'VERDICT: PASS' <<< "$outB"; then
        fails="${fails}; box-only fixture: want rc 0 and VERDICT: PASS, got rc ${rcB}: $(printf '%s' "$outB" | tr '\n' ' ' | cut -c1-400)"
    elif ! /usr/bin/grep -q 'settling_progress.d' "$log" 2>/dev/null; then
        fails="${fails}; box-only fixture: PASS, but the ssh stub recorded no read of the box's shard directory, so the verdict cannot be credited to the box"
    fi

    # ARM C. Box does not answer: CANNOT-RUN (78), never PASS or FAIL.
    local outC rcC
    outC="$(env -i PATH="$stub_path" HOME="$drv" OSTLER_BOX_HOST=stub-box STUB_BOX_HOME="$box" SSH_STUB_MODE=dead SSH_STUB_LOG="$log" OSTLER_STABILITY_INTERVAL_S=0 /bin/bash "$_PROBE_SELF" 2>&1)"; rcC=$?
    if [ "$rcC" -ne 78 ] || ! /usr/bin/grep -q 'VERDICT: CANNOT-RUN' <<< "$outC"; then
        fails="${fails}; unreachable box: want rc 78 and VERDICT: CANNOT-RUN, got rc ${rcC}: $(printf '%s' "$outC" | tr '\n' ' ' | cut -c1-400)"
    fi

    # ARM D. No OSTLER_BOX_HOST: the same probe reads THIS machine's HOME.
    local outD rcD
    outD="$(env -i PATH=/usr/bin:/bin HOME="$box" OSTLER_STABILITY_INTERVAL_S=0 /bin/bash "$_PROBE_SELF" 2>&1)"; rcD=$?
    if [ "$rcD" -ne 0 ] || ! /usr/bin/grep -q 'VERDICT: PASS' <<< "$outD"; then
        fails="${fails}; box-local run (no OSTLER_BOX_HOST): want rc 0 and VERDICT: PASS, got rc ${rcD}: $(printf '%s' "$outD" | tr '\n' ' ' | cut -c1-400)"
    fi

    if [ -n "$fails" ]; then
        rm -rf "$root"
        probe_cannot_run "SELF-TEST ARM FAILED, so the box read is not demonstrated: ${fails#; }"
    fi

    # ARM E. The original negative control: a stalled fixture must FAIL.
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/d"
    local old='2000-01-01T00:00:00+00:00'
    printf '{"key":"contacts","done":2398,"total":2443,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/contacts.json"
    printf '{"key":"emails","done":17080,"total":121262,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/emails.json"
    printf '{"key":"calendar","done":10,"total":50,"needs_source":false,"updated_at":"%s"}\n' "$old" > "$tmp/d/calendar.json"
    printf '%s\n' '{"key":"notes","done":0,"total":0,"needs_source":true}' > "$tmp/d/notes.json"
    local sa="$tmp/s"
    _snapshot "$tmp/d" "$sa"
    printf 'contacts=3600|x\nemails=3600|x\ncalendar=CANNOT|no plist\n' > "$tmp/iv.txt"
    local out; out="$(_judge "$sa" "$sa" "contacts,calendar,messages,emails" "$tmp/iv.txt")"
    local fail_n info_n cannot_n
    fail_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|FAIL|not advancing' || true)"
    info_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|INFO|' || true)"
    cannot_n="$(printf '%s\n' "$out" | /usr/bin/grep -c '|CANNOT|' || true)"
    if [ "$fail_n" -ne 2 ] || [ "$info_n" -ne 1 ] || [ "$cannot_n" -ne 1 ]; then
        rm -rf "$tmp" "$root"
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: the stalled fixture gave $fail_n FAIL (want 2), $info_n INFO (want 1, notes), $cannot_n CANNOT (want 1, calendar). This probe cannot see a stalled bar."
    fi
    # A manifest that is absent on the box is MISSING, never a fallback list.
    _manifest_verdict "$tmp/no-such-dir/settling_channels.json" "$tmp/nm"
    local nm; nm="$(cat "$tmp/nm")"
    rm -rf "$tmp" "$root"
    case "$nm" in
        MISSING\|*) ;;
        *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: an absent settling_channels.json read as: $nm" ;;
    esac
    probe_fail "self-test: the box-only fixture PASSes on the box's data, an unreachable box is CANNOT-RUN, and the stalled fixture gives 2 FAIL (stale hourly shards), 1 INFO (notes) and 1 CANNOT (unknown interval)"
}

probe_main "$@"
