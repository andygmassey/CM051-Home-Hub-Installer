#!/usr/bin/env bash
# For every probe that FAILED in a walk, say when it last PASSED -- or say,
# in those words, that we cannot tell.
#
# WHY THIS EXISTS. Andy, 2026-09-07: "when an installer walk happens, Archie
# doesn't go back and look at what changed since the last successful walk and
# figure out what the issue is a regression of. He reinvents the whole wheel
# again, and sometimes makes matters worse."
#
# He is describing a missing INPUT, not a missing effort. Nothing in this repo
# reads two walk records together. Measured 2026-09-07: `last_green|previous_walk|
# baseline_walk` matches 0 files under scripts/ and tests/, against a control of
# 5 files that do reference walks/ -- so the zero is a real absence.
#
# 🔴 AND THE FIRST THING IT TAUGHT ME, WHICH CHANGES THE QUESTION.
# There has never been a green walk. All nine records on main say FAILED. So
# "the last SUCCESSFUL walk" does not exist and a whole-walk baseline is not
# available. The answerable question is PER PROBE: when did THIS probe last
# pass? That is the comparison this script makes.
#
# ⚠️ FOUR STATES PER PROBE PER WALK, AND THE FOURTH IS THE ONE THAT MATTERS.
#
#   FAILED       the probe is named in a `failed_probe` row
#   NOT-MEASURED the probe is named in a `not_measured_probe` row -- it did not
#                run, so the walk says nothing about it
#   PASSED       the record HAS failed_probe rows, and this probe is in neither
#                list. Only then is absence evidence of passing.
#   UNRECORDED   the record has ZERO failed_probe rows. v1.0.44 and v1.0.47
#                predate the field. Absence there means the walk did not write
#                down which probes failed, NOT that none did -- both records say
#                verdict FAILED. Treating those as PASSED would manufacture a
#                green baseline out of a missing field, and would name an
#                innocent commit range as the regression.
#
# A search backwards that reaches UNRECORDED before it reaches PASSED is
# CANNOT-RUN for that probe. It is not a pass and it is not "never passed".
#
# USAGE
#   scripts/walk_regression_triage.sh <version>       triage that walk
#   scripts/walk_regression_triage.sh --newest        triage the newest record
#   scripts/walk_regression_triage.sh --self-test     prove the classifier can fail
#
# Exit 0 when every failing probe was classified, 2 when any probe is
# CANNOT-RUN, 1 on a usage error. Being unable to classify is not a pass.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${WALK_TRIAGE_REPO:-$(cd "${HERE}/.." && pwd)}"
WALKS="${REPO}/walks"

die() { printf '%s\n' "$*" >&2; exit 1; }

# All walk versions, oldest first, ordered by walked_at and NOT by filename --
# a version string does not sort chronologically once a cut is re-walked, and
# 1.0.9 vs 1.0.10 is the classic way a lexical sort picks the wrong baseline.
walk_versions_oldest_first() {
    local f v w
    for f in "${WALKS}"/v*.tsv; do
        [ -f "${f}" ] || continue
        v="$(basename "${f}" .tsv)"
        w="$(awk -F'\t' '$1=="walked_at"{print $2; exit}' "${f}")"
        [ -n "${w}" ] || w="0000"
        printf '%s\t%s\n' "${w}" "${v}"
    done | sort | cut -f2
}

field()   { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1"; }
rows_of() { awk -F'\t' -v k="$2" '$1==k{print $2}' "$1"; }

# classify <walk-file> <probe> -> FAILED | NOT-MEASURED | PASSED | UNRECORDED
classify() {
    local f="$1" p="$2" nfail
    nfail="$(rows_of "${f}" failed_probe | grep -c . || true)"
    if rows_of "${f}" failed_probe | grep -qxF "${p}"; then
        printf 'FAILED\n'; return
    fi
    if rows_of "${f}" not_measured_probe | grep -qxF "${p}"; then
        printf 'NOT-MEASURED\n'; return
    fi
    if [ "${nfail}" -eq 0 ]; then
        # No failed_probe rows AT ALL. See the header: this is a missing field,
        # not a clean sweep, and both such records say verdict FAILED.
        printf 'UNRECORDED\n'; return
    fi
    printf 'PASSED\n'
}

triage() {
    local target="$1"
    local tf="${WALKS}/${target}.tsv"
    [ -f "${tf}" ] || die "CANNOT-RUN: no walk record at ${tf}"

    local verdict; verdict="$(field "${tf}" verdict)"
    local walked;  walked="$(field "${tf}" walked_at)"
    printf '== walk %s   verdict=%s   walked_at=%s ==\n\n' "${target}" "${verdict:-?}" "${walked:-?}"

    local -a order=()
    while IFS= read -r v; do order+=("${v}"); done < <(walk_versions_oldest_first)

    # Index of the target, so the search looks only at EARLIER walks.
    local ti=-1 i=0
    for i in "${!order[@]}"; do
        [ "${order[$i]}" = "${target}" ] && ti="${i}"
    done
    [ "${ti}" -ge 0 ] || die "CANNOT-RUN: ${target} is not among the walk records"

    local -a failing=()
    while IFS= read -r p; do [ -n "${p}" ] && failing+=("${p}"); done < <(rows_of "${tf}" failed_probe)

    if [ "${#failing[@]}" -eq 0 ]; then
        if [ "${verdict}" = "PASSED" ]; then
            printf 'no failing probes recorded, and the verdict is PASSED. Nothing to classify.\n'
            return 0
        fi
        printf '⚠️  verdict is %s but the record names ZERO failed probes.\n' "${verdict}"
        printf '    This record predates the failed_probe field. It cannot be triaged and it\n'
        printf '    cannot serve as a baseline for anything else. CANNOT-RUN.\n'
        return 2
    fi

    local cannot=0 j state probe last_pass nfailed nnamed nnotm
    for probe in "${failing[@]}"; do
        last_pass=""; state=""; nfailed=0; nnamed=0; nnotm=0
        for (( j=ti-1; j>=0; j-- )); do
            state="$(classify "${WALKS}/${order[$j]}.tsv" "${probe}")"
            case "${state}" in
                PASSED)     last_pass="${order[$j]}"; break ;;
                UNRECORDED) last_pass=""; break ;;
                FAILED)       nfailed=$((nfailed+1)); nnamed=$((nnamed+1)) ;;
                NOT-MEASURED) nnotm=$((nnotm+1));     nnamed=$((nnamed+1)) ;;
            esac
        done

        if [ -n "${last_pass}" ]; then
            printf '  REGRESSION   %-38s last passed at %s\n' "${probe}" "${last_pass}"
            printf '               range to examine: %s..%s\n' "${last_pass}" "${target}"
        elif [ "${state}" = "UNRECORDED" ]; then
            printf '  CANNOT-RUN   %-38s history reaches %s, which records no probe names\n' "${probe}" "${order[$j]}"
            printf '               failed in %d and was not measured in %d of the %d earlier records that name probes.\n' \
                   "${nfailed}" "${nnotm}" "${nnamed}"
            printf '               A missing field is not a pass. Do NOT name a commit range from this.\n'
            cannot=$((cannot + 1))
        else
            printf '  NEVER-PASSED %-38s failed in %d and not measured in %d of %d earlier records\n' \
                   "${probe}" "${nfailed}" "${nnotm}" "${nnamed}"
            printf '               This is not a regression. Treat it as unbuilt, not broken.\n'
        fi
    done

    printf '\n  %d failing probe(s); %d could not be classified.\n' "${#failing[@]}" "${cannot}"
    [ "${cannot}" -eq 0 ] || return 2
    return 0
}

# ── SELF-TEST: the classifier must be able to say each of the four things ────
# Without this, a run that classified everything as NEVER-PASSED would look
# exactly like a correct one.
self_test() {
    local tmp pass=0 fail=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/walktriage.XXXXXX")" || die "CANNOT-RUN: no temp dir"
    mkdir -p "${tmp}/walks"

    printf 'walked_at\t2026-01-01T00:00:00Z\nverdict\tFAILED\n' > "${tmp}/walks/v1.0.1.tsv"
    printf 'walked_at\t2026-01-02T00:00:00Z\nverdict\tFAILED\nfailed_probe\tother\n' > "${tmp}/walks/v1.0.2.tsv"
    printf 'walked_at\t2026-01-03T00:00:00Z\nverdict\tFAILED\nfailed_probe\tsubject\n' > "${tmp}/walks/v1.0.3.tsv"

    _t() {  # $1 wanted-substring  $2 wanted-rc  $3 label
        local out rc
        out="$(WALK_TRIAGE_REPO="${tmp}" "$0" v1.0.3 2>&1)"; rc=$?
        if grep -q "$1" <<< "${out}" && [ "${rc}" -eq "$2" ]; then
            printf '  [PASS] %s\n' "$3"; pass=$((pass+1))
        else
            printf '  [FAIL] %s (rc=%s)\n' "$3" "${rc}"; printf '%s\n' "${out}" | sed 's/^/         /'
            fail=$((fail+1))
        fi
    }

    echo "self-test: the classifier must be able to say each thing"
    # v1.0.2 names a DIFFERENT probe, so `subject` is PASSED there -> regression.
    _t 'REGRESSION' 0 'a probe absent from a record that names others reads as PASSED -> REGRESSION'

    # Now make v1.0.2 nameless too, so the search reaches UNRECORDED.
    printf 'walked_at\t2026-01-02T00:00:00Z\nverdict\tFAILED\n' > "${tmp}/walks/v1.0.2.tsv"
    _t 'CANNOT-RUN' 2 'a record with NO probe names is UNRECORDED, not a pass -> CANNOT-RUN, rc=2'

    # And with the subject failing all the way back, it never passed.
    printf 'walked_at\t2026-01-01T00:00:00Z\nverdict\tFAILED\nfailed_probe\tsubject\n' > "${tmp}/walks/v1.0.1.tsv"
    printf 'walked_at\t2026-01-02T00:00:00Z\nverdict\tFAILED\nfailed_probe\tsubject\n' > "${tmp}/walks/v1.0.2.tsv"
    _t 'NEVER-PASSED' 0 'failing in every earlier record -> NEVER-PASSED, not a regression'

    rm -rf -- "${tmp}"
    printf '\n  PASS: %d  FAIL: %d\n' "${pass}" "${fail}"
    [ "${fail}" -eq 0 ] || return 1
    return 0
}

case "${1:-}" in
    --self-test) self_test; exit $? ;;
    --newest)
        newest="$(walk_versions_oldest_first | tail -1)"
        [ -n "${newest}" ] || die "CANNOT-RUN: no walk records under ${WALKS}"
        triage "${newest}"; exit $? ;;
    "" ) die "usage: $0 <version> | --newest | --self-test" ;;
    * )  triage "${1#walks/}"; exit $? ;;
esac
