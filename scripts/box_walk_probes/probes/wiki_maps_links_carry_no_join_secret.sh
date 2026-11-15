#!/usr/bin/env bash
# wiki_maps_links_carry_no_join_secret -- does any maps link in the compiled wiki carry pwd= or passcode=? (BLOCKING, #2528)
# A meeting location that is really a join URL used to become a maps link, so one click sent the join passcode to a maps
# provider. CM044 #289 (compiler/pw_kit.py maps_href) refuses URL-shaped locations and pwd=/passcode=; this is the walk grep
# that closes the row. RED shape: any maps URL under /docs/docs of ostler-wiki-site containing pwd= or passcode= (or %3D form).
#
# THE INSTRUMENT: lib/maps_href_secrets.py extract_sh, one find+grep line run INSIDE ostler-wiki-site (the compiled wiki
# lives at /docs/docs, the same path hub_screens_customer_read stats). DENOMINATOR: pages scanned, printed; 0 pages is
# CANNOT-RUN, never a pass. 0 maps links on a box with pages is legitimate and is printed as such.
# SEEDED POSITIVE CONTROL: the SAME extract line is run on fixtures/maps_href/bad (two synthetic passcode links) and MUST
# be caught; fixtures/maps_href/good must not be. The control runs on the driver, the subject in the container, so a
# control-green does not prove the container's grep binary; that is why the box leg also prints pages_scanned.
#
# WALK_READ_ONLY: reads the wiki container's files; writes nothing on the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="wiki_maps_links_carry_no_join_secret"
PROBE_QUESTION="in the compiled wiki, does any maps link carry pwd= or passcode= (expect 0, with a seeded positive control)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/maps_href_secrets.py"
_FIX="${_HERE}/fixtures/maps_href"
_ROOT="${OSTLER_WIKI_DOCS_ROOT:-/docs/docs}"
# Test seam only: the CI test points this at a plain sh and a fixture tree. The walk never sets it.
_EXEC="${OSTLER_WIKI_EXEC-docker exec ostler-wiki-site}"

self_test() {
    local out rc
    out="$(python3 "${_LIB}" --self-test "${_FIX}" 2>&1)"; rc=$?
    printf '%s\n' "${out}"
    probe_examined 3 "control cases (seeded passcode links caught, clean page clean, blind extractor CANNOT-RUN)"
    if [ "${rc}" -eq 0 ]; then
        # The judge on the seeded-bad fixture is FAIL by construction: run it for the verdict the runner demands.
        local tok; tok="$(mktemp)"
        python3 "${_LIB}" extract "${_FIX}/bad" > "${tok}"
        python3 "${_LIB}" judge "${tok}" 1; rc=$?; rm -f "${tok}"
        [ "${rc}" -eq 1 ] && probe_fail "negative control behaved: the seeded fixture with pwd=/passcode= inside maps links was FAIL"
    fi
    probe_pass "SELF-TEST BROKEN: the seeded positive control was not caught"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was run"
    # CONTROL FIRST, on the driver, through the very same extractor text.
    python3 "${_LIB}" --self-test "${_FIX}" >/dev/null 2>&1 \
        || { probe_examined 3 "control cases"; probe_fail "the seeded positive control was not caught by the extractor; the instrument is blind, so no wiki verdict is believable"; }
    local pages_b64 ext_b64 pages tok rc out
    pages_b64="$(python3 "${_LIB}" pages-sh "${_ROOT}" | base64 | tr -d '\n')"
    ext_b64="$(python3 "${_LIB}" extract-sh "${_ROOT}" | base64 | tr -d '\n')"
    pages="$(box_run "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; ${_EXEC} sh -c \"\$(printf %s ${pages_b64} | base64 -d)\"" 2>/dev/null | tr -d ' \n')"
    case "${pages}" in ''|*[!0-9]*) probe_cannot_run "could not count pages in ostler-wiki-site:${_ROOT} (docker exec gave '${pages}'); nothing was measured" ;; esac
    tok="$(mktemp)"
    box_run_v "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; ${_EXEC} sh -c \"\$(printf %s ${ext_b64} | base64 -d)\"" > "${tok}" 2>"${tok}.err"
    rc=$?
    if [ "${rc}" -gt 1 ]; then
        out="$(head -c 300 "${tok}.err")"; rm -f "${tok}" "${tok}.err"
        probe_cannot_run "the grep inside ostler-wiki-site exited ${rc}: ${out}"
    fi
    out="$(python3 "${_LIB}" judge "${tok}" "${pages}")"; rc=$?
    rm -f "${tok}" "${tok}.err"
    printf '%s\n' "${out}"
    probe_examined "${pages}" "wiki pages scanned"
    case "${rc}" in
        0)  probe_pass "no maps link in ${pages} compiled wiki pages carries pwd= or passcode=, positive control caught" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "a compiled wiki maps link carries a join secret (see FAIL lines above)" ;;
    esac
}

probe_main "$@"
