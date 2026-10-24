#!/usr/bin/env bash
# scripts/box_walk_probes/lib/smart_prefs_seed.sh
# ============================================================================
# THE SMART PREFERENCES FIXTURE, AND THE ONE COLLECTOR THE FIVE PROBES SHARE.
# (OS003 docs/SMART_PREFERENCES_SPEC.md, "Done means PROVEN"; v1.0.118.)
#
# Sourced two ways:
#   - run_box_walk.sh, above the phase-2 loop, calls smart_prefs_seed_apply:
#     writes SYNTHETIC evidence for ten broad categories (Qdrant points the
#     derive readers scan) and nine CM048-shaped stated-preference facts (an
#     owner dislike, an owner like as the control, ANOTHER person's like) into
#     the box's stores, reads them back out, kicks the derive LaunchAgent and
#     waits for a pass to finish. The forget runs at the end.
#   - each of the five probes sources it for smart_prefs_run, which stages
#     lib/smart_prefs.py on the box, runs one reader, and judges the facts here.
#
# It asserts nothing and has no verdict of its own; collecting it as a probe
# would run a seed as if it were a measurement (see EXEMPT in
# tests/test_every_probe_on_disk_is_collected.py). Its wiring is pinned by
# tests/test_the_walk_seeds_smart_prefs.sh.
#
# THE RULE, as every seed here: a seed that did not work must not look like a
# product defect. A seed that failed leaves OSTLER_SMARTPREFS_SEED_STATE at
# failed:<why>, the stores unread, and the probes print CANNOT-RUN naming it.
# The probes do not trust the state, though: they read the fixture back out of
# the stores themselves.
#
# ENV
#   OSTLER_BOX_HOST                 unset means this machine.
#   OSTLER_SMARTPREFS_DERIVE_BUDGET_S  seconds to wait for a derive pass (240).
#   OSTLER_SMARTPREFS_SEED_SKIP=1   do not seed (the probes then CANNOT-RUN).
# BASH 3.2. No associative arrays, no mapfile.
# ============================================================================

SMARTPREFS_SEED_STATE="unrun"
_SP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_sp_remote() {
    if [ -z "${OSTLER_BOX_HOST:-}" ]; then
        /bin/sh -c "$1"
    else
        /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
            -o StrictHostKeyChecking=accept-new "$OSTLER_BOX_HOST" "$1"
    fi
}

# Stage the module (and wow_moments.py, which the brief reader imports) in a
# scratch directory on the box. Prints the directory. Nonzero when it could not.
_sp_stage() {
    local dir f
    dir="/tmp/ostler-smartprefs-$$"
    _sp_remote "mkdir -p ${dir}" >/dev/null || return 1
    for f in smart_prefs.py wow_moments.py; do
        _sp_remote "printf %s '$(base64 < "${_SP_LIB_DIR}/${f}" | tr -d '\n')' | base64 -d > ${dir}/${f}" >/dev/null \
            || return 1
    done
    printf '%s' "${dir}"
}

# The interpreter. The cm019 venv carries pyyaml and the store-auth .pth, which
# attaches the store credential on loopback; the Hub venv has tomllib for the
# brief reader's config read. Both fall back to python3 on PATH.
_SP_PY_CM019='PY=$HOME/.ostler/services/cm019/.venv/bin/python3; [ -x "$PY" ] || PY=python3;'
_SP_PY_HUB='PY=$HOME/.ostler/.venv/bin/python3; [ -x "$PY" ] || PY=python3;'

smart_prefs_seed_apply() {
    printf -- '--- SMART PREFERENCES SEED ---\n'
    if [ "${OSTLER_SMARTPREFS_SEED_SKIP:-0}" = "1" ]; then
        SMARTPREFS_SEED_STATE="skipped"
        printf '  SKIPPED (OSTLER_SMARTPREFS_SEED_SKIP=1): the five smart-prefs probes will CANNOT-RUN.\n\n'
        OSTLER_SMARTPREFS_SEED_STATE="$SMARTPREFS_SEED_STATE"; export OSTLER_SMARTPREFS_SEED_STATE
        return 0
    fi
    local dir out why
    if ! dir="$(_sp_stage)"; then
        SMARTPREFS_SEED_STATE="failed:could not stage lib/smart_prefs.py on the box"
        printf '  CANNOT-RUN: %s\n\n' "${SMARTPREFS_SEED_STATE}"
        OSTLER_SMARTPREFS_SEED_STATE="$SMARTPREFS_SEED_STATE"; export OSTLER_SMARTPREFS_SEED_STATE
        return 0
    fi
    out="$(_sp_remote "${_SP_PY_CM019} \$PY ${dir}/smart_prefs.py seed; rm -rf ${dir}" 2>&1)"
    # The reader prints one JSON object. Anything else is the harness failing.
    why="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read().strip().splitlines()[-1])
except Exception as e:
    print("FAILED unreadable seed output: %s" % type(e).__name__); sys.exit(0)
p = d.get("presence") or {}
if d.get("state") != "seeded":
    print("FAILED " + (d.get("why") or "seed did not complete"))
else:
    dv = d.get("derive") or {}
    print("SEEDED points=%s facts=%s derive_ran_after_seed=%s outcome=%s" % (p.get("points"), p.get("facts"), dv.get("ran_after_seed"), dv.get("outcome")))
' 2>&1)"
    case "$why" in
        SEEDED*) SMARTPREFS_SEED_STATE="seeded"; printf '  %s\n\n' "$why" ;;
        *)       SMARTPREFS_SEED_STATE="failed:${why#FAILED }"; printf '  CANNOT-RUN: seed %s\n\n' "${SMARTPREFS_SEED_STATE}" ;;
    esac
    OSTLER_SMARTPREFS_SEED_STATE="$SMARTPREFS_SEED_STATE"; export OSTLER_SMARTPREFS_SEED_STATE
    return 0
}

smart_prefs_seed_forget() {
    case "${SMARTPREFS_SEED_STATE:-unrun}" in unrun|skipped) return 0 ;; esac
    local dir out
    dir="$(_sp_stage)" || { printf '  WARNING: smart-prefs fixture NOT removed: could not stage the module\n'; return 0; }
    out="$(_sp_remote "${_SP_PY_CM019} \$PY ${dir}/smart_prefs.py forget; rm -rf ${dir}" 2>&1)"
    printf '  smart-prefs fixture removed: %s\n' "$(printf '%s' "$out" | tail -1 | cut -c1-200)"
    SMARTPREFS_SEED_STATE="unrun"
    return 0
}

# ---------------------------------------------------------------------------
# For the probes (probe.sh is already sourced by the probe).
# ---------------------------------------------------------------------------

# smart_prefs_self_test: the judges against a good fixture and one mutant per
# assertion, including the uniform-zero control. python exit 0 means they
# behaved, which the probe contract turns into its own expected FAIL.
smart_prefs_self_test() {
    local out n
    out="$(python3 "${_SP_LIB_DIR}/smart_prefs.py" --self-test)"; local rc=$?
    n="$(printf '%s\n' "$out" | sed -n 's/^EXAMINED: \([0-9]*\) .*/\1/p')"
    probe_examined "${n:-0}" "mutated smart-prefs facts"
    if [ "$rc" -eq 0 ] && [ "${n:-0}" -gt 0 ]; then
        probe_fail "negative control behaved: every mutant (v1.0.116 films-only, polarity inverted, another person's like leaked, a blind engine, a brief that names the disliked thing) went red by its own assertion"
    fi
    printf '%s\n' "$out" | grep BROKEN
    probe_pass "SELF-TEST BROKEN: a smart-prefs judge let a known-bad fixture through"
}

# smart_prefs_run <judge-name> <reader-mode> <hub|cm019>
smart_prefs_run() {
    local name="$1" mode="$2" which="$3" dir facts errf out rc n py
    box_reachable || probe_cannot_run "cannot reach the box; nothing was read"
    dir="/tmp/ostler-probe-smartprefs-$$"
    box_run "mkdir -p ${dir}" >/dev/null || probe_cannot_run "could not make a staging directory on the box"
    for f in smart_prefs.py wow_moments.py; do
        box_run "printf %s '$(base64 < "${_SP_LIB_DIR}/${f}" | tr -d '\n')' | base64 -d > ${dir}/${f}" >/dev/null \
            || probe_cannot_run "could not stage ${f} on the box"
    done
    [ "$which" = "hub" ] && py="$_SP_PY_HUB" || py="$_SP_PY_CM019"
    facts="$(mktemp)"; errf="$(mktemp)"
    # box_run_v, not box_run: the reader's stderr is part of the answer.
    box_run_v "OSTLER_SMARTPREFS_SEED_STATE='${OSTLER_SMARTPREFS_SEED_STATE:-}'; export OSTLER_SMARTPREFS_SEED_STATE; ${py} \$PY ${dir}/smart_prefs.py ${mode}; r=\$?; rm -rf ${dir}; exit \$r" \
        > "${facts}" 2> "${errf}"
    rc=$?
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${facts}" 2>/dev/null; then
        printf '  box-side reader rc=%s, stderr tail: %s\n' "$rc" "$(tail -3 "${errf}" | tr '\n' ' ' | cut -c1-300)"
        rm -f "${facts}" "${errf}"
        probe_cannot_run "the box-side reader returned no facts (seed state: ${OSTLER_SMARTPREFS_SEED_STATE:-not set by the runner})"
    fi
    out="$(python3 "${_SP_LIB_DIR}/smart_prefs.py" judge "${name}" "${facts}")"; rc=$?
    rm -f "${facts}" "${errf}"
    printf '%s\n' "${out}"
    n="$(printf '%s\n' "${out}" | grep -cE '^  (ok|FAIL|CANNOT) ')"
    probe_examined "${n}" "smart-prefs assertions"
    [ "${n}" -gt 0 ] || probe_fail "the judge printed no assertion; a silent probe is not a pass"
    case "${rc}" in
        0)  probe_pass "every ${name} assertion held" ;;
        78) probe_cannot_run "an assertion could not be measured (see the CANNOT lines above)" ;;
        *)  probe_fail "${name} does not hold (see the FAIL lines above)" ;;
    esac
}
