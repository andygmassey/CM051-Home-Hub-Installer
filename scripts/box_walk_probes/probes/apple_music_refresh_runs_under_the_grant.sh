#!/usr/bin/env bash
# apple_music_refresh_runs_under_the_grant -- does the SCHEDULED Apple Music
# refresh read the library under the grant the customer gave the installer?
# (CM051 v1.0.108, Andy 2026-10-15, "please don't let that slip")
#
# Apple Music used to refresh at install only. The refresh is now a LaunchAgent
# whose program is the signed installer app (--music-refresh); the app runs the
# same signed helper as a child. Whether macOS attributes that read to the app
# and answers from the existing grant is INFERRED, not measured
# (docs/APPLE_MUSIC_REFRESH_TCC.md). This probe is the measurement. It reads
# what the agent itself recorded; RunAtLoad makes the agent read once at
# bootstrap, so a granted console install carries last_status ok within minutes.
#
#   PASS        both agents loaded, and the scheduled read succeeded
#   FAIL        armed but not scheduled or not loaded; or the scheduled read was
#               REFUSED (the grant did not carry: the design must change)
#   CANNOT-RUN  "TCC: ..." the install never got the grant, so nothing was
#               scheduled (correct); only the console walk can click Allow.
#               Listed in console_only_probes.tsv.
#
# Counts only. No title, artist or playlist name is read or printed.
#
# WALK_READ_ONLY: stats two files, reads one JSON file, and runs `launchctl print`
# (read-only) for two labels.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="apple_music_refresh_runs_under_the_grant"
PROBE_QUESTION="is the scheduled Apple Music refresh armed, loaded, and did its own read succeed under the installer's grant? CANNOT-RUN, saying TCC, when the install never got the grant."

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/apple_music_refresh_probe.py" --self-test; then
        probe_examined 9 "Apple Music refresh judge fixtures"
        probe_pass "SELF-TEST BROKEN: the refresh judge let a known-bad fixture through"
    fi
    probe_examined 9 "Apple Music refresh judge fixtures"
    probe_fail "negative controls behaved: not armed, armed but unscheduled, a missing plist, an unloaded agent, an unreachable launchd, an agent that never ran, a refused grant and an empty record were each judged by their own branch"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing about the Apple Music refresh was measured"

    local facts raw
    facts="$(mktemp)"
    raw="$(box_run '
S="$HOME/.ostler/state/music_refresh"; A="$HOME/Library/LaunchAgents"; U="$(id -u)"
[ -f "$S/armed" ] && echo "armed=1" || echo "armed=0"
for k in run apply; do
  if [ "$k" = run ]; then L=com.ostler.music-refresh; else L=com.ostler.music-refresh-apply; fi
  [ -f "$A/$L.plist" ] && echo "plist_$k=1" || echo "plist_$k=0"
  if launchctl print "gui/$U" >/dev/null 2>&1; then
    launchctl print "gui/$U/$L" >/dev/null 2>&1 && echo "loaded_$k=1" || echo "loaded_$k=0"
  else echo "loaded_$k=?"; fi
done
[ -r "$S/state.json" ] && { printf "state="; tr -d "\n" < "$S/state.json"; echo; }
')"
    RAW="$raw" python3 -c '
import json, os, sys
kv = {}
for ln in os.environ.get("RAW", "").splitlines():
    if "=" in ln:
        k, v = ln.split("=", 1); kv[k] = v
def tri(v):
    return None if v == "?" else v == "1"
facts = {"armed": kv.get("armed") == "1",
         "plists": {"run": kv.get("plist_run") == "1", "apply": kv.get("plist_apply") == "1"},
         "loaded": {"run": tri(kv.get("loaded_run", "?")), "apply": tri(kv.get("loaded_apply", "?"))},
         "state": None}
try:
    s = json.loads(kv["state"])
    facts["state"] = {"last_status": s.get("last_status"), "refusals": s.get("refusals"),
                      "last_run": s.get("last_run"), "snapshot_size": len(s.get("snapshot") or {})}
except (KeyError, ValueError):
    pass
json.dump(facts, open(sys.argv[1], "w"))' "$facts"

    local out rc n
    out="$(python3 "${_HERE}/lib/apple_music_refresh_probe.py" judge "$facts")"; rc=$?
    rm -f "$facts"
    printf '%s\n' "$out"
    n="$(printf '%s\n' "$out" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "$n" "Apple Music refresh assertions (armed, plists, launchd, last read)"
    [ "$n" -gt 0 ] || probe_fail "the refresh judge printed no assertion; a silent probe is not a pass"
    case "$rc" in
        0)  probe_pass "the Apple Music refresh is armed, loaded, and its scheduled read succeeded under the grant" ;;
        78) if printf '%s\n' "$out" | grep -q 'TCC: '; then
                probe_cannot_run "TCC: the install never got Media & Apple Music, so no refresh was scheduled; only the console walk can click Allow (console_only_probes.tsv)"
            else
                probe_cannot_run "an Apple Music refresh assertion could not be measured (see the CANNOT line above)"
            fi ;;
        *)  probe_fail "the Apple Music refresh is not working under the grant (see the FAIL line above)" ;;
    esac
}

probe_main "$@"
