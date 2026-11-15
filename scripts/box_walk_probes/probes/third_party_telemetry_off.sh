#!/usr/bin/env bash
# third_party_telemetry_off -- no Qdrant, Homebrew-analytics or Google Fonts call from the installed Hub
# (BLOCKING.) v1.0.124 egress audit D1 (telemetry.qdrant.io hourly), D3 (Homebrew analytics), D2 (fonts.googleapis.com / fonts.gstatic.com).
#
# Read ON THE BOX: the RUNNING qdrant container's environment must carry QDRANT__TELEMETRY_DISABLED=true (docker inspect,
# not the compose file), and N samples of ESTABLISHED tcp remotes must match none of the addresses the forbidden hosts
# resolve to on the box. A loopback connection planted by the collector and read by the same lsof is the control: if it
# is not seen the sampler is blind and the verdict is CANNOT-RUN. FAIL names the host. Sample, not capture (lib/telemetry_off.py).
#
# WALK_READ_ONLY: `docker ps`, `docker inspect`, `lsof`, DNS lookups, one loopback socket; writes nothing on the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="third_party_telemetry_off"
PROBE_QUESTION="does the installed Hub hold zero connections to Qdrant telemetry, Homebrew analytics and Google Fonts, with Qdrant telemetry disabled in the running container?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/telemetry_off.py"

self_test() {
    if python3 -I "${_LIB}" --self-test >/dev/null; then
        probe_examined 12 "judge cases (a disabled flag missing, a forbidden-host connection, a blind sampler, each its own verdict)"
        probe_fail "negative control behaved: telemetry left on and a connection to a forbidden host were each FAIL, and a blind sampler was CANNOT-RUN"
    fi
    probe_examined 12 "judge cases"
    probe_pass "SELF-TEST BROKEN: the telemetry judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local remote cap out rc n
    remote="/tmp/ostler-probe-telemetry-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the telemetry collector on the box"
    cap="$(mktemp)"
    box_run "python3 -I ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side collector returned no capture"; }
    out="$(python3 -I "${_LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions (qdrant container env, forbidden-host sockets with a planted control)"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "qdrant telemetry is disabled in the running container and no sampled connection reached a forbidden host" ;;
        78) probe_cannot_run "a prerequisite was missing (see the CANNOT lines above)" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
