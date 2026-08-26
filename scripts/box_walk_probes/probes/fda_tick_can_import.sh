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
# 🔴 EVALUATE THE WRAPPER'S WHOLE RESOLUTION CHAIN, NOT ONE LINE OF IT.
#
# This used to grep ONLY the OSTLER_PYTHON= line and re-evaluate it in a fresh
# remote shell. The wrapper's actual text is:
#
#     line  3   OSTLER_DIR="${HOME}/.ostler"
#     line 14   OSTLER_PYTHON="${OSTLER_PYTHON:-${OSTLER_DIR}/.venv/bin/python3}"
#     line 15   if [[ ! -x "$OSTLER_PYTHON" ]]; then
#     line 16       OSTLER_PYTHON="$(command -v python3 || true)"
#
# Lifting line 14 alone drops the line-3 assignment, so ${OSTLER_DIR} expanded
# to EMPTY and the probe tested `/.venv/bin/python3`, which exists nowhere. The
# import then failed for a reason that had nothing to do with the product, and
# the probe reported FAIL on a box measured healthy: on andy@.228 2026-08-26 the
# real interpreter imports httpx 0.28.1, nameparser 2.1.0, ostler_fda,
# ostler_fda.identifier_quality and ostler_fda.pwg_ingest, all OK.
#
# A gate that cries wolf gets ignored, and the next REAL regression here would be
# waved through as "that known false red".
#
# The fallback arm is mirrored deliberately: if the venv is absent the wrapper
# silently lands on system python3, and THAT is the original defect's shape --
# a system interpreter that never had nameparser installed. Which arm resolved
# is therefore itself a finding, so the caller is told.
resolve_tick_python() {
    # Emits "ARM<space>PATH" on stdout. The caller splits it -- this runs inside
    # a command substitution, so a variable set here would NOT reach the caller.
    _rp_wrapper="$(box_run 'ls ~/.ostler/bin/ostler-fda 2>/dev/null')"
    if [ -z "$_rp_wrapper" ]; then
        _rp_venv="$(box_run 'ls ~/.ostler/.venv/bin/python3 2>/dev/null')"
        [ -n "$_rp_venv" ] && { echo "NO-WRAPPER $_rp_venv"; return 0; }
        return 1
    fi

    # 🔴 THE WRAPPER'S LADDER IS CONDITIONAL. DO NOT eval ITS LINES.
    # Two drafts of this probe got it wrong in two different ways, both by
    # lifting text out of the control flow that gives it meaning:
    #   draft 1  grepped ONLY the OSTLER_PYTHON= line, losing the line-3
    #            OSTLER_DIR assignment, so ${OSTLER_DIR} expanded to EMPTY and
    #            it tested "/.venv/bin/python3", which exists nowhere
    #   draft 2  grepped every OSTLER_DIR/OSTLER_PYTHON assignment and eval'd
    #            them in file order -- but the third one lives INSIDE
    #            `if [[ ! -x "$OSTLER_PYTHON" ]]`, so lifting it out of its
    #            conditional overwrote the venv path with system python3 on
    #            EVERY box, healthy or not
    # Both produced a confident FAIL on a box measured healthy.
    #
    # So replicate the wrapper's documented ladder directly, and ASSERT the
    # wrapper still has that shape. If the shape changes, this returns nothing
    # and the caller reports CANNOT-RUN rather than guessing.
    _rp_shape="$(box_run 'W=~/.ostler/bin/ostler-fda
        a=$(/usr/bin/grep -c "OSTLER_DIR=\"\${HOME}/.ostler\"" "$W" 2>/dev/null || true)
        b=$(/usr/bin/grep -c "OSTLER_PYTHON:-\${OSTLER_DIR}/.venv/bin/python3" "$W" 2>/dev/null || true)
        c=$(/usr/bin/grep -c "command -v python3" "$W" 2>/dev/null || true)
        echo "${a:-0}${b:-0}${c:-0}"')"
    case "$_rp_shape" in
        1*1*1*) : ;;
        *) return 1 ;;
    esac

    _rp_path="$(box_run '
        # The wrapper ladder, replicated: explicit override, then the venv,
        # then whatever python3 is on PATH.
        P="${OSTLER_PYTHON:-$HOME/.ostler/.venv/bin/python3}"
        if [ -x "$P" ]; then printf "VENV %s\n" "$P"
        else printf "FALLBACK %s\n" "$(command -v python3 || true)"; fi')"
    [ -n "$_rp_path" ] && { echo "$_rp_path"; return 0; }
    return 1
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box at '${OSTLER_BOX_HOST}' did not answer over ssh, so no interpreter could be resolved. Not a pass."
    fi

    _resolved="$(resolve_tick_python)" || _resolved=""
    TICK_PYTHON_ARM="${_resolved%% *}"
    PY="${_resolved#* }"
    if [ -z "$_resolved" ] || [ -z "$PY" ] || [ "$PY" = "$TICK_PYTHON_ARM" ]; then
        probe_cannot_run "could not resolve the tick's interpreter: either ~/.ostler/bin/ostler-fda and ~/.ostler/.venv/bin/python3 are both absent, or the wrapper no longer has the OSTLER_DIR -> venv -> system-python3 ladder this probe replicates. Not a pass -- re-point the probe rather than assuming."
    fi
    probe_note "interpreter: ${PY}  [resolved via: ${TICK_PYTHON_ARM:-unknown}]"
    # FALLBACK means the venv was absent or not executable and the wrapper
    # silently reached for whatever python3 is on PATH. That is the shape of the
    # original defect -- a system interpreter that never had the packages -- so
    # say it out loud even when the imports below happen to succeed.
    if [ "${TICK_PYTHON_ARM:-}" = "FALLBACK" ]; then
        probe_note "⚠ the venv did not resolve, so the tick is running on SYSTEM python3."
        probe_note "  Imports may still pass here by luck of what is installed globally;"
        probe_note "  that is not the interpreter the install is supposed to provide."
    fi

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
