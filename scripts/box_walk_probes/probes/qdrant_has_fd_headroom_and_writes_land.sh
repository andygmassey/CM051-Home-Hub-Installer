#!/usr/bin/env bash
# qdrant_has_fd_headroom_and_writes_land -- BLOCKING (scripts/walk_promote_scope.tsv).
#
# v1.0.107 cut #16 console walk: ostler-qdrant ran with nofile=1024 (the
# compose block set no ulimits), 751 RocksDB .sst files were open, and the
# Places step then wrote 0 of 979 and printed status=ok. The synthetic walk
# could not see it because its seed is tiny; lib/scale_fixture.py is the
# volume that can (see scripts/qdrant_fd_scale_proof.sh for the RED/GREEN
# proof on the pinned image).
#
# Asserts, from the box:
#   1. the qdrant PROCESS's soft nofile limit is >= 65535 (/proc/<pid>/limits
#      inside ostler-qdrant, not the compose text);
#   2. its open fds are under 50% of that limit;
#   3. every hydrate step with input wrote ALL of it (written == input and no
#      errors), read from the step's OWN count lines in the kept install
#      diagnostics (and the newest scale-fixture replay), never its status word.
#
# CANNOT-RUN, never PASS: docker or the container cannot be read, or no step
# with input is found in the logs. --self-test drives the judge over the #16
# shapes (nofile 1024, 0 written with status=ok); each must FAIL.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="qdrant_has_fd_headroom_and_writes_land"
PROBE_QUESTION="does ostler-qdrant run with nofile >= 65535 and under half of it open, and did every hydrate step that had input actually write (by its own counts, not its status word)?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/qdrant_fd_headroom.py" --self-test; then
        probe_examined 9 "known-bad captures (nofile 1024, fds at the limit, fds over half, 0 written with status=ok, chunks with no vectors, a partial write with errors, errors with a full write, docker unreachable, no step found)"
        probe_fail "negative control behaved: every #16 shape went red by its own assertion"
    fi
    probe_examined 9 "known-bad captures"
    probe_pass "SELF-TEST BROKEN: the judge let a #16 shape through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    local remote cap rc out n
    remote="/tmp/ostler-probe-qfd-$$"
    box_run "mkdir -p ${remote}" >/dev/null 2>&1 || probe_cannot_run "could not make a staging directory on the box"
    box_run "printf %s '$(base64 < "${_HERE}/lib/qdrant_fd_headroom.py" | tr -d '\n')' | base64 -d > ${remote}/qdrant_fd_headroom.py" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage qdrant_fd_headroom.py on the box"
    cap="$(mktemp)"
    box_run "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; python3 ${remote}/qdrant_fd_headroom.py box; rm -rf ${remote}" > "${cap}" 2>/dev/null
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${cap}" 2>/dev/null \
        || { rm -f "${cap}"; probe_cannot_run "the box-side collector returned no capture"; }
    out="$(python3 "${_HERE}/lib/qdrant_fd_headroom.py" judge "${cap}")"; rc=$?
    rm -f "${cap}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "qdrant has fd headroom and every hydrate step with input wrote" ;;
        78) probe_cannot_run "see the CANNOT line above" ;;
        *)  probe_fail "see the FAIL lines above" ;;
    esac
}

probe_main "$@"
