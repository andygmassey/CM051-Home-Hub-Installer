#!/usr/bin/env bash
# apple_music_library_reaches_preferences -- after install, did the Apple Music
# reader see the owner's library, and did it land in the preference store?
# (CM051 walk #27, Andy 2026-10-14: "we MUST have Apple Music data in there")
#
# Walk #27 showed 14,488 music likes, all Spotify, on a box whose owner mostly
# uses Apple Music: the reader read only the optional XML export. This probe
# reads what the install itself recorded, never a fresh library read:
#
#   1. ~/.ostler/imports/fda/extraction_summary.json -> sources.apple_music
#      (status, total_tracks, reader, native_status, native_detail)
#   2. how many Music Library.musiclibrary bundles exist under ~/Music/Music,
#      so an empty-library CANNOT-RUN is told apart from a permission one
#   3. Qdrant `preferences`: the collection's points_count (the control that
#      the endpoint is the store and the credential works) and the number of
#      points whose payload source is apple_music
#
# Verdicts (lib/apple_music_probe.py, fixture-tested by --self-test):
#   PASS        tracks > 0 and apple_music preference points > 0
#   FAIL        tracks read but none stored; the helper never ran or broke;
#               the source was not requested; the arm crashed
#   CANNOT-RUN  "TCC: ..."  Media & Apple Music not granted to the installer.
#               An ssh-driven install cannot answer that prompt (measured on
#               Mini16, macOS 26.5.2: tccd "Policy disallows prompt" for the
#               sshd responsible process), so this probe is listed in
#               console_only_probes.tsv and is proven on the console walk.
#   CANNOT-RUN  "EMPTY LIBRARY: ..."  nothing to read on this box.
#
# Counts only. No title, artist or playlist name is read or printed.
#
# WALK_READ_ONLY: reads one JSON file, lists a directory, and asks Qdrant two
# read-only questions (collection info, and points/count, which is a POST but
# counts without changing anything).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="apple_music_library_reaches_preferences"
PROBE_QUESTION="after install, did the Apple Music reader see the owner's library (track count > 0), and do apple_music preference points exist in the store? CANNOT-RUN, saying which, when the library is empty or Media & Apple Music was not granted."

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"

self_test() {
    if python3 "${_HERE}/lib/apple_music_probe.py" --self-test; then
        probe_examined 13 "Apple Music judge fixtures"
        probe_pass "SELF-TEST BROKEN: the Apple Music judge let a known-bad fixture through"
    fi
    probe_examined 13 "Apple Music judge fixtures"
    probe_fail "negative controls behaved: a missing summary, an unrequested source, a crashed arm, a refused permission, an empty library, a helper never run, a hung helper, tracks read but not stored, and an unreadable store were each judged by their own branch"
}

# Prints a reading: an integer, or AUTH / ABSENT / TRANSPORT / UNPARSED:<code>.
_reading() {
    local out="$1" code body
    code="$(printf '%s\n' "$out" | tail -n1)"
    body="$(printf '%s\n' "$out" | sed '$d')"
    case "$code" in
        401|403) printf 'AUTH'; return ;;
        404)     printf 'ABSENT'; return ;;
        000|'')  printf 'TRANSPORT'; return ;;
    esac
    local n
    n="$(printf '%s' "$body" | python3 -c '
import json,sys
try:
    r=json.loads(sys.stdin.read())["result"]
    n=r.get("points_count", r.get("count"))
    print("" if n is None else int(n))
except Exception:
    print("")')"
    if [ -n "$n" ]; then printf '%s' "$n"; else printf 'UNPARSED:%s' "$code"; fi
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing about Apple Music was measured"

    local facts summary bundles conf khdr="" total apple
    facts="$(mktemp)"

    summary="$(box_run 'f="$HOME/.ostler/imports/fda/extraction_summary.json"; [ -r "$f" ] && cat "$f"')"
    bundles="$(box_run 'if [ -d "$HOME/Music/Music" ]; then /bin/ls -1d "$HOME"/Music/Music/*.musiclibrary 2>/dev/null | /usr/bin/wc -l | tr -d " "; else echo 0; fi')"

    conf="$(box_run "printf '%s' \"${STORE_CURL_CONF}\"" | tr -d '\r\n')"
    if [ -n "$conf" ] && box_run "[ -r '${conf}' ] && /usr/bin/grep -q '^header = ' '${conf}'"; then
        khdr="-K '${conf}'"
    fi
    total="$(_reading "$(box_run "curl -sS --noproxy '*' -m 10 ${khdr} '${QDRANT_URL}/collections/preferences' -w '\n%{http_code}'")")"
    apple="$(_reading "$(box_run "curl -sS --noproxy '*' -m 10 ${khdr} -X POST -H 'Content-Type: application/json' '${QDRANT_URL}/collections/preferences/points/count' -d '{\"filter\":{\"must\":[{\"key\":\"source\",\"match\":{\"value\":\"apple_music\"}}]},\"exact\":true}' -w '\n%{http_code}'")")"

    SUMMARY="$summary" BUNDLES="$bundles" TOTAL="$total" APPLE="$apple" python3 -c '
import json, os, sys
def num(v):
    v = (v or "").strip()
    return int(v) if v.isdigit() else (v or "TRANSPORT")
raw = os.environ.get("SUMMARY", "").strip()
facts = {"summary_present": False}
if raw:
    try:
        s = json.loads(raw)
        facts = {"summary_present": True, "apple_music": (s.get("sources") or {}).get("apple_music")}
    except ValueError:
        facts = {"summary_present": False}
b = os.environ.get("BUNDLES", "").strip()
facts["library_bundles"] = int(b) if b.isdigit() else None
facts["prefs_total"] = num(os.environ.get("TOTAL"))
facts["prefs_apple"] = num(os.environ.get("APPLE"))
json.dump(facts, open(sys.argv[1], "w"))' "$facts"

    local out rc n
    out="$(python3 "${_HERE}/lib/apple_music_probe.py" judge "$facts")"; rc=$?
    rm -f "$facts"
    printf '%s\n' "$out"
    n="$(printf '%s\n' "$out" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "$n" "Apple Music assertions (summary, library, store)"
    [ "$n" -gt 0 ] || probe_fail "the Apple Music judge printed no assertion; a silent probe is not a pass"
    case "$rc" in
        0)  probe_pass "the Apple Music reader saw the library and apple_music preference points exist in the store" ;;
        78) if printf '%s\n' "$out" | grep -q 'TCC: '; then
                probe_cannot_run "TCC: Media & Apple Music was not granted to the installer; only the console walk can click Allow (console_only_probes.tsv)"
            elif printf '%s\n' "$out" | grep -q 'EMPTY LIBRARY'; then
                probe_cannot_run "EMPTY LIBRARY: this box has no Apple Music library to read"
            else
                probe_cannot_run "an Apple Music assertion could not be measured (see the CANNOT line above)"
            fi ;;
        *)  probe_fail "Apple Music did not reach the preference store (see the FAIL line above)" ;;
    esac
}

probe_main "$@"
