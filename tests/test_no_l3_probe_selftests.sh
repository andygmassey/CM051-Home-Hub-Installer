#!/usr/bin/env bash
# The no_l3 probe's own self-test modes, run as one wired test: the seed-URL resolver
# (loopback forwarding, ambient refusal), the ical-server preflight (decision cases and
# the live-process collector) and the probe's run_probe with fake box runs. Each mode
# exits non-zero on any failed case, so this script does too.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="${ROOT}/scripts/box_walk_probes/probes/no_l3_in_tool_results.sh"
rc=0
for mode in --seed-url-test --preflight-test --self-test; do
    out="$(bash "${P}" "${mode}" 2>&1)"; r=$?
    printf '%s\n' "${out}" | tail -2
    if [ "${r}" -ne 0 ]; then echo "FAILED: ${mode} rc=${r}"; rc=1; fi
done
[ "${rc}" -eq 0 ] && echo "no_l3 probe self-tests: all modes held"
exit "${rc}"
