#!/usr/bin/env bash
# The no_l3 probe's own self-test modes, run as one wired test: the seed-URL resolver
# (loopback forwarding, ambient refusal), the ical-server preflight (decision cases and
# the live-process collector), and the probe's --self-test, which runs fake box runs
# and then ends on the known-bad capture.
#
# --self-test and --negative-control follow the SUITE contract (lib/probe.sh,
# run_box_walk.sh phase 1): rc 1 with the decide() FAIL line and no "VERDICT: BROKEN".
# rc 0 means decide() passed a known-bad capture; rc 2 with BROKEN means a fixture
# check failed. The other two modes are plain case lists: rc 0 required.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${ROOT}/scripts/box_walk_probes/probes/no_l3_in_tool_results.sh"
rc=0
for mode in --seed-url-test --preflight-test; do
    out="$(bash "${P}" "${mode}" 2>&1)"; r=$?
    printf '%s\n' "${out}" | tail -2
    if [ "${r}" -ne 0 ]; then echo "FAILED: ${mode} rc=${r} (0 required)"; rc=1; fi
done
for mode in --self-test --negative-control; do
    out="$(bash "${P}" "${mode}" 2>&1)"; r=$?
    printf '%s\n' "${out}" | tail -2
    if [ "${r}" -ne 1 ]; then echo "FAILED: ${mode} rc=${r} (1 required)"; rc=1; fi
    if printf '%s\n' "${out}" | grep -q 'VERDICT: BROKEN'; then echo "FAILED: ${mode} printed VERDICT: BROKEN"; rc=1; fi
    if ! printf '%s\n' "${out}" | grep -q 'VERDICT: FAIL -- an L0 or L3 marker reached an outbound path'; then
        echo "FAILED: ${mode} did not end on the decide() FAIL line"; rc=1
    fi
done
[ "${rc}" -eq 0 ] && echo "no_l3 probe self-tests: all modes held"
exit "${rc}"
