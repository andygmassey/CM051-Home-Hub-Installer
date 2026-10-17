#!/usr/bin/env bash
# scripts/lib_walk_store.sh -- what may live in the operator's walk store.
#
# The walk store (~/.ostler/walks, or $OSTLER_WALK_STORE) holds <ver>-<stamp>.tsv
# copies of real walk records. scripts/early_repeat_fail_pass.sh and the
# run_box_walk.sh promotion read the NEWEST one as "the previous walk".
#
# WHY THIS EXISTS: a test that ran record_walk.sh with a stub writer and
# --version v9.9.9 left v9.9.9-<stamp>.tsv in the REAL store. The next real
# walk's early pass picked that fake record as the previous walk and could not
# run. Two defences, both here so the writer and the readers agree:
#   1. walk_store_version_is_cut: only a real cut version may be copied in,
#      and a reader skips anything else and falls back to the next newest.
#   2. walk_store_write_refusal: under a test (OSTLER_UNDER_TEST=1) the store
#      must be named explicitly via OSTLER_WALK_STORE, never defaulted to $HOME.
#
# A real cut version is vMAJOR.MINOR.PATCH with MAJOR 1..8 (real ones are
# v1.0.NNN, see walks/). Fixture markers (v9.9.9, v99.x, v0.0.0) are not cuts.
# BASH 3.2.

walk_store_version_is_cut() {   # $1 = version, with or without a leading v
    local v="${1:-}"
    [[ "$v" == v* ]] || v="v${v}"
    [[ "$v" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local major="${BASH_REMATCH[1]}"
    [ "$major" -ge 1 ] && [ "$major" -le 8 ]
}

# Prints the reason and returns 0 when a copy into the store must be refused.
walk_store_write_refusal() {   # $1 = version
    if ! walk_store_version_is_cut "${1:-}"; then
        printf "'%s' is not a real cut version (expected vMAJOR.MINOR.PATCH with MAJOR 1..8, like v1.0.107); fixture records never enter the walk store" "${1:-}"
        return 0
    fi
    if [ "${OSTLER_UNDER_TEST:-}" = "1" ] && [ -z "${OSTLER_WALK_STORE:-}" ]; then
        printf 'running under a test (OSTLER_UNDER_TEST=1) with OSTLER_WALK_STORE unset, so the store would default to the real ~/.ostler/walks'
        return 0
    fi
    return 1
}
