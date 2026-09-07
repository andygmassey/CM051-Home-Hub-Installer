#!/usr/bin/env bash
# A walk may not record a failure without saying what it is a regression OF.
#
# WHY THIS EXISTS. Andy, 2026-09-07: "when an installer walk happens, Archie
# doesn't go back and look at what changed since the last successful walk and
# figure out what the issue is a regression of. He reinvents the whole wheel
# again, and sometimes makes matters worse."
#
# Reinventing is the rational move when the alternative costs an afternoon of
# reading walk records by hand. So this pairs a gate with the tool that makes
# compliance one command:
#
#     scripts/walk_regression_triage.sh <version>
#
# THE CONTRACT. Every `failed_probe` row in a walk record must have a matching
# `regression_of` row:
#
#     regression_of<TAB><probe><TAB><classification>
#
# where <classification> is one of:
#
#     v1.0.NN                 it PASSED at that walk and fails now. The range
#                             v1.0.NN..<this walk> is where the cause is.
#     NEVER-PASSED            no earlier walk records it passing. Not a
#                             regression; unbuilt rather than broken.
#     CANNOT-CLASSIFY: <why>  the history cannot answer it. A real third state,
#                             and it must carry a reason.
#
# 🗿 CANNOT-CLASSIFY IS ALLOWED ON PURPOSE, AND IT IS NOT A LOOPHOLE. Four of
# the five failures in v1.0.68 genuinely cannot be classified: their history
# runs back to v1.0.47, which records no probe names at all. Forbidding the
# honest answer would only teach people to write NEVER-PASSED instead, which is
# a false claim about the software. What the gate forbids is SILENCE.
#
# GRANDFATHERING, NAMED RATHER THAN HIDDEN. Records walked before
# REQUIRED_FROM predate the requirement. They are counted and listed by this
# gate, so the debt is visible; they are not failed, because a rule cannot bind
# a record written before it existed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${WALK_CLASSIFY_REPO:-$(cd "${HERE}/.." && pwd)}"
WALKS="${REPO}/walks"

# The date the requirement starts. Walks on or after this must classify.
REQUIRED_FROM="${WALK_CLASSIFY_REQUIRED_FROM:-2026-09-07}"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -d "${WALKS}" ] || { cant "no walks/ directory at ${WALKS}"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

rows_of() { awk -F'\t' -v k="$2" '$1==k{print $2}' "$1"; }
field()   { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }

shopt -s nullglob
FILES=( "${WALKS}"/v*.tsv )
shopt -u nullglob
if [ "${#FILES[@]}" -eq 0 ]; then
    cant "no walk records under ${WALKS}; this gate would pass by measuring nothing"
    echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2
fi

echo "== a walk failure must say what it is a regression of =="
echo "   requirement starts ${REQUIRED_FROM}; ${#FILES[@]} record(s) present"
echo

grandfathered=0; in_scope=0; classified=0
declare -a GF=()

for f in "${FILES[@]}"; do
    v="$(basename "${f}" .tsv)"
    walked="$(field "${f}" walked_at)"
    day="${walked%%T*}"

    # A record with no walked_at cannot be placed relative to the requirement.
    # That is CANNOT-RUN for that record, never a silent pass.
    if [ -z "${day}" ]; then
        cant "${v}: no walked_at, so it cannot be placed before or after ${REQUIRED_FROM}"
        continue
    fi

    mapfile_failing=()
    while IFS= read -r p; do [ -n "${p}" ] && mapfile_failing+=("${p}"); done < <(rows_of "${f}" failed_probe)
    [ "${#mapfile_failing[@]}" -eq 0 ] && continue

    # String comparison is correct for ISO-8601 and needs no `date -d`, which
    # macOS does not have.
    if [[ "${day}" < "${REQUIRED_FROM}" ]]; then
        grandfathered=$((grandfathered+1))
        GF+=("${v} (${day}, ${#mapfile_failing[@]} failing, unclassified)")
        continue
    fi

    in_scope=$((in_scope+1))
    missing=()
    # Herestring, not a pipe: see scripts/walk_regression_triage.sh.
    _classified_rows="$(rows_of "${f}" regression_of)"
    for p in "${mapfile_failing[@]}"; do
        if grep -qF "${p}" <<< "${_classified_rows}"; then
            classified=$((classified+1))
        else
            missing+=("${p}")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        ok "${v}: all ${#mapfile_failing[@]} failing probe(s) classified"
    else
        bad "${v}: ${#missing[@]} failing probe(s) with no regression_of row:"
        printf '           %s\n' "${missing[@]}"
        printf '         Run: scripts/walk_regression_triage.sh %s\n' "${v}"
    fi
done

# The grandfathered set is DEBT, printed every run so it cannot be forgotten.
if [ "${grandfathered}" -gt 0 ]; then
    printf '  [NOTE] %d record(s) predate %s and are not failed by this gate:\n' "${grandfathered}" "${REQUIRED_FROM}"
    printf '         %s\n' "${GF[@]}"
fi

# ⚠️ RE-ENTRY GUARD, AND IT IS LOAD-BEARING. The control below invokes "$0".
# Without this, the child runs its own control, which spawns another child,
# forever. Measured 2026-09-07: the first version of this file HUNG rather than
# failed and took the machine with it -- `echo` would not run until the process
# tree was killed. A hang is worse than a red: in CI it reads as a slow runner
# and burns the job timeout instead of printing a verdict.
if [ -n "${WALK_CLASSIFY_NO_SELFTEST:-}" ]; then
    echo
    echo "   in scope: ${in_scope} record(s), ${classified} probe classification(s) found"
    echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
    [ "${FAIL}" -gt 0 ] && exit 1
    [ "${CANT}" -gt 0 ] && exit 2
    exit 0
fi

# ── CONTROL: the gate must be able to FAIL. A gate that has only ever seen
# compliant records is indistinguishable from one whose predicate matches
# nothing, and both print the same clean sweep.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/walkclass.XXXXXX")" || TMP=""
if [ -z "${TMP}" ]; then
    cant "no temp dir, so the self-test could not run and the passes above are unproved"
else
    mkdir -p "${TMP}/walks"
    printf 'walked_at\t2099-01-01T00:00:00Z\nverdict\tFAILED\nfailed_probe\tsubject\n' \
        > "${TMP}/walks/v9.9.9.tsv"
    out="$(WALK_CLASSIFY_REPO="${TMP}" WALK_CLASSIFY_NO_SELFTEST=1 "$0" 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && grep -q 'no regression_of row' <<< "${out}"; then
        ok "CONTROL: an in-scope record with an unclassified failure FAILS this gate (rc=1)"
    else
        bad "CONTROL FAILED: an unclassified failure did not fail the gate (rc=${rc}), so every pass above is meaningless"
    fi

    # MUST-MISS: the same record, now classified, must pass.
    printf 'walked_at\t2099-01-01T00:00:00Z\nverdict\tFAILED\nfailed_probe\tsubject\nregression_of\tsubject\tNEVER-PASSED\n' \
        > "${TMP}/walks/v9.9.9.tsv"
    out="$(WALK_CLASSIFY_REPO="${TMP}" WALK_CLASSIFY_NO_SELFTEST=1 "$0" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "CONTROL: the same record WITH a regression_of row passes, so the gate is not rejecting everything"
    else
        bad "CONTROL FAILED: a classified record still failed (rc=${rc}); the gate rejects its own remedy"
    fi
    rm -rf -- "${TMP}"
fi

echo
echo "   in scope: ${in_scope} record(s), ${classified} probe classification(s) found"
echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
