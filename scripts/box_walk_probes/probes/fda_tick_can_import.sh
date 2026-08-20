#!/usr/bin/env bash
# scripts/box_walk_probes/probes/fda_tick_can_import.sh
# ============================================================================
# CAN THE RECURRING FDA TICK IMPORT WHAT IT NEEDS, UNDER THE INTERPRETER IT
# ACTUALLY RUNS?
#
# THE DEFECT, measured on a live v1.0.37 box 2026-08-20 by TNM, then verified
# at source by me:
#
#   ModuleNotFoundError: No module named 'nameparser'
#
#   vendor/ostler_fda/pyproject.toml:42         "nameparser>=2.1.0,<3.0"
#   vendor/ostler_fda/identifier_quality.py:88  from nameparser import HumanName
#   install.sh:5385   cp -R "${SCRIPT_DIR}/ostler_fda" "$FDA_DIR/"
#
# A bare copy, no pip. The chain is plist -> run-source -> tick.sh ->
# ~/.ostler/bin/ostler-fda -> OSTLER_PYTHON=~/.ostler/.venv/bin/python3, and
# that venv never had the package installed. So fda-rerun died on every fire,
# on every box, from the first install. Meanwhile the product told the customer
# "still loading in the background" while the background was dead.
#
# WHY THIS PROBE IMPORTS AND DOES NOT READ
#
# The obvious check is "is nameparser listed in pyproject.toml". That check
# PASSES ON EXACTLY THE BROKEN BOXES, because the declaration was always there
# -- it is the installation that was missing, not the declaration. A gate whose
# surface differs from the defect's surface is green forever.
#
# So this executes the import, under the interpreter resolved the same way the
# tick resolves it, and reads the interpreter's own verdict.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM
#
# That the tick then produces useful data. Import success is a floor, not a
# harvest. It answers one question: can the code that runs on a schedule load.
# ============================================================================

set -uo pipefail

PROBE_NAME="fda_tick_can_import"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/probe.sh
. "${HERE}/../lib/probe.sh"

# The modules the tick loads before it can do any work. identifier_quality is
# the one that died; nameparser is named separately because a future refactor
# could move the import and the box would still need the package.
FDA_MODULES="ostler_fda.identifier_quality nameparser"

# ---------------------------------------------------------------------------
# THE BODY, factored so the negative control drives the SAME code.
#
#   try_import <python> <module>   -> echoes OK or the interpreter's error
#
# No pipe into a short-circuiting consumer anywhere in here: under pipefail a
# pipe into `grep -q` reports a successful match as a failure (CM051 #895).
# ---------------------------------------------------------------------------
try_import() {
    _ti_py="$1"
    _ti_mod="$2"
    _ti_out="$("$_ti_py" -c "import ${_ti_mod}" 2>&1)"
    if [ $? -eq 0 ]; then
        echo "OK"
    else
        # One line, and the interpreter's own words. A paraphrase here would
        # be the probe guessing at a cause it did not observe.
        echo "$_ti_out" | tail -1
    fi
}

# Resolve the interpreter the TICK uses, not whichever python is on PATH.
# Order matters: the wrapper is authoritative because it is what actually runs.
resolve_tick_python() {
    _rp_wrapper="$(box_run 'ls ~/.ostler/bin/ostler-fda 2>/dev/null')"
    if [ -n "$_rp_wrapper" ]; then
        _rp_declared="$(box_run 'grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?OSTLER_PYTHON=" ~/.ostler/bin/ostler-fda 2>/dev/null')"
        _rp_path="$(echo "$_rp_declared" | sed -E 's/.*OSTLER_PYTHON=//; s/^"//; s/"$//; s/^.\{0,0\}//')"
        _rp_path="$(box_run "echo ${_rp_path}" 2>/dev/null)"
        if [ -n "$_rp_path" ]; then
            echo "$_rp_path"
            return 0
        fi
    fi
    # Fallback to the documented venv location, and SAY that is what happened.
    _rp_venv="$(box_run 'ls ~/.ostler/.venv/bin/python3 2>/dev/null')"
    [ -n "$_rp_venv" ] && { echo "$_rp_venv"; return 0; }
    return 1
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box at '${OSTLER_BOX_HOST}' did not answer over ssh, so no interpreter could be resolved. Not a pass."
    fi

    PY="$(resolve_tick_python)" || PY=""
    if [ -z "$PY" ]; then
        probe_cannot_run "neither ~/.ostler/bin/ostler-fda nor ~/.ostler/.venv/bin/python3 was found on the box, so the tick's interpreter is unknown. Not a pass: an absent wrapper is its own defect."
    fi
    probe_note "interpreter: ${PY}"

    _n=0
    _bad=""
    for _m in $FDA_MODULES; do
        _n=$((_n + 1))
        _r="$(box_run "${PY} -c 'import ${_m}' 2>&1 || true")"
        if [ -n "$_r" ]; then
            _bad="${_bad}${_m}: $(echo "$_r" | tail -1)
"
        fi
    done

    probe_examined "$_n" "module import(s) under ${PY}"

    if [ -n "$_bad" ]; then
        probe_note "failing imports:"
        printf '%s' "$_bad" | sed 's/^/    /'
        probe_fail "the recurring FDA tick cannot load its own modules under ${PY}. fda-rerun dies on every fire and the customer is told loading continues in the background."
    fi
    probe_pass "all ${_n} tick modules import cleanly under ${PY}"
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. Must come back FAIL, per the probe contract.
#
# Driven with the LOCAL python3 on purpose. The control must be deterministic
# whether or not a box is reachable -- a negative control that CANNOT-RUNs has
# proved nothing, and this framework exists because instruments returned
# confident verdicts from measurements that never ran.
#
# Both directions, because a checker that always says "broken" would satisfy a
# one-sided control while being useless.
# ---------------------------------------------------------------------------
self_test() {
    _st_py="$(command -v python3 2>/dev/null)"
    if [ -z "$_st_py" ]; then
        probe_pass "NEGATIVE CONTROL COULD NOT RUN: no python3 on this machine, so try_import was never exercised."
    fi

    # 1. A module that MUST import. If this reads as broken, the checker is
    #    stuck on failure and its reds mean nothing.
    if [ "$(try_import "$_st_py" sys)" != "OK" ]; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: 'import sys' adjudicated as broken. This probe would red every healthy box."
    fi

    # 2. A module that CANNOT exist. This is the shape of the real defect:
    #    an ImportError from the interpreter the tick actually uses.
    _st_miss="$(try_import "$_st_py" ostler_fda_probe_canary_absent_by_design)"
    if [ "$_st_miss" = "OK" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a module that cannot exist adjudicated as importable. This probe cannot detect the ModuleNotFoundError it exists for."
    fi

    # 3. And the error must be the one we claim to detect, not any error at
    #    all -- otherwise a syntax error in the probe would read as the defect.
    if ! grep -q 'ModuleNotFoundError\|No module named' <<< "$_st_miss"; then
        probe_pass "NEGATIVE CONTROL FIRED FOR THE WRONG REASON: expected a ModuleNotFoundError, got: ${_st_miss}"
    fi

    probe_examined 3 "synthetic import readings (negative control)"
    probe_fail "negative control behaved correctly on 3 readings (a present module imports; an absent one fails; and it fails with ModuleNotFoundError, not merely with something)"
}

probe_main "$@"
