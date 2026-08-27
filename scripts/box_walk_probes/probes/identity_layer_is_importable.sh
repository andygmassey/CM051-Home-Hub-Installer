#!/usr/bin/env bash
# probes/identity_layer_is_importable.sh
# ============================================================================
# QUESTION: can the service that owns dedupe actually import the dedupe code?
#
# WHY IT MATTERS. Shipping a module is not installing its dependencies. When a
# dependency is missing the layer does not crash -- it quietly is not there.
#
# MEASURED on the walk box 2026-08-26, in the interpreter actually running
# ical-server, using that process's own PYTHONPATH:
#
#     identity_resolver.compartment   OK             <- stdlib-only
#     identity_resolver.normalise     ModuleNotFoundError: rapidfuzz
#     identity_resolver.resolver      ModuleNotFoundError: rapidfuzz
#     identity_resolver.tidy          ModuleNotFoundError: rapidfuzz
#     qdrant_client                   ModuleNotFoundError
#     CONTROL json                    OK
#
# Cause: install.sh selected ONE pipeline requirements file via if/elif, so
# contact_syncer's was installed and identity_resolver's -- the one declaring
# rapidfuzz -- never was. Fixed in #1115. This probe is what would have caught
# it on day one.
#
# WHY NOTHING NOTICED, and it is three defensible decisions stacking:
#
#   1. identity_resolver/__init__.py uses PEP 562 lazy re-exports ON PURPOSE, so
#      importing the stdlib-only submodule does not drag in the heavy ones. The
#      service therefore STARTS CLEAN.
#   2. the call sites wrap use in try/except and return {"degraded": true,
#      "reason": ...}. Honest, at the call site.
#   3. nothing aggregates that upward. Doctor diagnostics returns 28KB and
#      mentions "identity_resolver", "rapidfuzz", "degraded", "tidy" and
#      "dedupe" ZERO times.
#
# The first two are good engineering. The third is the gap this probe closes.
# The only symptom otherwise is data quality drifting: 130 over-merged Person
# nodes swallowing 268 Contacts cards, and a 173-point gap between the Qdrant
# people collection and Oxigraph Person nodes, with no fault reported anywhere.
#
# RESOLVE THE INTERPRETER FROM THE RUNNING PROCESS, NEVER ASSUME IT. A probe
# that picks its own python proves something about a python nobody uses. The
# interpreter and PYTHONPATH here are read out of the live process.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/probe.sh"

PROBE_NAME="identity_layer_is_importable"
PROBE_QUESTION="can the service that owns dedupe import the dedupe code, in the interpreter it actually runs?"

# Modules the dedupe/identity layer cannot function without.
REQUIRED_MODULES="identity_resolver.normalise identity_resolver.resolver"
# Needed for Oxigraph<->Qdrant reconciliation; _merge_qdrant() FAILS OPEN
# without it, so its absence is silent by design.
RECONCILE_MODULES="qdrant_client"

# missing_dep <output> -> the module python could not find, or empty
#
# WHY THIS EXISTS. This probe used to print `identity_resolver.normalise ->
# MISSING` and stop there, and MISSING is two completely different faults
# wearing one word:
#
#   No module named 'identity_resolver'   the package was never deployed
#   No module named 'rapidfuzz'           the package IS deployed; a DEPENDENCY
#                                         of it is absent from THIS interpreter
#
# Measured 2026-08-27: the second one was true on the live box and the first
# one is what the output implied, so the search went to the install path that
# copies identity_resolver -- which was working perfectly -- instead of to the
# venv that holds its dependencies. Five steps to reach a fact the interpreter
# had stated on line one and this probe had thrown away.
#
# No sed: the message is full of single quotes and this string has already
# survived a bash string, an ssh argument and a python -c by the time it gets
# here. Parameter expansion cannot be broken by any of them.
missing_dep() {
    case "$1" in
        *"No module named '"*)
            _md_tail="${1#*No module named \'}"
            printf '%s' "${_md_tail%%\'*}"
            ;;
        *) printf '' ;;
    esac
}

# judge_import <module> <output> -> OK|MISSING|ERROR
# Split out so self_test can adjudicate crafted interpreter output.
judge_import() {
    case "$2" in
        *"__PROBE_OK__"*)          printf 'OK' ;;
        *ModuleNotFoundError*)     printf 'MISSING' ;;
        *)                         printf 'ERROR' ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach ${OSTLER_BOX_HOST:-this machine} over ssh; nothing was imported"
    fi

    _pid="$(box_run "pgrep -f ical-server.py | head -1")"
    if [ -z "$_pid" ]; then
        probe_cannot_run "ical-server is not running on ${OSTLER_BOX_HOST:-this machine}, so there is no interpreter to test. Not a pass: the dedupe layer's importability is unknown, not proven."
    fi
    _py="$(box_run "ps -o command= -p ${_pid} | awk '{print \$1}'")"
    _pp="$(box_run "ps -Eww -p ${_pid} 2>/dev/null | tr ' ' '\\n' | grep -m1 '^PYTHONPATH=' | sed 's/^PYTHONPATH=//'")"
    if [ -z "$_py" ]; then
        probe_cannot_run "could not resolve the interpreter from pid ${_pid}; refusing to substitute one of my own, which would prove nothing about the service"
    fi
    probe_note "interpreter (from pid ${_pid}): ${_py}"
    probe_note "PYTHONPATH (from the process): ${_pp:-<unset>}"

    # POSITIVE CONTROL FIRST. Same interpreter, same PYTHONPATH. If this fails,
    # every absence below is my invocation, not the box.
    _ctl="$(box_run "PYTHONPATH='${_pp}' '${_py}' -c 'import json; print(\"__PROBE_OK__\")' 2>&1")"
    if [ "$(judge_import json "$_ctl")" != "OK" ]; then
        probe_cannot_run "CONTROL FAILED: 'import json' did not succeed in ${_py}. The invocation is broken, so no absence below can be trusted. Output: $(printf '%s' "$_ctl" | tr '\n' ' ' | cut -c1-120)"
    fi
    probe_note "CONTROL: import json in that interpreter -> OK"

    _checked=0; _missing=0; _missing_names=""; _dep_names=""
    for _m in $REQUIRED_MODULES $RECONCILE_MODULES; do
        _out="$(box_run "PYTHONPATH='${_pp}' '${_py}' -c 'import ${_m}; print(\"__PROBE_OK__\")' 2>&1")"
        _v="$(judge_import "$_m" "$_out")"
        _checked=$((_checked + 1))
        if [ "$_v" = "OK" ]; then
            probe_note "  ${_m} -> ${_v}"
        else
            _dep="$(missing_dep "$_out")"
            _missing=$((_missing + 1))
            if [ -z "$_dep" ]; then
                probe_note "  ${_m} -> ${_v}"
                _missing_names="${_missing_names}${_missing_names:+ }${_m}"
            elif [ "$_dep" = "$_m" ]; then
                # The module asked for IS the one not found: not deployed.
                probe_note "  ${_m} -> ${_v} (the module itself is absent)"
                _missing_names="${_missing_names}${_missing_names:+ }${_m}"
            else
                # Deployed, but a dependency is absent from THIS interpreter.
                probe_note "  ${_m} -> ${_v} (deployed, but needs '${_dep}', which is absent from this interpreter)"
                _missing_names="${_missing_names}${_missing_names:+ }${_m}(needs ${_dep})"
                # Several modules commonly fail on the SAME dependency, and
                # "[rapidfuzz rapidfuzz]" reads as two faults when it is one.
                case " ${_dep_names} " in
                    *" ${_dep} "*) : ;;
                    *) _dep_names="${_dep_names}${_dep_names:+ }${_dep}" ;;
                esac
            fi
        fi
    done

    probe_examined "${_checked} modules imported in the service's own interpreter" "plus 1 stdlib control in the same interpreter"

    if [ "$_missing" -eq 0 ]; then
        probe_pass "the dedupe layer is importable where it runs (${_checked} of ${_checked} modules)"
    fi
    # The remedy differs by fault, so the verdict must not offer one remedy for
    # both. A missing PACKAGE is an install-copy problem. A missing DEPENDENCY
    # is a venv problem, and pointing at the copy step sends the reader to code
    # that is working.
    if [ -n "$_dep_names" ]; then
        probe_fail "${_missing} of ${_checked} modules the dedupe layer needs are NOT importable in the interpreter that runs it: ${_missing_names}. The dedupe code IS deployed and on PYTHONPATH -- what is absent from THIS interpreter is [${_dep_names}]. Do not go looking at whether install.sh copied identity_resolver; it did. Ask which venv the dependencies were installed into versus which venv the consumer runs under (${_py}). The layer is not failing loudly, it is not running at all: lazy imports keep the service starting clean and try/except returns degraded:true at the call sites, so nothing crashes and nothing reports it. See #1137."
    fi
    probe_fail "${_missing} of ${_checked} modules the dedupe layer needs are NOT importable in the interpreter that runs it: ${_missing_names}. The layer is not failing loudly -- it is not running at all. Lazy imports keep the service starting clean and try/except returns degraded:true at the call sites, so nothing crashes and nothing reports it. Check that install.sh installed EVERY pipeline requirements file, not just the first (see #1115)."
}

self_test() {
    probe_examined "9 crafted interpreter outputs" "adjudicated by the live judge and the dependency extractor (no box touched)"

    # 1. THE DEFECT. A ModuleNotFoundError must be MISSING, never ERROR/OK.
    if [ "$(judge_import identity_resolver.resolver "Traceback...
ModuleNotFoundError: No module named 'rapidfuzz'")" != "MISSING" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a ModuleNotFoundError was not adjudicated MISSING, so this probe could not have caught the 2026-08-26 dead-layer defect."
    fi

    # 2. A successful import must still read OK, or the probe refuses a healthy box.
    if [ "$(judge_import json "__PROBE_OK__")" != "OK" ]; then
        probe_pass "POSITIVE CONTROL DID NOT FIRE: a successful import was not adjudicated OK."
    fi

    # 3. AN UNRELATED FAILURE IS NOT A MISSING MODULE. A syntax error, a
    #    permission denial or an ssh hiccup must not be reported as "the layer
    #    is absent" -- that would send someone to reinstall a dependency that
    #    is already there.
    if [ "$(judge_import identity_resolver.resolver "PermissionError: [Errno 13] Permission denied")" != "ERROR" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: an unrelated error adjudicated as MISSING, which would misdirect the fix."
    fi

    # 4. EMPTY OUTPUT IS NOT SUCCESS. An ssh that returned nothing must not
    #    read as OK -- silence is the shape a dropped connection makes.
    if [ "$(judge_import json "")" = "OK" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: empty output adjudicated as a successful import. Silence would have read as health."
    fi

    # ── missing_dep: the two faults that MISSING used to hide ────────────
    # This function is new, so it gets its own controls. A check added without
    # them does not merely go untested, it can mask the checks already here by
    # making their output look richer than their coverage.
    _md_fail() { probe_pass "MISSING_DEP CONTROL FAILED -- $1"; }

    _r="$(missing_dep "Traceback...
ModuleNotFoundError: No module named 'rapidfuzz'")"
    [ "$_r" = "rapidfuzz" ] || _md_fail "a dependency failure yielded '${_r}', expected rapidfuzz. The probe would name the wrong package."

    _r="$(missing_dep "Traceback...
ModuleNotFoundError: No module named 'identity_resolver'")"
    [ "$_r" = "identity_resolver" ] || _md_fail "a package-absent failure yielded '${_r}', expected identity_resolver."

    _r="$(missing_dep "__PROBE_OK__")"
    [ -z "$_r" ] || _md_fail "a SUCCESSFUL import yielded a missing dependency '${_r}'. That would report a fault on a healthy module."

    _r="$(missing_dep "ImportError: cannot import name 'x' from 'y'")"
    [ -z "$_r" ] || _md_fail "a non-ModuleNotFoundError yielded '${_r}'. Only 'No module named' means an absent module."

    # THE DISCRIMINATION THAT MATTERS. Same requested module, two different
    # interpreter messages, two different remedies. If these collapse, the
    # verdict sends the reader to the wrong half of the install.
    _a="$(missing_dep "ModuleNotFoundError: No module named 'rapidfuzz'")"
    _b="$(missing_dep "ModuleNotFoundError: No module named 'identity_resolver'")"
    if [ "$_a" = "$_b" ]; then
        probe_pass "MISSING_DEP IS BLIND: 'dependency absent' and 'package absent' both yield '${_a}'. Those have different remedies -- one is a venv, one is a copy step -- and this probe would name the same one for both."
    fi

    probe_fail "negative controls fired on all 9 crafted outputs: 4 on the import judge (missing caught, success kept, unrelated error not misread as missing, silence not read as success) and 5 on the dependency extractor (dependency named, package-absent named, healthy import yields nothing, non-ModuleNotFoundError yields nothing, and the two faults do not collapse onto one name)"
}

probe_main "$@"
