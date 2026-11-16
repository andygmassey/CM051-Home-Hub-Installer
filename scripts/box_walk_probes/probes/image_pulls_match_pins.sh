#!/usr/bin/env bash
# image_pulls_match_pins -- the qdrant, nginx and valkey images the install actually pulled are the digests install.sh pins
# (BLOCKING.) CM051 #2404: the three images moved to ghcr.io at the SAME digest and a failed pull aborts the install.
# The walk installs once and no probe read the pull result.
#
# Per image, read ON THE BOX (lib/image_pins.py): the pin from the installed docker-compose.yml, the digests
# docker holds for that ref, the image the running container uses, and the pull lines and errors in
# ~/.ostler/logs/install.log. FAIL: a held, running or logged-pulled digest that is not the pin, or a pull
# error naming the image. CANNOT-RUN: docker or the log unreadable, no pin, or an image the log never names.
# The compose pin and the log's pull line share a source; docker's RepoDigests and the running ref do not.
#
# WALK_READ_ONLY: `docker ps`, `docker image inspect` and reads of two files; writes nothing on the box.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="image_pulls_match_pins"
PROBE_QUESTION="are the qdrant, nginx and valkey images the install pulled and runs exactly the digests it pins, with no pull error in the install log?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
_LIB="${_HERE}/lib/image_pins.py"

self_test() {
    if python3 -I "${_LIB}" --self-test >/dev/null; then
        probe_examined 31 "judge cases (one mutant per arm per image, blind controls)"
        probe_fail "negative control behaved: a wrong held, running or logged digest, a never-pulled image and a pull error were each FAIL, and an unreadable docker or log was CANNOT-RUN"
    fi
    probe_examined 31 "judge cases"
    probe_pass "SELF-TEST BROKEN: the image-pin judge put a known case on the wrong verdict"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local remote cap out rc n
    remote="/tmp/ostler-probe-imagepins-$$.py"
    box_run "printf %s '$(base64 < "${_LIB}" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the image-pin collector on the box"
    cap="$(mktemp)"
    box_run "python3 -I ${remote} box; rm -f ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side collector returned no capture"; }
    out="$(python3 -I "${_LIB}" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions (3 images x held, running, install log)"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "qdrant, nginx and valkey: the held, running and install-log-pulled digests all equal the pin" ;;
        78) probe_cannot_run "a prerequisite was missing (see the CANNOT lines above)" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
