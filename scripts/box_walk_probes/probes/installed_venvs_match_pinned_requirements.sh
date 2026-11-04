#!/usr/bin/env bash
# installed_venvs_match_pinned_requirements -- does each installed Python venv
# hold exactly the versions the shipped requirements files pin? (S4, v1.0.124)
#
# Red-team S4: CM051 installed Python packages unpinned, at install AND at every
# upgrade. v1.0.124 pins every requirements file (full freeze, transitive
# included). The source gate (tests/test_python_requirements_are_pinned.py)
# proves the files. THIS proves the install: a venv at a different version, or
# a pinned package that is absent, means an install path bypassed the pinned
# file. Hashes (--require-hashes) are v1.0.125; until then an `exact` venv with
# an extra unpinned package FAILs and the `superset` consumer venv reports it.
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="installed_venvs_match_pinned_requirements"
PROBE_QUESTION="does each installed venv's pip freeze equal the == pins of the requirements files the installer used, with no missing, drifted or extra packages?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"

self_test() {
    if python3 "${_HERE}/lib/pip_pins_probe.py" --self-test; then
        probe_examined 6 "mutated freeze facts"
        probe_fail "negative control behaved: version drift, a missing pin, an extra package in an exact venv, an unpinned line and an empty pin set were each caught"
    fi
    probe_examined 6 "mutated freeze facts"
    probe_pass "SELF-TEST BROKEN: the pin judge let a known-bad fixture through"
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; no venv was read"
    local remote facts out rc n
    remote="/tmp/ostler-probe-pins-$$.py"
    box_run "printf %s '$(base64 < "${_HERE}/lib/pip_pins_probe.py" | tr -d '\n')' | base64 -d > ${remote}" >/dev/null 2>&1 \
        || probe_cannot_run "could not stage the pin reader on the box"
    facts="$(mktemp)"
    box_run "python3 ${remote} box" > "${facts}" 2>/dev/null
    box_run "rm -f ${remote}" >/dev/null 2>&1
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null \
        || { rm -f "${facts}"; probe_cannot_run "the box-side reader returned no facts"; }
    out="$(python3 "${_HERE}/lib/pip_pins_probe.py" judge "${facts}")"; rc=$?
    rm -f "${facts}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT|N/A) ')"
    probe_examined 4 "venv/requirements pairs (${n} reported)"
    case "${rc}" in
        0)  probe_pass "every installed venv matches its pinned requirements" ;;
        78) probe_cannot_run "a venv could not be measured, or none was present (see the lines above)" ;;
        *)  probe_fail "an installed venv differs from the pinned requirements (see the FAIL lines above)" ;;
    esac
}

probe_main "$@"
