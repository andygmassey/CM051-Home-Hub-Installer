#!/usr/bin/env bash
# needs_you_now_birthdays_survive_fallback -- ADVISORY (scripts/walk_promote_scope.tsv).
# CM044 fix/v107-needs-you-now-shared-source: the Front Page's "Needs you now"
# has two sources, the Hub editor feed and a SPARQL fallback. The shipped
# compiler container has no /editor mount, so the fallback is a real path.
#
# Box side: re-runs the wiki-compiler exactly as wiki-recompile-tick.sh phase 1
# does (OSTLER_WIKI_SKIP_LLM=1) with OSTLER_FRONT_PAGE_JSON=/nonexistent so the
# feed cannot be read, then reads the band from ~/Documents/Ostler/Wiki/index.md.
# SLOW (about 7 min on a 16 GB Mini). It republishes the same baseline a normal
# tick publishes; nothing else on the box changes. Refuses (CANNOT-RUN) while
# another compile is running. Judge: lib/needs_you_now_fallback.py. --self-test
# runs the judge over canned bands (listed -> green, empty/missing nearest ->
# red, nothing seeded -> CANNOT-RUN).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="needs_you_now_birthdays_survive_fallback"
PROBE_QUESTION="with the Hub editor feed absent (SPARQL fallback forced), does the Front Page's Needs-you-now still list the nearest upcoming birthday?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/needs_you_now_fallback.py" --self-test; then
        probe_examined 6 "canned bands"
        probe_fail "negative control behaved: an empty band, a missing nearest birthday and no band all went red"
    fi
    probe_examined 6 "canned bands"
    probe_pass "SELF-TEST BROKEN: the judge let a known-bad band through"
}

# Expected names are read from birthdays.md AFTER the forced compile, so both come from the same
# compile (read before, a birthday that became due in between is missed). Prints one JSON object {"expected": [...], "index_md": "..."} on the box.
BOX_SIDE='
export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH
W="$HOME/Documents/Ostler/Wiki"
if pgrep -u "$(id -u)" -f "[w]iki-compiler" >/dev/null 2>&1; then echo "BUSY"; exit 0; fi
cd "$HOME/.ostler" || exit 1
OSTLER_PUBLIC_LOOKUPS=0 docker compose --profile compile run --rm -T -e OSTLER_WIKI_SKIP_LLM=1 -e OSTLER_FRONT_PAGE_JSON=/nonexistent/front_page.json wiki-compiler </dev/null >/tmp/ostler-probe-nyn-compile.log 2>&1 || { echo "COMPILE_FAILED"; exit 0; }
python3 - "$W/birthdays.md" <<PY > /tmp/ostler-probe-nyn-expected.json
import json, re, sys
out = []
for l in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r"\| (Today|Tomorrow|In (\d+) days?) \| (?:\[\[[^|]*\|([^\]]+)\]\]|([^|]+?)) \|", l)
    if m and (m.group(2) is None or int(m.group(2)) <= 14):
        out.append((m.group(3) or m.group(4)).strip())
print(json.dumps(out))
PY
python3 -c "import json,sys; print(json.dumps({\"expected\": json.load(open(\"/tmp/ostler-probe-nyn-expected.json\")), \"index_md\": open(sys.argv[1], encoding=\"utf-8\").read()}))" "$W/index.md"
rm -f /tmp/ostler-probe-nyn-expected.json /tmp/ostler-probe-nyn-compile.log
'

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was asked"
    local cap exp lst out rc n
    cap="$(mktemp)"; exp="$(mktemp)"; lst="$(mktemp)"
    box_run "bash -c '$(printf '%s' "${BOX_SIDE}" | sed "s/'/'\\\\''/g")'" > "${cap}" 2>/dev/null
    case "$(head -c 20 "${cap}")" in
        BUSY*) rm -f "${cap}" "${exp}" "${lst}"; probe_cannot_run "another wiki compile is running; not racing it" ;;
        COMPILE_FAILED*) rm -f "${cap}" "${exp}" "${lst}"; probe_cannot_run "the forced-fallback compile exited non-zero on the box" ;;
    esac
    python3 -I -c "
import json, sys
sys.path.insert(0, sys.argv[1])
import needs_you_now_fallback as m
d = json.load(open(sys.argv[2]))
json.dump(d['expected'], open(sys.argv[3], 'w'))
json.dump(m.names_on_band(d['index_md']), open(sys.argv[4], 'w'))
" "${_HERE}/lib" "${cap}" "${exp}" "${lst}" 2>/dev/null \
        || { rm -f "${cap}" "${exp}" "${lst}"; probe_cannot_run "the box-side half returned no capture"; }
    out="$(python3 -I "${_HERE}/lib/needs_you_now_fallback.py" judge "${exp}" "${lst}")"; rc=$?
    rm -f "${cap}" "${exp}" "${lst}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "lines"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed nothing; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "see the lines above" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
