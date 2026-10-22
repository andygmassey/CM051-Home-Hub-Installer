#!/usr/bin/env bash
# derived_preferences_reach_digest_and_tool -- do derived preferences ("What you
# like") reach the assistant's always-on digest AND the assistant's tool?
# (smart-prefs, v1.0.117)
#
# The derive engine writes pwg:DerivedPreference nodes; the Hub serves them at
# /api/v1/preferences/derived, which the assistant's pwg_derived_preferences
# tool reads. Three assertions, graded by lib/derived_preferences_reach.py from
# yes/no facts and counts only:
#   (route)  the route serves at least one derived preference, not degraded;
#   (digest) CONTEXT.md's Preferences section names a served derived label;
#   (tool)   asked what the owner likes, the assistant names a served label.
# Runs after hydration and the derive pass the import kicks. No derived store
# means (digest) and (tool) are CANNOT-RUN. Labels and prose never leave the box.
#
# WALK_READ_ONLY: GETs one Hub route, reads CONTEXT.md, and asks the assistant
# one question (a chat turn, which the owner-digest probe also makes).
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="derived_preferences_reach_digest_and_tool"
PROBE_QUESTION="after hydration and a derive pass, does /api/v1/preferences/derived serve a derived preference, does CONTEXT.md's Preferences section name one, and does the assistant name one when asked what the owner likes?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/derived_preferences_reach.py" --self-test; then
        probe_examined 9 "mutated derived-preference facts"
        probe_fail "negative control behaved: an empty or degraded route fails the route, a digest or reply naming nothing fails its own assertion, and every unmeasured arm is CANNOT-RUN"
    fi
    probe_examined 9 "mutated derived-preference facts"
    probe_pass "SELF-TEST BROKEN: the derived-preference judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; the derived preferences were never read"
    local dir facts out rc n
    dir="/tmp/ostler-probe-derived-prefs-$$"
    box_run "mkdir -p ${dir}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    for f in derived_preferences_reach.py owner_digest.py; do
        box_run "printf %s '$(base64 < "${_HERE}/lib/${f}" | tr -d '\n')' | base64 -d > ${dir}/${f}" >/dev/null 2>&1 \
            || probe_cannot_run "could not stage ${f} on the box"
    done
    facts="$(mktemp)"
    box_run "python3 ${dir}/derived_preferences_reach.py box; rm -rf ${dir}" > "${facts}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts"; }
    out="$(python3 "${_HERE}/lib/derived_preferences_reach.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "derived-preference assertions"
    [ "${n}" -gt 0 ] || probe_fail "the derived-preference judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "derived preferences are served, in the digest, and named by the assistant" ;;
        78) probe_cannot_run "a derived-preference assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "derived preferences do not reach the digest or the assistant tool (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
